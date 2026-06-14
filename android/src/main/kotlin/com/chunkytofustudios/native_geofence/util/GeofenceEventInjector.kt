package com.chunkytofustudios.native_geofence.util

import android.content.Context
import android.location.Location
import android.util.Log
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent

/**
 * Feeds an externally-confirmed geofence transition through native_geofence's
 * normal de-dupe + dispatch pipeline.
 *
 * This is a generic integration hook for higher layers: they detect a crossing
 * their own way, then call this so the event is delivered to the app's geofence
 * callback exactly like an OS geofence event — sharing the same de-dupe state,
 * so an injected event and the OS event for the same transition never
 * double-fire.
 */
object GeofenceEventInjector {
    private const val TAG = "GeofenceEventInjector"

    /**
     * @param geofenceId the registered geofence's id.
     * @param event the confirmed transition.
     * @param location optional location to attach to the event.
     * @return true if an event was enqueued, false if dropped (unknown id or
     *         already-delivered state).
     */
    @JvmStatic
    fun inject(
        context: Context,
        geofenceId: String,
        event: GeofenceEvent,
        location: Location?,
        isMock: Boolean = false,
    ): Boolean {
        val appContext = context.applicationContext
        val fence = NativeGeofencePersistence.getAllGeofences(appContext)
            .firstOrNull { it.id == geofenceId }
        if (fence == null) {
            Log.w(TAG, "Inject ignored: unknown geofence ID=$geofenceId.")
            return false
        }
        if (!fence.triggers.contains(event)) {
            Log.d(TAG, "Inject ignored: $event not configured for ID=$geofenceId.")
            return false
        }
        if (NativeGeofencePersistence.wasSameGeofenceTransitionStateDelivered(
                appContext, geofenceId, event
            )
        ) {
            Log.d(TAG, "Inject de-duped: ID=$geofenceId event=$event already delivered.")
            return false
        }

        NativeGeofencePersistence.recordDeliveredGeofenceEvent(appContext, geofenceId, event)
        // Build the wire with the out-of-band mock flag: a constructed Location
        // cannot carry the OS mock state, so the caller passes it explicitly.
        val locationWire = location?.let {
            LocationWires.of(
                it.latitude,
                it.longitude,
                if (it.hasAccuracy()) it.accuracy.toDouble() else null,
                isMock,
            )
        }
        val params = GeofenceCallbackParamsWire(
            listOf(ActiveGeofenceWires.fromGeofenceWire(fence)),
            event,
            locationWire,
            fence.callbackHandle,
        )
        GeofenceCallbackWork.enqueue(appContext, params)
        Log.i(TAG, "Injected geofence event ID=$geofenceId event=$event.")
        return true
    }
}
