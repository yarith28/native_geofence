package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.generated.LocationWire

internal data class GeofenceCallbackRoutingResult(
    val callbackGroups: List<GeofenceCallbackParamsWire>,
    val orphanIds: List<String>,
    val staleIds: List<String> = emptyList()
)

internal object GeofenceCallbackRouting {
    /**
     * Resolve every triggered request ID through durable canonical storage and
     * preserve the first-seen callback order for deterministic queueing.
     */
    fun route(
        triggeredIds: List<String>,
        event: GeofenceEvent,
        location: LocationWire?,
        eventAtMillis: Long,
        lookup: (String) -> GeofenceWire?
    ): GeofenceCallbackRoutingResult {
        val grouped = linkedMapOf<Long, MutableList<GeofenceWire>>()
        val orphanIds = mutableListOf<String>()
        triggeredIds.distinct().forEach { id ->
            val configured = lookup(id)
            if (configured == null) {
                orphanIds.add(id)
                return@forEach
            }
            if (configured.callbackHandle == 0L) {
                orphanIds.add(id)
                return@forEach
            }
            grouped.getOrPut(configured.callbackHandle) { mutableListOf() }.add(configured)
        }

        return GeofenceCallbackRoutingResult(
            callbackGroups = grouped.map { (callbackHandle, geofences) ->
                GeofenceCallbackParamsWire(
                    geofences = geofences.map(ActiveGeofenceWires::fromGeofenceWire),
                    event = event,
                    location = location,
                    eventAtMillis = eventAtMillis,
                    callbackHandle = callbackHandle,
                    eventId = null
                )
            },
            orphanIds = orphanIds
        )
    }
}
