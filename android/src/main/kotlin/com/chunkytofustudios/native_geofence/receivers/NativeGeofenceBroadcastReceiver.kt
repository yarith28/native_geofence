package com.chunkytofustudios.native_geofence.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.util.ActiveGeofenceWires
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackWork
import com.chunkytofustudios.native_geofence.util.GeofenceEvents
import com.chunkytofustudios.native_geofence.util.LocationWires
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.google.android.gms.location.GeofencingEvent

class NativeGeofenceBroadcastReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "NativeGeofenceBroadcastReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "Geofence broadcast received.")

        val geofenceCallbackParams = getGeofenceCallbackParams(intent) ?: return

        val dedupedParams = removeAlreadyDeliveredGeofenceStates(
            context,
            geofenceCallbackParams
        ) ?: return
        GeofenceCallbackWork.enqueue(context, dedupedParams)
    }

    private fun removeAlreadyDeliveredGeofenceStates(
        context: Context,
        params: GeofenceCallbackParamsWire
    ): GeofenceCallbackParamsWire? {
        val now = System.currentTimeMillis()
        val geofencesToDeliver = params.geofences.filter { geofence ->
            val sameStateDelivered =
                NativeGeofencePersistence.wasSameGeofenceTransitionStateDelivered(
                    context,
                    geofence.id,
                    params.event
                )
            if (sameStateDelivered) {
                Log.d(
                    TAG,
                    "Skipping already-delivered geofence state ID=${geofence.id}, event=${params.event}."
                )
            }
            !sameStateDelivered
        }

        if (geofencesToDeliver.isEmpty()) {
            Log.d(TAG, "No new geofence events to enqueue after state de-dupe.")
            return null
        }

        for (geofence in geofencesToDeliver) {
            NativeGeofencePersistence.recordDeliveredGeofenceEvent(
                context,
                geofence.id,
                params.event,
                now
            )
        }
        return GeofenceCallbackParamsWire(
            geofencesToDeliver,
            params.event,
            params.location,
            params.callbackHandle
        )
    }

    private fun getGeofenceCallbackParams(intent: Intent): GeofenceCallbackParamsWire? {
        val callbackHandle = intent.getLongExtra(Constants.CALLBACK_HANDLE_KEY, 0)
        if (callbackHandle == 0L) {
            Log.e(TAG, "GeofencingEvent callback handle is missing.")
            return null
        }

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

        // Get the geofences that were triggered. A single event can trigger
        // multiple geofences.
        val triggeringGeofences = geofencingEvent.triggeringGeofences?.map {
            ActiveGeofenceWires.fromGeofence(it)
        }
        if (triggeringGeofences.isNullOrEmpty()) {
            Log.e(TAG, "No triggering geofences found.")
            return null
        }

        val location = geofencingEvent.triggeringLocation
        if (location == null) {
            Log.w(TAG, "No triggering location found.")
        }

        return GeofenceCallbackParamsWire(
            triggeringGeofences,
            geofenceEvent,
            location?.let { LocationWires.fromLocation(it) },
            callbackHandle
        )
    }
}
