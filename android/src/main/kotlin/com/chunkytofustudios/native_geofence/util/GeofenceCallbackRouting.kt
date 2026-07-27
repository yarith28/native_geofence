package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.generated.LocationWire

internal data class GeofenceCallbackRoutingResult(
    val callbackGroups: List<GeofenceCallbackParamsWire>,
    val orphanIds: List<String>,
    val staleIds: List<String> = emptyList(),
    val staleCallbackGroups: List<GeofenceCallbackParamsWire> = emptyList(),
)

internal data class GeofenceCallbackRegistration(
    val configuredGeofence: GeofenceWire,
    val expirationDeadlineMillis: Long?,
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
        eventAtMillis: Long?,
        isCallbackFresh: (String) -> Boolean = { true },
        lookup: (String) -> GeofenceCallbackRegistration?
    ): GeofenceCallbackRoutingResult {
        val grouped = linkedMapOf<Long, MutableList<GeofenceCallbackRegistration>>()
        val staleGrouped = linkedMapOf<Long, MutableList<GeofenceCallbackRegistration>>()
        val orphanIds = mutableListOf<String>()
        val staleIds = mutableListOf<String>()
        triggeredIds.distinct().forEach { id ->
            val registration = lookup(id)
            if (registration == null) {
                orphanIds.add(id)
                return@forEach
            }
            val configured = registration.configuredGeofence
            if (configured.callbackHandle == 0L) {
                orphanIds.add(id)
                return@forEach
            }
            if (!isCallbackFresh(id)) {
                staleIds.add(id)
                staleGrouped.getOrPut(configured.callbackHandle) { mutableListOf() }
                    .add(registration)
                return@forEach
            }
            grouped.getOrPut(configured.callbackHandle) { mutableListOf() }.add(registration)
        }

        return GeofenceCallbackRoutingResult(
            callbackGroups = callbackGroups(
                grouped,
                event,
                location,
                eventAtMillis,
            ),
            orphanIds = orphanIds,
            staleIds = staleIds,
            staleCallbackGroups = callbackGroups(
                staleGrouped,
                event,
                location,
                eventAtMillis,
            ),
        )
    }

    private fun callbackGroups(
        grouped: Map<Long, List<GeofenceCallbackRegistration>>,
        event: GeofenceEvent,
        location: LocationWire?,
        eventAtMillis: Long?,
    ): List<GeofenceCallbackParamsWire> =
        grouped.map { (callbackHandle, geofences) ->
            val callbackContexts = geofences.mapNotNull { registration ->
                val geofence = registration.configuredGeofence
                geofence.callbackContext?.let { geofence.id to it }
            }.toMap()
            GeofenceCallbackParamsWire(
                geofences = geofences.map { registration ->
                    ActiveGeofenceWires.fromGeofenceWire(
                        registration.configuredGeofence,
                        registration.expirationDeadlineMillis,
                    )
                },
                event = event,
                location = location,
                eventAtMillis = eventAtMillis,
                callbackHandle = callbackHandle,
                eventId = null,
                callbackContextsByGeofenceId = callbackContexts.ifEmpty { null }
            )
        }
}
