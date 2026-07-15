package com.chunkytofustudios.native_geofence.model

import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import kotlinx.serialization.Serializable

@Serializable
class GeofenceCallbackParamsStorage(
    private val geofences: List<ActiveGeofenceStorage>,
    private val event: GeofenceEvent,
    private val location: LocationStorage? = null,
    private val eventAtMillis: Long? = null,
    private val callbackHandle: Long,
    private val eventId: String? = null,
    // Defaulted for payload files queued before callback contexts existed.
    private val callbackContextsByGeofenceId: Map<String, Long>? = null,
    // Defaulted for payload files queued before root tracing existed.
    private val traceId: String? = null,
) {
    companion object {
        fun fromWire(e: GeofenceCallbackParamsWire): GeofenceCallbackParamsStorage {
            return GeofenceCallbackParamsStorage(
                geofences = e.geofences.map { ActiveGeofenceStorage.fromWire(it) }.toList(),
                event = e.event,
                location = e.location?.let { LocationStorage.fromWire(it) },
                eventAtMillis = e.eventAtMillis,
                callbackHandle = e.callbackHandle,
                eventId = e.eventId,
                callbackContextsByGeofenceId = e.callbackContextsByGeofenceId,
                traceId = e.traceId,
            )
        }
    }

    fun toWire(): GeofenceCallbackParamsWire {
        return GeofenceCallbackParamsWire(
            geofences = geofences.map { it.toWire() }.toList(),
            event = event,
            location = location?.toWire(),
            eventAtMillis = eventAtMillis,
            callbackHandle = callbackHandle,
            eventId = eventId,
            callbackContextsByGeofenceId = callbackContextsByGeofenceId,
            traceId = traceId,
        )
    }
}
