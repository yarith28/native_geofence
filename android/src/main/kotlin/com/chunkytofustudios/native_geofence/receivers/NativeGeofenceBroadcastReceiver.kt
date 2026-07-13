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
import com.chunkytofustudios.native_geofence.model.GeofenceCallbackParamsStorage
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackRouting
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackRoutingResult
import com.chunkytofustudios.native_geofence.util.GeofenceEvents
import com.chunkytofustudios.native_geofence.util.LocationWires
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.google.android.gms.location.GeofencingEvent
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class NativeGeofenceBroadcastReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "NativeGeofenceBroadcastReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "Geofence broadcast received.")

        val routing = getGeofenceCallbackParams(context, intent) ?: return
        if (routing.orphanIds.isNotEmpty()) {
            Log.w(
                TAG,
                "Triggered geofences without usable durable registrations were classified as orphans."
            )
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

    private fun getGeofenceCallbackParams(
        context: Context,
        intent: Intent
    ): GeofenceCallbackRoutingResult? {
        val geofencingEvent = GeofencingEvent.fromIntent(intent)
        if (geofencingEvent == null) {
            Log.e(TAG, "GeofencingEvent is null.")
            return null
        }
        if (geofencingEvent.hasError()) {
            Log.e(TAG, "GeofencingEvent has error Code=${geofencingEvent.errorCode}.")
            return null
        }

        // Get the transition type.
        val geofenceEvent = GeofenceEvents.fromInt(geofencingEvent.geofenceTransition)
        if (geofenceEvent == null) {
            Log.e(
                TAG,
                "GeofencingEvent has invalid transition ID=${geofencingEvent.geofenceTransition}."
            )
            return null
        }

        val eventAtMillis = System.currentTimeMillis()

        val triggeringIds = geofencingEvent.triggeringGeofences?.map { it.requestId }
        if (triggeringIds.isNullOrEmpty()) {
            Log.e(TAG, "No triggering geofences found.")
            return null
        }

        val location = geofencingEvent.triggeringLocation
        if (location == null) {
            Log.w(TAG, "No triggering location found.")
        }

        return GeofenceCallbackRouting.route(
            triggeredIds = triggeringIds,
            event = geofenceEvent,
            location = location?.let { LocationWires.fromLocation(it) },
            eventAtMillis = eventAtMillis,
            lookup = { id -> NativeGeofencePersistence.getGeofence(context, id) }
        )
    }
}
