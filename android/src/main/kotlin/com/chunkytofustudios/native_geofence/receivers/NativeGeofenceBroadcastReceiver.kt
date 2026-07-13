package com.chunkytofustudios.native_geofence.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.NativeGeofenceBackgroundWorker
import com.chunkytofustudios.native_geofence.api.NativeGeofenceApiImpl
import com.chunkytofustudios.native_geofence.model.GeofenceCallbackParamsStorage
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackRouting
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackRoutingResult
import com.chunkytofustudios.native_geofence.util.GeofenceEvents
import com.chunkytofustudios.native_geofence.util.GeofenceMutationQueues
import com.chunkytofustudios.native_geofence.util.GeofenceMutationRunner
import com.chunkytofustudios.native_geofence.util.LocationWires
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.chunkytofustudios.native_geofence.util.OrphanedGeofenceCleanupCoordinator
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.location.LocationServices
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

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
    companion object {
        private const val TAG = "NativeGeofenceBroadcastReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "Geofence broadcast received.")

        val routing = when (val outcome = getGeofenceBroadcastOutcome(context, intent)) {
            is GeofenceBroadcastOutcome.Callbacks -> outcome.routing
            GeofenceBroadcastOutcome.GeofenceNotAvailable -> {
                startNotAvailableRecovery(context)
                return
            }
            GeofenceBroadcastOutcome.Ignored -> return
        }
        if (routing.orphanIds.isNotEmpty()) {
            cleanupOrphans(context, routing.orphanIds)
        }
        if (routing.callbackGroups.isEmpty()) {
            Log.e(TAG, "No triggered geofences could be resolved through durable storage.")
            return
        }

        routing.callbackGroups.forEach { geofenceCallbackParams ->
            val jsonData =
                Json.encodeToString(GeofenceCallbackParamsStorage.fromWire(geofenceCallbackParams))
            val workRequest = OneTimeWorkRequestBuilder<NativeGeofenceBackgroundWorker>()
                .setInputData(Data.Builder().putString(Constants.WORKER_PAYLOAD_KEY, jsonData).build())
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()

            val workManager = WorkManager.getInstance(context)
            val work = workManager.beginUniqueWork(
                Constants.GEOFENCE_CALLBACK_WORK_GROUP,
                // Process every callback-handle group sequentially.
                ExistingWorkPolicy.APPEND,
                workRequest
            )
            work.enqueue()
        }
    }

    private fun startNotAvailableRecovery(context: Context) {
        val applicationContext = context.applicationContext
        val lease = RecoveryBroadcastLease(goAsync())
        try {
            NativeGeofenceApiImpl(applicationContext).startAutomaticRecovery(
                reason = "geofence_not_available"
            ) { result ->
                try {
                    result.exceptionOrNull()?.let { error ->
                        Log.e(TAG, "GEOFENCE_NOT_AVAILABLE recovery failed.", error)
                    }
                } finally {
                    lease.finish()
                }
            }
        } catch (error: Throwable) {
            Log.e(TAG, "Failed to start GEOFENCE_NOT_AVAILABLE recovery.", error)
            lease.finish()
        }
    }

    private fun cleanupOrphans(context: Context, orphanIds: List<String>) {
        val applicationContext = context.applicationContext
        val geofencingClient = LocationServices.getGeofencingClient(applicationContext)
        val mutationRunner = GeofenceMutationRunner(
            GeofenceMutationQueues.forContext(applicationContext) { error ->
                Log.e(TAG, "Unhandled orphan cleanup mutation failure.", error)
            }
        ) { error ->
            Log.e(TAG, "Orphan cleanup callback threw an exception.", error)
        }
        val coordinator = OrphanedGeofenceCleanupCoordinator(
            mutationRunner = mutationRunner,
            lookup = { id -> NativeGeofencePersistence.getGeofence(applicationContext, id) },
            markForPlatformCleanup = { id ->
                NativeGeofencePersistence.markGeofenceForPlatformCleanup(applicationContext, id)
            },
            removeFromPlatform = { id, complete ->
                geofencingClient.removeGeofences(listOf(id))
                    .addOnSuccessListener { complete(Result.success(Unit)) }
                    .addOnFailureListener { complete(Result.failure(it)) }
            },
            clearDurableState = { id ->
                NativeGeofencePersistence.removeGeofence(applicationContext, id)
            }
        )

        orphanIds.forEach { id ->
            coordinator.cleanup(id) { result ->
                result.onFailure { error ->
                    Log.e(TAG, "Failed to clean an orphaned geofence ID=$id.", error)
                }
            }
        }
    }

    private fun getGeofenceBroadcastOutcome(
        context: Context,
        intent: Intent
    ): GeofenceBroadcastOutcome {
        val geofencingEvent = GeofencingEvent.fromIntent(intent)
        if (geofencingEvent == null) {
            Log.e(TAG, "GeofencingEvent is null.")
            return GeofenceBroadcastOutcome.Ignored
        }
        if (geofencingEvent.hasError()) {
            Log.e(TAG, "GeofencingEvent has error Code=${geofencingEvent.errorCode}.")
            return GeofenceBroadcastOutcomeClassifier.fromErrorCode(geofencingEvent.errorCode)
        }

        // Get the transition type.
        val geofenceEvent = GeofenceEvents.fromInt(geofencingEvent.geofenceTransition)
        if (geofenceEvent == null) {
            Log.e(
                TAG,
                "GeofencingEvent has invalid transition ID=${geofencingEvent.geofenceTransition}."
            )
            return GeofenceBroadcastOutcome.Ignored
        }

        val eventAtMillis = System.currentTimeMillis()

        val triggeringIds = geofencingEvent.triggeringGeofences?.map { it.requestId }
        if (triggeringIds.isNullOrEmpty()) {
            Log.e(TAG, "No triggering geofences found.")
            return GeofenceBroadcastOutcome.Ignored
        }

        val location = geofencingEvent.triggeringLocation
        if (location == null) {
            Log.w(TAG, "No triggering location found.")
        }

        return GeofenceBroadcastOutcome.Callbacks(
            GeofenceCallbackRouting.route(
                triggeredIds = triggeringIds,
                event = geofenceEvent,
                location = location?.let { LocationWires.fromLocation(it) },
                eventAtMillis = eventAtMillis,
                lookup = { id -> NativeGeofencePersistence.getGeofence(context, id) },
                isCallbackFresh = { id ->
                    NativeGeofencePersistence.isCallbackPackageCurrent(context, id)
                }
            )
        )
    }
}
