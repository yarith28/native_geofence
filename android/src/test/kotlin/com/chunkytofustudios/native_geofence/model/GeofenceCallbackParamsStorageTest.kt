package com.chunkytofustudios.native_geofence.model

import com.chunkytofustudios.native_geofence.generated.ActiveGeofenceWire
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.LocationWire
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class GeofenceCallbackParamsStorageTest {
    @Test
    fun `preserves event timestamp through queued payload round trip`() {
        val params = callbackParams(
            eventAtMillis = 1_720_000_000_123L,
            eventId = "delivery-123",
        )
        val encoded = Json.encodeToString(GeofenceCallbackParamsStorage.fromWire(params))

        val restored = Json.decodeFromString<GeofenceCallbackParamsStorage>(encoded).toWire()

        assertEquals(1_720_000_000_123L, restored.eventAtMillis)
        assertEquals("delivery-123", restored.eventId)
    }

    @Test
    fun `decodes legacy queued payload without event timestamp`() {
        val encoded = Json.encodeToString(
            GeofenceCallbackParamsStorage.fromWire(callbackParams(eventAtMillis = null))
        )
        assertFalse(encoded.contains("eventAtMillis"))

        val restored = Json.decodeFromString<GeofenceCallbackParamsStorage>(encoded).toWire()

        assertEquals(null, restored.eventAtMillis)
        assertEquals(null, restored.eventId)
    }

    @Test
    fun `preserves callback contexts through queued payload round trip`() {
        val params = callbackParams(
            eventAtMillis = 1_720_000_000_123L,
            callbackContextsByGeofenceId = mapOf("office" to 71L),
        )
        val encoded = Json.encodeToString(GeofenceCallbackParamsStorage.fromWire(params))

        val restored = Json.decodeFromString<GeofenceCallbackParamsStorage>(encoded).toWire()

        assertEquals(mapOf("office" to 71L), restored.callbackContextsByGeofenceId)
    }

    private fun callbackParams(
        eventAtMillis: Long?,
        eventId: String? = null,
        callbackContextsByGeofenceId: Map<String, Long>? = null,
    ): GeofenceCallbackParamsWire =
        GeofenceCallbackParamsWire(
            geofences = listOf(
                ActiveGeofenceWire(
                    id = "office",
                    location = LocationWire(
                        latitude = 11.5,
                        longitude = 104.9,
                        isMock = false,
                    ),
                    radiusMeters = 120.0,
                    triggers = listOf(GeofenceEvent.ENTER),
                )
            ),
            event = GeofenceEvent.ENTER,
            eventAtMillis = eventAtMillis,
            callbackHandle = 42L,
            eventId = eventId,
            callbackContextsByGeofenceId = callbackContextsByGeofenceId,
        )
}
