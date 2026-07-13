package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.LocationWire
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import java.util.concurrent.Future
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
                    isMock = it.isMock
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
                        isMock = it.isMock
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
    private val mainHandler = Handler(Looper.getMainLooper())
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
        val processor = NativeGeofenceBridge.resolve(context)
        val event = NativeGeofenceBridgeMapper.event(params)
        if (processor == null || event == null) {
            completion(NativeGeofenceBridgeOutcome.Continue(params))
            return
        }

        val processingFuture = AtomicReference<Future<*>?>(null)
        val gate = NativeGeofenceBridgeDecisionGate(
            timeoutMillis = OWNERSHIP_TIMEOUT_MILLIS,
            schedule = { delayMillis, action ->
                val runnable = Runnable(action)
                mainHandler.postDelayed(runnable, delayMillis)
                val cancel: () -> Unit = { mainHandler.removeCallbacks(runnable) }
                cancel
            },
            onResolved = { decision ->
                if (decision == null) {
                    processingFuture.get()?.cancel(true)
                    NativeGeofenceLogger.w(
                        context,
                        TAG,
                        "Native event processor timed out; continuing with Dart delivery."
                    )
                }
                completion(NativeGeofenceBridgeMapper.outcome(params, decision))
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
                                NativeGeofenceLogger.w(
                                    context,
                                    TAG,
                                    "Native event processor failed; continuing with Dart " +
                                        "delivery.",
                                    error
                                )
                                NativeGeofenceBridgeDecision.Decline
                            }
                            gate.resolve(decision)
                        }
                    } catch (error: Throwable) {
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
            NativeGeofenceLogger.w(
                context,
                TAG,
                "Native event processor could not be scheduled; continuing with Dart delivery.",
                error
            )
            gate.resolve(NativeGeofenceBridgeDecision.Decline)
        }
    }

    private const val TAG = "NativeGeofenceBridgeDispatcher"
    private const val OWNERSHIP_TIMEOUT_MILLIS = 3_000L
}
