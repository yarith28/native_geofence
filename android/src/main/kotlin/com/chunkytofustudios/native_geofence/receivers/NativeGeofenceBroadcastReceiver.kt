package com.chunkytofustudios.native_geofence.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.BackoffPolicy
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.NativeGeofenceBackgroundWorker
import com.chunkytofustudios.native_geofence.api.NativeGeofenceApiImpl
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceMutationKind
import com.chunkytofustudios.native_geofence.util.AndroidPackageFingerprint
import com.chunkytofustudios.native_geofence.util.BroadcastCompletionBarrier
import com.chunkytofustudios.native_geofence.util.CallbackEnqueueOperation
import com.chunkytofustudios.native_geofence.util.CallbackEnqueueOutcome
import com.chunkytofustudios.native_geofence.util.CallbackEnqueueUnconfirmedException
import com.chunkytofustudios.native_geofence.util.CallbackWorkEnqueueCoordinator
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackPayloadStore
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackRouting
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackRoutingResult
import com.chunkytofustudios.native_geofence.util.GeofenceEvents
import com.chunkytofustudios.native_geofence.util.GeofenceMutationQueues
import com.chunkytofustudios.native_geofence.util.GeofenceMutationRunner
import com.chunkytofustudios.native_geofence.util.LocationWires
import com.chunkytofustudios.native_geofence.util.NativeGeofenceIo
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnosticStage
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.chunkytofustudios.native_geofence.util.OrphanedGeofenceCleanupCoordinator
import com.chunkytofustudios.native_geofence.util.attachWithGeofenceMutationDeadline
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.location.LocationServices
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

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

class NativeGeofenceBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val appContext = context.applicationContext
        NativeGeofenceLogger.d(appContext, TAG, "Geofence broadcast received.")

        val routing = when (val outcome = getGeofenceBroadcastOutcome(appContext, intent)) {
            is GeofenceBroadcastOutcome.Callbacks -> {
                val routing = outcome.routing
                val callbackCount = routing.callbackGroups.sumOf { it.geofences.size }
                val diagnosticOutcome = when {
                    routing.callbackGroups.isNotEmpty() -> "resolved"
                    routing.orphanIds.isNotEmpty() -> "orphaned"
                    routing.staleIds.isNotEmpty() -> "stale"
                    else -> "unresolved"
                }
                NativeGeofenceDiagnostics.record(
                    appContext,
                    NativeGeofenceDiagnosticStage.BROADCAST,
                    succeeded = routing.callbackGroups.isNotEmpty(),
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
                "Ignored ${routing.staleIds.size} callback registration(s) from an older package."
            )
        }

        val taskCount = routing.callbackGroups.size + routing.orphanIds.size
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
        cleanupOrphans(appContext, routing.orphanIds, barrier)
    }

    private fun enqueueCallbackGroups(
        context: Context,
        groups: List<GeofenceCallbackParamsWire>,
        barrier: BroadcastCompletionBarrier
    ) {
        if (groups.isEmpty()) return
        val tickets = groups.map { barrier.ticket() }
        try {
            NativeGeofenceIo.execute {
                val packageFingerprint: String
                val payloadStore: GeofenceCallbackPayloadStore
                try {
                    packageFingerprint = AndroidPackageFingerprint.current(context)
                    payloadStore = GeofenceCallbackPayloadStore.forContext(context)
                } catch (error: Throwable) {
                    NativeGeofenceLogger.e(
                        context,
                        TAG,
                        "Failed to prepare durable callback enqueueing.",
                        error
                    )
                    tickets.forEach { it() }
                    return@execute
                }

                groups.forEachIndexed { index, params ->
                    enqueueCallback(
                        context = context,
                        params = params.copy(eventId = UUID.randomUUID().toString()),
                        packageFingerprint = packageFingerprint,
                        payloadStore = payloadStore,
                        completion = tickets[index]
                    )
                }
            }
        } catch (error: Throwable) {
            NativeGeofenceLogger.e(context, TAG, "Failed to dispatch callback enqueueing.", error)
            tickets.forEach { it() }
        }
    }

    private fun enqueueCallback(
        context: Context,
        params: GeofenceCallbackParamsWire,
        packageFingerprint: String,
        payloadStore: GeofenceCallbackPayloadStore,
        completion: () -> Unit
    ) {
        val reference = try {
            payloadStore.store(params, packageFingerprint)
        } catch (error: Throwable) {
            NativeGeofenceLogger.e(context, TAG, "Failed to persist a callback payload.", error)
            null
        }
        if (reference == null) {
            NativeGeofenceDiagnostics.record(
                context,
                NativeGeofenceDiagnosticStage.ENQUEUE,
                succeeded = false,
                outcome = "payload_persistence_failed",
                geofenceCount = params.geofences.size
            )
            NativeGeofenceLogger.e(context, TAG, "Failed to persist a callback payload.")
            completion()
            return
        }

        val coordinator = CallbackWorkEnqueueCoordinator(payloadStore::delete)
        coordinator.enqueue(
            payloadReference = reference,
            start = {
                val workRequest = OneTimeWorkRequestBuilder<NativeGeofenceBackgroundWorker>()
                    .setInputData(
                        Data.Builder()
                            .putString(Constants.WORKER_PAYLOAD_REFERENCE_KEY, reference)
                            .build()
                    )
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30L, TimeUnit.SECONDS)
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .build()
                val operation = WorkManager.getInstance(context).enqueueUniqueWork(
                    Constants.GEOFENCE_CALLBACK_WORK_GROUP,
                    ExistingWorkPolicy.APPEND_OR_REPLACE,
                    workRequest
                )
                CallbackEnqueueOperation { observed ->
                    val future = operation.result
                    future.addListener(
                        {
                            try {
                                future.get()
                                observed(Result.success(Unit))
                            } catch (error: InterruptedException) {
                                Thread.currentThread().interrupt()
                                observed(
                                    Result.failure(
                                        CallbackEnqueueUnconfirmedException(error)
                                    )
                                )
                            } catch (error: Throwable) {
                                observed(Result.failure(error))
                            }
                        },
                        DIRECT_EXECUTOR
                    )
                }
            }
        ) { outcome ->
            try {
                when (outcome) {
                    CallbackEnqueueOutcome.ACCEPTED -> {
                        NativeGeofenceDiagnostics.record(
                            context,
                            NativeGeofenceDiagnosticStage.ENQUEUE,
                            succeeded = true,
                            outcome = "work_enqueue_confirmed",
                            geofenceCount = params.geofences.size
                        )
                        NativeGeofenceLogger.d(
                            context,
                            TAG,
                            "Callback work enqueue was confirmed."
                        )
                    }
                    CallbackEnqueueOutcome.REJECTED -> {
                        NativeGeofenceDiagnostics.record(
                            context,
                            NativeGeofenceDiagnosticStage.ENQUEUE,
                            succeeded = false,
                            outcome = "work_enqueue_failed",
                            geofenceCount = params.geofences.size
                        )
                        NativeGeofenceLogger.e(
                            context,
                            TAG,
                            "Callback work enqueue was rejected."
                        )
                    }
                    CallbackEnqueueOutcome.UNCONFIRMED -> {
                        NativeGeofenceDiagnostics.record(
                            context,
                            NativeGeofenceDiagnosticStage.ENQUEUE,
                            succeeded = false,
                            outcome = "work_enqueue_unconfirmed",
                            geofenceCount = params.geofences.size
                        )
                        NativeGeofenceLogger.w(
                            context,
                            TAG,
                            "Callback work enqueue could not be confirmed; payload retained."
                        )
                    }
                }
            } finally {
                completion()
            }
        }
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
                lookup = { id -> NativeGeofencePersistence.getGeofence(context, id) },
                isCallbackFresh = { id ->
                    NativeGeofencePersistence.isCallbackPackageCurrent(context, id)
                }
            )
        )
    }

    private companion object {
        const val TAG = "NativeGeofenceBroadcastReceiver"
        val DIRECT_EXECUTOR = Executor { command -> command.run() }
    }
}
