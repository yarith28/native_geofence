package com.chunkytofustudios.native_geofence.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.Location
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.api.NativeGeofenceApiImpl
import com.chunkytofustudios.native_geofence.generated.ActiveGeofenceWire
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.util.ActiveGeofenceWires
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackWork
import com.chunkytofustudios.native_geofence.util.GeofenceEvents
import com.chunkytofustudios.native_geofence.util.LocationWires
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.location.GeofencingEvent

class NativeGeofenceBroadcastReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "NativeGeofenceBroadcastReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        NativeGeofenceLogger.d(context, TAG, "Geofence broadcast received.")
        NativeGeofenceDiagnostics.recordBroadcastReceived(context)

        val source = Constants.EVENT_SOURCE_ANDROID_GEOFENCING_API
        val geofenceCallbackParams = getGeofenceCallbackParams(context, intent) ?: return
        val claimedParams = claimUndeliveredGeofenceStates(
            context,
            geofenceCallbackParams,
            source
        )
        enqueueGeofenceCallbacks(context, claimedParams, source)
    }

    private fun claimUndeliveredGeofenceStates(
        context: Context,
        params: List<GeofenceCallbackParamsWire>,
        source: String
    ): List<ClaimedGeofenceCallbackParams> {
        return params.mapNotNull { callbackParams ->
            val claims = mutableListOf<DeliveredGeofenceEventClaim>()
            val geofencesToDeliver = callbackParams.geofences.filter { geofence ->
                val claimedAt = System.currentTimeMillis()
                val claimed =
                    NativeGeofencePersistence.claimDeliveredGeofenceEvent(
                        context,
                        geofence.id,
                        callbackParams.event,
                        claimedAt
                    )
                if (claimed) {
                    claims.add(
                        DeliveredGeofenceEventClaim(
                            geofence.id,
                            callbackParams.event,
                            claimedAt
                        )
                    )
                } else {
                    NativeGeofenceLogger.d(
                        context,
                        TAG,
                        "Skipping already-delivered geofence state ID=${geofence.id}, " +
                            "event=${callbackParams.event}, source=$source."
                    )
                }
                claimed
            }

            if (geofencesToDeliver.isEmpty()) {
                NativeGeofenceLogger.d(
                    context,
                    TAG,
                    "No new geofence events to enqueue after state de-dupe: " +
                        "event=${callbackParams.event}, source=$source."
                )
                return@mapNotNull null
            }

            ClaimedGeofenceCallbackParams(
                GeofenceCallbackParamsWire(
                    geofencesToDeliver,
                    callbackParams.event,
                    callbackParams.location,
                    callbackParams.callbackHandle
                ),
                claims
            )
        }
    }

    private fun enqueueGeofenceCallbacks(
        context: Context,
        params: List<ClaimedGeofenceCallbackParams>,
        source: String
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
            for (claimedParams in params) {
                val geofenceCallbackParams = claimedParams.params
                GeofenceCallbackWork.enqueue(context, geofenceCallbackParams, source) { enqueued ->
                    if (!enqueued) {
                        releaseDeliveredGeofenceStateClaims(context, claimedParams.claims)
                    }
                    finishOne()
                }
            }
        } catch (e: Exception) {
            NativeGeofenceDiagnostics.recordCallbackEnqueueFailure(
                context,
                params.firstOrNull()?.event,
                params.flatMap { it.params.geofences.map { geofence -> geofence.id } }.distinct(),
                e.toString()
            )
            NativeGeofenceLogger.e(
                context,
                TAG,
                "Failed while queueing geofence callback work from source=$source; callbacks may be dropped.",
                e
            )
            params.forEach { releaseDeliveredGeofenceStateClaims(context, it.claims) }
            finishPendingResult()
        }
    }

    private fun releaseDeliveredGeofenceStateClaims(
        context: Context,
        claims: List<DeliveredGeofenceEventClaim>
    ) {
        for (claim in claims) {
            NativeGeofencePersistence.releaseDeliveredGeofenceEventClaim(
                context,
                claim.geofenceId,
                claim.event,
                claim.timestampMillis
            )
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
            NativeGeofenceLogger.e(
                context,
                TAG,
                "Failed to re-create persisted geofences after geofence service error: $e",
                e
            )
            pendingResult.finish()
        }
    }

    private data class TriggerDistance(
        val geofenceId: String,
        val distanceMeters: Double,
        val radiusMeters: Double
    )

    private data class ClaimedGeofenceCallbackParams(
        val params: GeofenceCallbackParamsWire,
        val claims: List<DeliveredGeofenceEventClaim>
    ) {
        val event: GeofenceEvent = params.event
    }

    private data class DeliveredGeofenceEventClaim(
        val geofenceId: String,
        val event: GeofenceEvent,
        val timestampMillis: Long
    )
}
