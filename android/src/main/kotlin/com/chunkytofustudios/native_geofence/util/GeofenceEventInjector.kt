package com.chunkytofustudios.native_geofence.util

import android.content.Context
import android.location.Location
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent

/**
 * Feeds an externally-confirmed geofence transition through native_geofence's
 * normal de-dupe + dispatch pipeline.
 *
 * This is a generic integration hook for higher layers: they detect a crossing
 * their own way, then call this so the event is delivered to the app's geofence
 * callback exactly like an OS geofence event, sharing the same de-dupe state,
 * so an injected event and the OS event for the same transition never
 * double-fire.
 */
object GeofenceEventInjector {
    private const val TAG = "GeofenceEventInjector"

    /**
     * @param geofenceId the registered geofence's id.
     * @param event the confirmed transition.
     * @param location optional location to attach to the event.
     * @param source source label for logging and diagnostics.
     * @param onFinished called after WorkManager reports whether the enqueue
     *         completed.
     * @return true if the event was accepted for enqueue, false if dropped
     *         before enqueue (unknown id, unsupported trigger, or
     *         already-delivered state).
     */
    @JvmStatic
    fun inject(
        context: Context,
        geofenceId: String,
        event: GeofenceEvent,
        location: Location?,
        isMock: Boolean = false,
        source: String = Constants.EVENT_SOURCE_EXTERNAL_INJECTION,
        onFinished: ((Boolean) -> Unit)? = null,
    ): Boolean {
        val appContext = context.applicationContext
        val fence = NativeGeofencePersistence.getGeofence(appContext, geofenceId)
        if (fence == null) {
            NativeGeofenceLogger.w(appContext, TAG, "Inject ignored: unknown geofence ID=$geofenceId source=$source.")
            return false
        }
        if (!fence.triggers.contains(event)) {
            NativeGeofenceLogger.d(appContext, TAG, "Inject ignored: $event not configured for ID=$geofenceId source=$source.")
            return false
        }
        val claimedAt = System.currentTimeMillis()
        if (!NativeGeofencePersistence.claimDeliveredGeofenceEvent(
                appContext,
                geofenceId,
                event,
                claimedAt
            )) {
            NativeGeofenceLogger.d(appContext, TAG, "Inject de-duped: ID=$geofenceId event=$event source=$source already delivered.")
            return false
        }

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
        GeofenceCallbackWork.enqueue(appContext, params, source) { enqueued ->
            if (!enqueued) {
                NativeGeofencePersistence.releaseDeliveredGeofenceEventClaim(
                    appContext,
                    geofenceId,
                    event,
                    claimedAt
                )
            }
            onFinished?.invoke(enqueued)
        }
        NativeGeofenceLogger.i(appContext, TAG, "Queued injected geofence event ID=$geofenceId event=$event source=$source.")
        return true
    }
}
