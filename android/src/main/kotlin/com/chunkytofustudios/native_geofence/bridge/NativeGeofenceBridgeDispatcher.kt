package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import android.os.SystemClock
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.LocationWire
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDeliveryDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import java.util.concurrent.Future
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

internal sealed interface NativeGeofenceBridgeOutcome {
    data object Accepted : NativeGeofenceBridgeOutcome
    data class Continue(val params: GeofenceCallbackParamsWire) : NativeGeofenceBridgeOutcome
}

internal class NativeGeofenceBridgeDecisionGate(
    timeoutMillis: Long,
    schedule: (Long, () -> Unit) -> (() -> Unit),
    private val onResolved: (NativeGeofenceBridgeDecision?) -> Unit
) {
    private val lock = Object()
    private var open = true
    private val cancelTimeout = schedule(timeoutMillis) { resolve(null) }

    fun resolve(decision: NativeGeofenceBridgeDecision?): Boolean {
        val accepted = synchronized(lock) {
            if (!open) {
                false
            } else {
                open = false
                true
            }
        }
        if (!accepted) return false
        cancelTimeout()
        onResolved(decision)
        return true
    }
}

/** Keeps the ownership deadline independent from Android's main message queue. */
internal object NativeGeofenceBridgeTimeoutScheduler {
    private val executor = ScheduledThreadPoolExecutor(
        1,
        { runnable ->
            Thread(runnable, "native-geofence-bridge-timeout").apply { isDaemon = true }
        }
    ).apply {
        removeOnCancelPolicy = true
    }

    fun schedule(delayMillis: Long, action: () -> Unit): () -> Unit {
        val future = executor.schedule(action, delayMillis, TimeUnit.MILLISECONDS)
        return { future.cancel(false) }
    }
}

internal object NativeGeofenceBridgeMapper {
    fun event(params: GeofenceCallbackParamsWire): NativeGeofenceBridgeEvent? {
        val eventId = params.eventId?.takeIf(String::isNotBlank) ?: return null
        return NativeGeofenceBridgeEvent(
            geofenceIds = params.geofences.map { it.id }.distinct(),
            transition = params.event.toBridgeTransition(),
            location = params.location?.let {
                NativeGeofenceBridgeLocation(
                    latitude = it.latitude,
                    longitude = it.longitude,
                    accuracyMeters = it.accuracyMeters,
                    isMock = it.isMock,
                    fixTimeMillis = it.fixTimeMillis,
                    elapsedRealtimeNanos = it.elapsedRealtimeNanos,
                )
            },
            eventAtMillis = params.eventAtMillis,
            eventId = eventId
        )
    }

    fun outcome(
        original: GeofenceCallbackParamsWire,
        decision: NativeGeofenceBridgeDecision?
    ): NativeGeofenceBridgeOutcome = when (decision) {
        NativeGeofenceBridgeDecision.Accept -> NativeGeofenceBridgeOutcome.Accepted
        is NativeGeofenceBridgeDecision.Transform -> transform(original, decision.transformation)
        NativeGeofenceBridgeDecision.Decline,
        null -> NativeGeofenceBridgeOutcome.Continue(original)
    }

    private fun transform(
        original: GeofenceCallbackParamsWire,
        transformation: NativeGeofenceBridgeTransformation
    ): NativeGeofenceBridgeOutcome {
        val requestedIds = transformation.geofenceIds.distinct()
        val originalById = original.geofences.associateBy { it.id }
        if (
            requestedIds.isEmpty() ||
            requestedIds.any { id -> !originalById.containsKey(id) } ||
            !transformation.location.isValid()
        ) {
            return NativeGeofenceBridgeOutcome.Continue(original)
        }
        return NativeGeofenceBridgeOutcome.Continue(
            original.copy(
                geofences = requestedIds.mapNotNull(originalById::get),
                event = transformation.transition.toWire(),
                location = transformation.location?.let {
                    LocationWire(
                        latitude = it.latitude,
                        longitude = it.longitude,
                        accuracyMeters = it.accuracyMeters,
                        isMock = it.isMock,
                        fixTimeMillis = it.fixTimeMillis,
                        elapsedRealtimeNanos = it.elapsedRealtimeNanos,
                    )
                },
                callbackContextsByGeofenceId = original.callbackContextsByGeofenceId
                    ?.filterKeys(requestedIds::contains)
                    ?.ifEmpty { null }
            )
        )
    }

    private fun GeofenceEvent.toBridgeTransition(): NativeGeofenceBridgeTransition = when (this) {
        GeofenceEvent.ENTER -> NativeGeofenceBridgeTransition.ENTER
        GeofenceEvent.EXIT -> NativeGeofenceBridgeTransition.EXIT
        GeofenceEvent.DWELL -> NativeGeofenceBridgeTransition.DWELL
    }

    private fun NativeGeofenceBridgeTransition.toWire(): GeofenceEvent = when (this) {
        NativeGeofenceBridgeTransition.ENTER -> GeofenceEvent.ENTER
        NativeGeofenceBridgeTransition.EXIT -> GeofenceEvent.EXIT
        NativeGeofenceBridgeTransition.DWELL -> GeofenceEvent.DWELL
    }

    private fun NativeGeofenceBridgeLocation?.isValid(): Boolean =
        this == null ||
            (
                latitude.isFinite() && latitude in -90.0..90.0 &&
                    longitude.isFinite() && longitude in -180.0..180.0 &&
                    (accuracyMeters == null ||
                        (accuracyMeters.isFinite() && accuracyMeters >= 0.0))
                )
}

internal object NativeGeofenceBridgeDispatcher {
    private val processorExecutor = ThreadPoolExecutor(
        0,
        2,
        30L,
        TimeUnit.SECONDS,
        SynchronousQueue(),
        { runnable -> Thread(runnable, "native-geofence-bridge").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy()
    )

    fun process(
        context: Context,
        params: GeofenceCallbackParamsWire,
        completion: (NativeGeofenceBridgeOutcome) -> Unit
    ) {
        val startedAtElapsed = SystemClock.elapsedRealtime()
        val traceId = params.traceId?.takeIf(String::isNotBlank) ?: params.eventId
        val event = NativeGeofenceBridgeMapper.event(params)
        if (event == null) {
            record(
                context = context,
                params = params,
                traceId = traceId,
                stage = "bridge_decision",
                outcome = "invalid_event_to_dart",
                owner = "dart",
                reasonCode = "event_id_missing",
            )
            completion(NativeGeofenceBridgeOutcome.Continue(params))
            return
        }

        val resolution = NativeGeofenceBridge.resolveDetailed(context)
        record(
            context = context,
            params = params,
            traceId = traceId,
            stage = "bridge_resolved",
            outcome = resolution.outcome,
            processorSource = resolution.source,
            processorClass = resolution.className,
            errorType = resolution.errorType,
        )
        val processor = resolution.processor
        if (processor == null) {
            record(
                context = context,
                params = params,
                traceId = traceId,
                stage = "bridge_decision",
                outcome = "processor_unavailable_to_dart",
                owner = "dart",
                reasonCode = resolution.outcome,
                processorSource = resolution.source,
                processorClass = resolution.className,
                errorType = resolution.errorType,
                durationMillis = SystemClock.elapsedRealtime() - startedAtElapsed,
            )
            completion(NativeGeofenceBridgeOutcome.Continue(params))
            return
        }

        record(
            context = context,
            params = params,
            traceId = traceId,
            stage = "bridge_invoked",
            outcome = "started",
            owner = "native_pending",
            processorSource = resolution.source,
            processorClass = resolution.className,
        )

        val processingFuture = AtomicReference<Future<*>?>(null)
        val forcedOutcome = AtomicReference<String?>(null)
        val forcedErrorType = AtomicReference<String?>(null)
        val gate = NativeGeofenceBridgeDecisionGate(
            timeoutMillis = OWNERSHIP_TIMEOUT_MILLIS,
            schedule = NativeGeofenceBridgeTimeoutScheduler::schedule,
            onResolved = { decision ->
                if (decision == null) {
                    processingFuture.get()?.cancel(true)
                    NativeGeofenceLogger.w(
                        context,
                        TAG,
                        "Native event processor timed out; continuing with Dart delivery."
                    )
                }
                val mapped = NativeGeofenceBridgeMapper.outcome(params, decision)
                val outcome = forcedOutcome.get() ?: when (decision) {
                    NativeGeofenceBridgeDecision.Accept -> "native_accepted"
                    NativeGeofenceBridgeDecision.Decline -> "declined_to_dart"
                    is NativeGeofenceBridgeDecision.Transform ->
                        if (mapped is NativeGeofenceBridgeOutcome.Continue &&
                            mapped.params == params
                        ) {
                            "invalid_transform_to_dart"
                        } else {
                            "transformed_to_dart"
                        }
                    null -> "timeout_to_dart"
                }
                record(
                    context = context,
                    params = params,
                    traceId = traceId,
                    stage = "bridge_decision",
                    outcome = outcome,
                    owner = if (decision == NativeGeofenceBridgeDecision.Accept) {
                        "native"
                    } else {
                        "dart"
                    },
                    reasonCode = if (decision == null) "ownership_timeout" else null,
                    durationMillis = SystemClock.elapsedRealtime() - startedAtElapsed,
                    processorSource = resolution.source,
                    processorClass = resolution.className,
                    errorType = forcedErrorType.get(),
                )
                completion(mapped)
            }
        )

        try {
            processingFuture.set(
                processorExecutor.submit {
                    try {
                        processor.processNativeGeofenceEvent(
                            context.applicationContext,
                            event
                        ) { result ->
                            val decision = result.getOrElse { error ->
                                forcedOutcome.compareAndSet(null, "failed_to_dart")
                                forcedErrorType.compareAndSet(null, error.javaClass.name)
                                NativeGeofenceLogger.w(
                                    context,
                                    TAG,
                                    "Native event processor failed; continuing with Dart " +
                                        "delivery.",
                                    error
                                )
                                NativeGeofenceBridgeDecision.Decline
                            }
                            if (!gate.resolve(decision)) {
                                record(
                                    context = context,
                                    params = params,
                                    traceId = traceId,
                                    stage = "bridge_completion",
                                    outcome = "late_completion_ignored",
                                    owner = "dart",
                                    durationMillis = SystemClock.elapsedRealtime() -
                                        startedAtElapsed,
                                    processorSource = resolution.source,
                                    processorClass = resolution.className,
                                )
                            }
                        }
                    } catch (error: Throwable) {
                        forcedOutcome.compareAndSet(null, "threw_to_dart")
                        forcedErrorType.compareAndSet(null, error.javaClass.name)
                        NativeGeofenceLogger.w(
                            context,
                            TAG,
                            "Native event processor threw; continuing with Dart delivery.",
                            error
                        )
                        gate.resolve(NativeGeofenceBridgeDecision.Decline)
                    }
                }
            )
        } catch (error: RuntimeException) {
            forcedOutcome.compareAndSet(null, "schedule_failed_to_dart")
            forcedErrorType.compareAndSet(null, error.javaClass.name)
            NativeGeofenceLogger.w(
                context,
                TAG,
                "Native event processor could not be scheduled; continuing with Dart delivery.",
                error
            )
            gate.resolve(NativeGeofenceBridgeDecision.Decline)
        }
    }

    private fun record(
        context: Context,
        params: GeofenceCallbackParamsWire,
        traceId: String?,
        stage: String,
        outcome: String,
        owner: String? = null,
        reasonCode: String? = null,
        durationMillis: Long? = null,
        processorSource: String? = null,
        processorClass: String? = null,
        errorType: String? = null,
    ) {
        val location = params.location
        val locationAgeMillis = location?.elapsedRealtimeNanos?.let { fixElapsedNanos ->
            ((SystemClock.elapsedRealtimeNanos() - fixElapsedNanos) / 1_000_000L)
                .coerceAtLeast(0L)
        }
        runCatching {
            NativeGeofenceDeliveryDiagnostics.record(
                context = context,
                traceId = traceId,
                stage = stage,
                outcome = outcome,
                event = params.event.name.lowercase(),
                geofenceCount = params.geofences.size,
                owner = owner,
                reasonCode = reasonCode,
                durationMillis = durationMillis,
                hasLocation = location != null,
                locationAgeMillis = locationAgeMillis,
                accuracyMeters = location?.accuracyMeters,
                processorSource = processorSource,
                processorClass = processorClass,
                errorType = errorType,
            )
        }
    }

    private const val TAG = "NativeGeofenceBridgeDispatcher"
    private const val OWNERSHIP_TIMEOUT_MILLIS = 3_000L
}
