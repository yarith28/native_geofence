package com.chunkytofustudios.native_geofence.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import com.chunkytofustudios.native_geofence.api.NativeGeofenceApiImpl
import com.chunkytofustudios.native_geofence.bridge.CallbackPayloadEnqueueRecovery
import com.chunkytofustudios.native_geofence.bridge.DeferredGeofenceCallbackDelivery
import com.chunkytofustudios.native_geofence.bridge.NativeGeofenceCallbackDelivery
import com.chunkytofustudios.native_geofence.bridge.NativeGeofenceCallbackEnqueueResult
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceMutationKind
import com.chunkytofustudios.native_geofence.util.BroadcastCompletionBarrier
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackRegistration
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackRouting
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackRoutingResult
import com.chunkytofustudios.native_geofence.util.GeofenceEvents
import com.chunkytofustudios.native_geofence.util.GeofenceMutationQueues
import com.chunkytofustudios.native_geofence.util.GeofenceMutationRunner
import com.chunkytofustudios.native_geofence.util.LocationWires
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnosticStage
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDeliveryDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.chunkytofustudios.native_geofence.util.OrphanedGeofenceCleanupCoordinator
import com.chunkytofustudios.native_geofence.util.attachWithGeofenceMutationDeadline
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.location.LocationServices
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

internal sealed interface GeofenceBroadcastOutcome {
    data class Callbacks(val routing: GeofenceCallbackRoutingResult) : GeofenceBroadcastOutcome
    data object GeofenceNotAvailable : GeofenceBroadcastOutcome
    data object Ignored : GeofenceBroadcastOutcome
}

internal object GeofenceBroadcastOutcomeClassifier {
    fun fromErrorCode(errorCode: Int): GeofenceBroadcastOutcome =
        if (errorCode == GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE) {
            GeofenceBroadcastOutcome.GeofenceNotAvailable
        } else {
            GeofenceBroadcastOutcome.Ignored
        }
}

internal typealias NativeCallbackDeliveryEnqueue = (
    Context,
    GeofenceCallbackParamsWire,
    (NativeGeofenceCallbackEnqueueResult) -> Unit,
) -> Unit

internal typealias NativeCallbackDeliveryDefer = (
    Context,
    GeofenceCallbackParamsWire,
    (Boolean) -> Unit,
) -> Unit

/** Keeps the broadcast lease tied to completion of the public delivery boundary. */
internal class GeofenceBroadcastCallbackEnqueuer(
    private val enqueue: NativeCallbackDeliveryEnqueue =
        NativeGeofenceCallbackDelivery::enqueue,
    private val eventId: () -> String = { UUID.randomUUID().toString() },
) {
    fun enqueue(
        context: Context,
        groups: List<GeofenceCallbackParamsWire>,
        barrier: BroadcastCompletionBarrier,
    ) {
        if (groups.isEmpty()) return
        val tickets = groups.map { barrier.ticket() }
        groups.forEachIndexed { index, params ->
            val deliveryId = eventId()
            val identified = params.copy(eventId = deliveryId, traceId = deliveryId)
            try {
                recordBroadcastDelivery(context, identified, "dispatching")
                enqueue(
                    context,
                    identified,
                ) {
                    tickets[index]()
                }
            } catch (error: Throwable) {
                recordBroadcastDelivery(
                    context,
                    identified,
                    "dispatch_failed",
                    error.javaClass.name,
                )
                runCatching {
                    NativeGeofenceLogger.e(
                        context,
                        TAG,
                        "Failed to dispatch callback delivery.",
                        error,
                    )
                }
                tickets[index]()
            }
        }
    }

    private fun recordBroadcastDelivery(
        context: Context,
        params: GeofenceCallbackParamsWire,
        outcome: String,
        errorType: String? = null,
    ) {
        val location = params.location
        runCatching {
            NativeGeofenceDeliveryDiagnostics.record(
                context = context,
                traceId = params.traceId,
                stage = "broadcast_delivery",
                outcome = outcome,
                event = params.event.name.lowercase(),
                geofenceCount = params.geofences.size,
                owner = "native_geofence",
                hasLocation = location != null,
                locationAgeMillis = location?.elapsedRealtimeNanos?.let {
                    ((SystemClock.elapsedRealtimeNanos() - it) / 1_000_000L)
                        .coerceAtLeast(0L)
                },
                accuracyMeters = location?.accuracyMeters,
                errorType = errorType,
            )
        }
    }

    private companion object {
        const val TAG = "GeofenceBroadcastCallbackEnqueuer"
    }
}

/** Persists stale callback groups before releasing the broadcast lease. */
internal class GeofenceBroadcastCallbackDeferrer(
    private val defer: NativeCallbackDeliveryDefer =
        DeferredGeofenceCallbackDelivery::defer,
    private val fallbackEnqueue: NativeCallbackDeliveryEnqueue =
        NativeGeofenceCallbackDelivery::enqueue,
    private val eventId: () -> String = { UUID.randomUUID().toString() },
) {
    fun defer(
        context: Context,
        groups: List<GeofenceCallbackParamsWire>,
        barrier: BroadcastCompletionBarrier,
    ) {
        if (groups.isEmpty()) return
        val tickets = groups.map { barrier.ticket() }
        groups.forEachIndexed { index, params ->
            val traceId = eventId()
            val identified = params.copy(eventId = traceId, traceId = traceId)
            val deferralResolved = AtomicBoolean(false)
            fun finishDeferral(accepted: Boolean) {
                if (!deferralResolved.compareAndSet(false, true)) return
                if (accepted) {
                    tickets[index]()
                } else {
                    enqueueFallback(context, identified, tickets[index])
                }
            }
            try {
                defer(
                    context,
                    identified,
                ) {
                    finishDeferral(it)
                }
            } catch (error: Throwable) {
                runCatching {
                    NativeGeofenceLogger.e(
                        context,
                        TAG,
                        "Failed to dispatch stale callback deferral.",
                        error,
                    )
                }
                finishDeferral(false)
            }
        }
    }

    private fun enqueueFallback(
        context: Context,
        params: GeofenceCallbackParamsWire,
        completion: () -> Unit,
    ) {
        try {
            fallbackEnqueue(context, params) { outcome ->
                if (outcome == NativeGeofenceCallbackEnqueueResult.REJECTED) {
                    runCatching {
                        NativeGeofenceLogger.e(
                            context,
                            TAG,
                            "Both stale callback deferral and durable fallback were rejected.",
                        )
                    }
                }
                completion()
            }
        } catch (error: Throwable) {
            runCatching {
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Failed to dispatch stale callback fallback.",
                    error,
                )
            }
            completion()
        }
    }

    private companion object {
        const val TAG = "GeofenceBroadcastCallbackDeferrer"
    }
}

class NativeGeofenceBroadcastReceiver : BroadcastReceiver() {
    private val callbackEnqueuer = GeofenceBroadcastCallbackEnqueuer()
    private val callbackDeferrer = GeofenceBroadcastCallbackDeferrer()

    override fun onReceive(context: Context, intent: Intent) {
        val appContext = context.applicationContext
        NativeGeofenceLogger.d(appContext, TAG, "Geofence broadcast received.")
        CallbackPayloadEnqueueRecovery.recover(appContext)

        val routing = when (val outcome = getGeofenceBroadcastOutcome(appContext, intent)) {
            is GeofenceBroadcastOutcome.Callbacks -> {
                val routing = outcome.routing
                val callbackCount = (
                    routing.callbackGroups + routing.staleCallbackGroups
                    ).sumOf { it.geofences.size }
                val diagnosticOutcome = when {
                    routing.callbackGroups.isNotEmpty() -> "resolved"
                    routing.orphanIds.isNotEmpty() -> "orphaned"
                    routing.staleIds.isNotEmpty() -> "stale"
                    else -> "unresolved"
                }
                NativeGeofenceDiagnostics.record(
                    appContext,
                    NativeGeofenceDiagnosticStage.BROADCAST,
                    succeeded = routing.callbackGroups.isNotEmpty() ||
                        routing.staleCallbackGroups.isNotEmpty(),
                    outcome = diagnosticOutcome,
                    geofenceCount = callbackCount
                )
                routing
            }
            GeofenceBroadcastOutcome.GeofenceNotAvailable -> {
                NativeGeofenceDiagnostics.record(
                    appContext,
                    NativeGeofenceDiagnosticStage.BROADCAST,
                    succeeded = false,
                    outcome = "geofence_not_available"
                )
                startNotAvailableRecovery(appContext)
                return
            }
            GeofenceBroadcastOutcome.Ignored -> {
                NativeGeofenceDiagnostics.record(
                    appContext,
                    NativeGeofenceDiagnosticStage.BROADCAST,
                    succeeded = false,
                    outcome = "ignored"
                )
                return
            }
        }

        if (routing.staleIds.isNotEmpty()) {
            NativeGeofenceLogger.w(
                appContext,
                TAG,
                "Deferring ${routing.staleIds.size} callback registration(s) from an older package."
            )
        }

        val taskCount = routing.callbackGroups.size +
            routing.staleCallbackGroups.size +
            routing.orphanIds.size
        if (taskCount == 0) {
            NativeGeofenceLogger.w(
                appContext,
                TAG,
                "No current callback or orphan-cleanup work was produced for this broadcast."
            )
            return
        }

        val lease = RecoveryBroadcastLease(goAsync())
        val barrier = BroadcastCompletionBarrier(taskCount, lease::finish)
        enqueueCallbackGroups(appContext, routing.callbackGroups, barrier)
        callbackDeferrer.defer(appContext, routing.staleCallbackGroups, barrier)
        cleanupOrphans(appContext, routing.orphanIds, barrier)
    }

    private fun enqueueCallbackGroups(
        context: Context,
        groups: List<GeofenceCallbackParamsWire>,
        barrier: BroadcastCompletionBarrier
    ) {
        callbackEnqueuer.enqueue(context, groups, barrier)
    }

    private fun cleanupOrphans(
        context: Context,
        orphanIds: List<String>,
        barrier: BroadcastCompletionBarrier
    ) {
        if (orphanIds.isEmpty()) return
        val tickets = orphanIds.map { barrier.ticket() }
        val coordinator = try {
            createOrphanCleanupCoordinator(context)
        } catch (error: Throwable) {
            NativeGeofenceLogger.e(context, TAG, "Failed to prepare orphan cleanup.", error)
            tickets.forEach { it() }
            return
        }

        orphanIds.forEachIndexed { index, id ->
            try {
                coordinator.cleanup(id) { result ->
                    try {
                        result.exceptionOrNull()?.let { error ->
                            NativeGeofenceLogger.e(
                                context,
                                TAG,
                                "Failed to clean an orphaned geofence ID=$id.",
                                error
                            )
                        }
                    } finally {
                        tickets[index]()
                    }
                }
            } catch (error: Throwable) {
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Failed to dispatch orphan cleanup ID=$id.",
                    error
                )
                tickets[index]()
            }
        }
    }

    private fun createOrphanCleanupCoordinator(
        context: Context
    ): OrphanedGeofenceCleanupCoordinator {
        val geofencingClient = LocationServices.getGeofencingClient(context)
        val mutationRunner = GeofenceMutationRunner(
            GeofenceMutationQueues.forContext(context) { error ->
                NativeGeofenceLogger.e(context, TAG, "Unhandled orphan cleanup failure.", error)
            }
        ) { error ->
            NativeGeofenceLogger.e(context, TAG, "Orphan cleanup callback failed.", error)
        }
        return OrphanedGeofenceCleanupCoordinator(
            mutationRunner = mutationRunner,
            lookup = { id -> NativeGeofencePersistence.getGeofence(context, id) },
            markForPlatformCleanup = { id ->
                NativeGeofencePersistence.markGeofenceForPlatformCleanup(context, id)
            },
            removeFromPlatform = { id, complete ->
                geofencingClient.removeGeofences(listOf(id))
                    .attachWithGeofenceMutationDeadline(
                        kind = AndroidGeofenceMutationKind.REMOVAL,
                        onSuccess = { complete(Result.success(Unit)) },
                        onFailure = { complete(Result.failure(it)) }
                    )
            },
            clearDurableState = { id -> NativeGeofencePersistence.removeGeofence(context, id) }
        )
    }

    private fun startNotAvailableRecovery(context: Context) {
        val lease = RecoveryBroadcastLease(goAsync())
        try {
            NativeGeofenceApiImpl(context).startAutomaticRecovery(
                reason = "geofence_not_available"
            ) { result ->
                try {
                    result.exceptionOrNull()?.let { error ->
                        NativeGeofenceLogger.e(
                            context,
                            TAG,
                            "GEOFENCE_NOT_AVAILABLE recovery failed.",
                            error
                        )
                    }
                } finally {
                    lease.finish()
                }
            }
        } catch (error: Throwable) {
            NativeGeofenceLogger.e(
                context,
                TAG,
                "Failed to start GEOFENCE_NOT_AVAILABLE recovery.",
                error
            )
            lease.finish()
        }
    }

    private fun getGeofenceBroadcastOutcome(
        context: Context,
        intent: Intent
    ): GeofenceBroadcastOutcome {
        val geofencingEvent = GeofencingEvent.fromIntent(intent)
        if (geofencingEvent == null) {
            NativeGeofenceLogger.e(context, TAG, "GeofencingEvent is null.")
            return GeofenceBroadcastOutcome.Ignored
        }
        if (geofencingEvent.hasError()) {
            NativeGeofenceLogger.e(
                context,
                TAG,
                "GeofencingEvent has error Code=${geofencingEvent.errorCode}."
            )
            return GeofenceBroadcastOutcomeClassifier.fromErrorCode(geofencingEvent.errorCode)
        }

        val geofenceEvent = GeofenceEvents.fromInt(geofencingEvent.geofenceTransition)
        if (geofenceEvent == null) {
            NativeGeofenceLogger.e(
                context,
                TAG,
                "GeofencingEvent has invalid transition ID=${geofencingEvent.geofenceTransition}."
            )
            return GeofenceBroadcastOutcome.Ignored
        }

        val triggeringIds = geofencingEvent.triggeringGeofences?.map { it.requestId }
        if (triggeringIds.isNullOrEmpty()) {
            NativeGeofenceLogger.e(context, TAG, "No triggering geofences found.")
            return GeofenceBroadcastOutcome.Ignored
        }

        val location = geofencingEvent.triggeringLocation
        if (location == null) {
            NativeGeofenceLogger.w(context, TAG, "No triggering location found.")
        }

        return GeofenceBroadcastOutcome.Callbacks(
            GeofenceCallbackRouting.route(
                triggeredIds = triggeringIds,
                event = geofenceEvent,
                location = location?.let(LocationWires::fromLocation),
                eventAtMillis = System.currentTimeMillis(),
                lookup = { id ->
                    NativeGeofencePersistence.getStoredGeofence(context, id)?.let {
                        GeofenceCallbackRegistration(
                            configuredGeofence = it.configuredGeofence,
                            expirationDeadlineMillis = it.expirationDeadlineMillis,
                        )
                    }
                },
                isCallbackFresh = { id ->
                    NativeGeofencePersistence.isCallbackPackageCurrent(context, id)
                }
            )
        )
    }

    private companion object {
        const val TAG = "NativeGeofenceBroadcastReceiver"
    }
}
