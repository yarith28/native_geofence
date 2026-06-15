package com.chunkytofustudios.native_geofence.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.Location
import androidx.core.content.ContextCompat
import androidx.work.BackoffPolicy
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.NativeGeofenceBackgroundWorker
import com.chunkytofustudios.native_geofence.api.NativeGeofenceApiImpl
import com.chunkytofustudios.native_geofence.generated.ActiveGeofenceWire
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.model.GeofenceCallbackParamsStorage
import com.chunkytofustudios.native_geofence.util.ActiveGeofenceWires
import com.chunkytofustudios.native_geofence.util.GeofenceEvents
import com.chunkytofustudios.native_geofence.util.LocationWires
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofenceStatusCodes
import java.util.concurrent.TimeUnit
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class NativeGeofenceBroadcastReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "NativeGeofenceBroadcastReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        NativeGeofenceLogger.d(context, TAG, "Geofence broadcast received.")
        NativeGeofenceDiagnostics.recordBroadcastReceived(context)

        val geofenceCallbackParams = getGeofenceCallbackParams(context, intent) ?: return
        enqueueGeofenceCallbacks(context, geofenceCallbackParams)
    }

    private fun enqueueGeofenceCallbacks(
        context: Context,
        params: List<GeofenceCallbackParamsWire>
    ) {
        if (params.isEmpty()) {
            return
        }

        // Keep the broadcast alive long enough to enqueue all callback work.
        val pendingResult = goAsync()
        val lock = Object()
        var remaining = params.size
        var finished = false

        fun finishPendingResult() {
            synchronized(lock) {
                if (!finished) {
                    finished = true
                    pendingResult.finish()
                }
            }
        }

        fun finishOne() {
            synchronized(lock) {
                if (finished) {
                    return
                }
                remaining -= 1
                if (remaining == 0) {
                    finished = true
                    pendingResult.finish()
                }
            }
        }

        try {
            val workManager = WorkManager.getInstance(context)
            for (geofenceCallbackParams in params) {
                val geofenceIdList = geofenceCallbackParams.geofences.map { it.id }
                val geofenceIds = geofenceIdList.joinToString(",")
                NativeGeofenceDiagnostics.recordCallbackEnqueueAttempt(
                    context,
                    geofenceCallbackParams.event,
                    geofenceIdList
                )
                NativeGeofenceLogger.i(
                    context,
                    TAG,
                    "Queueing geofence callback work: event=${geofenceCallbackParams.event}, " +
                        "ids=$geofenceIds, callbackHandle=${geofenceCallbackParams.callbackHandle}, " +
                        "hasLocation=${geofenceCallbackParams.location != null}."
                )

                val jsonData =
                    Json.encodeToString(GeofenceCallbackParamsStorage.fromWire(geofenceCallbackParams))
                val workRequest = OneTimeWorkRequestBuilder<NativeGeofenceBackgroundWorker>()
                    .setInputData(
                        Data.Builder().putString(Constants.WORKER_PAYLOAD_KEY, jsonData).build()
                    )
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .build()

                val work = workManager.beginUniqueWork(
                    Constants.GEOFENCE_CALLBACK_WORK_GROUP,
                    // Process geofence callbacks sequentially without letting a failed
                    // historical chain poison future geofence events.
                    ExistingWorkPolicy.APPEND_OR_REPLACE,
                    workRequest
                )
                val enqueueResult = work.enqueue().result
                enqueueResult.addListener(
                    {
                        try {
                            enqueueResult.get()
                            NativeGeofenceLogger.d(
                                context,
                                TAG,
                                "Enqueued geofence callback work: event=${geofenceCallbackParams.event}, " +
                                    "ids=$geofenceIds."
                            )
                        } catch (e: Exception) {
                            NativeGeofenceDiagnostics.recordCallbackEnqueueFailure(
                                context,
                                geofenceCallbackParams.event,
                                geofenceIdList,
                                e.toString()
                            )
                            NativeGeofenceLogger.e(
                                context,
                                TAG,
                                "Failed to enqueue geofence callback work: " +
                                    "event=${geofenceCallbackParams.event}, ids=$geofenceIds.",
                                e
                            )
                        } finally {
                            finishOne()
                        }
                    },
                    ContextCompat.getMainExecutor(context)
                )
            }
        } catch (e: Exception) {
            NativeGeofenceDiagnostics.recordCallbackEnqueueFailure(
                context,
                params.firstOrNull()?.event,
                params.flatMap { it.geofences.map { geofence -> geofence.id } }.distinct(),
                e.toString()
            )
            NativeGeofenceLogger.e(context, TAG, "Failed while queueing geofence callback work; callbacks may be dropped.", e)
            finishPendingResult()
        }
    }

    private fun getGeofenceCallbackParams(
        context: Context,
        intent: Intent
    ): List<GeofenceCallbackParamsWire>? {
        val geofencingEvent = GeofencingEvent.fromIntent(intent)
        if (geofencingEvent == null) {
            NativeGeofenceDiagnostics.recordBroadcastError(
                context,
                "NULL_GEOFENCING_EVENT",
                "GeofencingEvent.fromIntent returned null."
            )
            NativeGeofenceLogger.e(context, TAG, "GeofencingEvent is null.")
            return null
        }
        if (geofencingEvent.hasError()) {
            NativeGeofenceDiagnostics.recordBroadcastError(
                context,
                "GeofenceStatusCodes=${geofencingEvent.errorCode}",
                "GeofencingEvent has error Code=${geofencingEvent.errorCode}."
            )
            NativeGeofenceLogger.e(context, TAG, "GeofencingEvent has error Code=${geofencingEvent.errorCode}.")
            if (geofencingEvent.errorCode == GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE) {
                reCreatePersistedGeofences(context)
            }
            return null
        }

        // Get the transition type.
        val geofenceEvent = GeofenceEvents.fromInt(geofencingEvent.geofenceTransition)
        if (geofenceEvent == null) {
            NativeGeofenceDiagnostics.recordBroadcastError(
                context,
                "INVALID_TRANSITION",
                "GeofencingEvent has invalid transition ID=${geofencingEvent.geofenceTransition}."
            )
            NativeGeofenceLogger.e(
                context,
                TAG,
                "GeofencingEvent has invalid transition ID=${geofencingEvent.geofenceTransition}."
            )
            return null
        }

        // Get the geofences that were triggered. A single event can trigger
        // multiple geofences.
        val triggeringGeofences = geofencingEvent.triggeringGeofences?.map {
            ActiveGeofenceWires.fromGeofence(it)
        }
        if (triggeringGeofences.isNullOrEmpty()) {
            NativeGeofenceDiagnostics.recordBroadcastError(
                context,
                "NO_TRIGGERING_GEOFENCES",
                "GeofencingEvent had no triggering geofences."
            )
            NativeGeofenceLogger.e(context, TAG, "No triggering geofences found.")
            return null
        }
        NativeGeofenceDiagnostics.recordBroadcastEvent(
            context,
            geofenceEvent,
            triggeringGeofences.map { it.id }
        )

        val location = geofencingEvent.triggeringLocation
        if (location == null) {
            NativeGeofenceLogger.w(context, TAG, "No triggering location found.")
        } else {
            recordTriggerLocation(context, location, triggeringGeofences)
        }

        val fallbackCallbackHandle = intent.getLongExtra(Constants.CALLBACK_HANDLE_KEY, 0)
        // Android can report multiple geofences in one transition; split them by
        // callback so each registered Dart handler receives only its own regions.
        val geofencesByCallbackHandle = linkedMapOf<Long, MutableList<ActiveGeofenceWire>>()
        for (geofence in triggeringGeofences) {
            val callbackHandle =
                NativeGeofencePersistence.getGeofence(context, geofence.id)?.callbackHandle
                    ?: fallbackCallbackHandle
            if (callbackHandle == 0L) {
                NativeGeofenceLogger.e(context, TAG, "Callback handle for Geofence ID=${geofence.id} is missing.")
                continue
            }
            geofencesByCallbackHandle.getOrPut(callbackHandle) { mutableListOf() }.add(geofence)
        }

        if (geofencesByCallbackHandle.isEmpty()) {
            NativeGeofenceDiagnostics.recordBroadcastError(
                context,
                "NO_CALLBACK_HANDLE",
                "No callback handles could be resolved for triggered geofences."
            )
            NativeGeofenceLogger.e(context, TAG, "No geofence callbacks could be resolved.")
            return null
        }

        return geofencesByCallbackHandle.map { (callbackHandle, geofences) ->
            GeofenceCallbackParamsWire(
                geofences,
                geofenceEvent,
                location?.let { LocationWires.fromLocation(it) },
                callbackHandle
            )
        }
    }

    private fun recordTriggerLocation(
        context: Context,
        location: Location,
        triggeringGeofences: List<ActiveGeofenceWire>
    ) {
        val nearest = triggeringGeofences.map { geofence ->
            val distance = FloatArray(1)
            Location.distanceBetween(
                location.latitude,
                location.longitude,
                geofence.location.latitude,
                geofence.location.longitude,
                distance
            )
            TriggerDistance(
                geofence.id,
                distance[0].toDouble(),
                geofence.radiusMeters
            )
        }.minByOrNull { it.distanceMeters }

        NativeGeofenceDiagnostics.recordBroadcastLocation(
            context,
            location.latitude,
            location.longitude,
            nearest?.geofenceId,
            nearest?.distanceMeters,
            nearest?.radiusMeters
        )
        NativeGeofenceLogger.i(
            context,
            TAG,
            "Triggering location: latitude=${location.latitude}, longitude=${location.longitude}, " +
                "nearestGeofenceId=${nearest?.geofenceId}, " +
                "distanceFromNearestMeters=${nearest?.distanceMeters}, " +
                "nearestRadiusMeters=${nearest?.radiusMeters}."
        )
    }

    private fun reCreatePersistedGeofences(context: Context) {
        // GEOFENCE_NOT_AVAILABLE can leave registrations unreliable; rebuild best-effort.
        val pendingResult = goAsync()
        try {
            NativeGeofenceApiImpl(context.applicationContext).reCreateAfterReboot(
                reason = "geofence_not_available"
            ) {
                pendingResult.finish()
            }
        } catch (e: Exception) {
            NativeGeofenceLogger.e(context, TAG, "Failed to re-create persisted geofences after geofence service error: $e", e)
            pendingResult.finish()
        }
    }

    private data class TriggerDistance(
        val geofenceId: String,
        val distanceMeters: Double,
        val radiusMeters: Double
    )
}
