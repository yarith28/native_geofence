package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.AndroidGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.generated.IosGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.LocationWire
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class GeofenceCallbackRoutingTest {
    @Test
    fun `one broadcast splits registrations by persisted callback handle`() {
        val registrations = mapOf(
            "a" to geofence("a", 10),
            "b" to geofence("b", 20)
        )

        val routed = route(listOf("a", "b"), registrations)

        assertEquals(listOf(10L, 20L), routed.callbackGroups.map { it.callbackHandle })
        assertEquals(listOf(listOf("a"), listOf("b")), routed.callbackGroups.map(::ids))
        assertTrue(routed.callbackGroups.all { it.eventAtMillis == 123_456L })
        assertTrue(routed.orphanIds.isEmpty())
        assertTrue(routed.staleIds.isEmpty())
    }

    @Test
    fun `registrations sharing a callback are delivered as one group`() {
        val registrations = mapOf(
            "a" to geofence("a", 10),
            "b" to geofence("b", 10)
        )

        val routed = route(listOf("a", "b", "a"), registrations)

        assertEquals(1, routed.callbackGroups.size)
        assertEquals(10L, routed.callbackGroups.single().callbackHandle)
        assertEquals(listOf("a", "b"), ids(routed.callbackGroups.single()))
    }

    @Test
    fun `contexts remain keyed per geofence within a callback group`() {
        val registrations = mapOf(
            "a" to geofence("a", 10, callbackContext = 101),
            "b" to geofence("b", 10),
            "c" to geofence("c", 10, callbackContext = 303)
        )

        val routed = route(listOf("a", "b", "c"), registrations).callbackGroups.single()

        assertEquals(mapOf("a" to 101L, "c" to 303L), routed.callbackContextsByGeofenceId)
    }

    @Test
    fun `missing registrations and zero callback handles are classified as orphans`() {
        val registrations = mapOf("zero" to geofence("zero", 0))

        val routed = route(listOf("missing", "zero", "missing"), registrations)

        assertTrue(routed.callbackGroups.isEmpty())
        assertEquals(listOf("missing", "zero"), routed.orphanIds)
        assertTrue(routed.staleIds.isEmpty())
    }

    @Test
    fun `newly persisted inactive registration is available to immediate events`() {
        val backend = TestGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { 1_000L }
        val configured = geofence("immediate", 42)
        assertTrue(
            store.saveConfiguredGeofence(
                configured,
                recoveryEligible = true,
                active = false
            )
        )

        val routed = GeofenceCallbackRouting.route(
            triggeredIds = listOf("immediate"),
            event = GeofenceEvent.ENTER,
            location = null,
            eventAtMillis = 1_001L
        ) { id -> store.getConfiguredGeofence(id)?.configuredGeofence }

        assertEquals(42L, routed.callbackGroups.single().callbackHandle)
        assertEquals(listOf("immediate"), ids(routed.callbackGroups.single()))
        assertTrue(routed.orphanIds.isEmpty())
    }

    @Test
    fun `lookup classifies orphans before freshness and keeps stale ids separate`() {
        val registrations = mapOf(
            "zero" to geofence("zero", 0),
            "old" to geofence("old", 17),
            "current" to geofence("current", 17)
        )
        val freshnessChecks = mutableListOf<String>()
        val routed = GeofenceCallbackRouting.route(
            triggeredIds = listOf("missing", "zero", "old", "current", "old"),
            event = GeofenceEvent.ENTER,
            location = null,
            eventAtMillis = 99L,
            lookup = registrations::get,
            isCallbackFresh = { id ->
                freshnessChecks += id
                id == "current"
            }
        )

        assertEquals(listOf("current"), ids(routed.callbackGroups.single()))
        assertEquals(listOf("missing", "zero"), routed.orphanIds)
        assertEquals(listOf("old"), routed.staleIds)
        assertEquals(listOf("old", "current"), freshnessChecks)
    }

    private fun route(
        ids: List<String>,
        registrations: Map<String, GeofenceWire>
    ) = GeofenceCallbackRouting.route(
        triggeredIds = ids,
        event = GeofenceEvent.EXIT,
        location = null,
        eventAtMillis = 123_456L,
        lookup = registrations::get
    )

    private fun ids(params: com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire) =
        params.geofences.map { it.id }

    private fun geofence(
        id: String,
        callbackHandle: Long,
        callbackContext: Long? = null
    ) = GeofenceWire(
        id = id,
        location = LocationWire(
            latitude = 11.0,
            longitude = 104.0,
            accuracyMeters = null,
            isMock = false
        ),
        radiusMeters = 100.0,
        triggers = listOf(GeofenceEvent.ENTER, GeofenceEvent.EXIT),
        iosSettings = IosGeofenceSettingsWire(initialTrigger = false),
        androidSettings = AndroidGeofenceSettingsWire(
            initialTriggers = emptyList(),
            expirationDurationMillis = null,
            loiteringDelayMillis = 0,
            notificationResponsivenessMillis = null
        ),
        callbackHandle = callbackHandle,
        callbackContext = callbackContext
    )
}

private class TestGeofencePersistenceBackend : GeofencePersistenceBackend {
    private val values = mutableMapOf<String, Any>()

    override fun keys(): Set<String> = values.keys.toSet()
    override fun contains(key: String): Boolean = values.containsKey(key)
    override fun getString(key: String): String? = values[key] as? String

    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String): Set<String>? = values[key] as? Set<String>

    override fun getLong(key: String, defaultValue: Long): Long =
        values[key] as? Long ?: defaultValue

    override fun getBoolean(key: String, defaultValue: Boolean): Boolean =
        values[key] as? Boolean ?: defaultValue

    override fun edit(block: GeofencePersistenceEditor.() -> Unit): Boolean {
        val editor = object : GeofencePersistenceEditor {
            override fun putString(key: String, value: String) {
                values[key] = value
            }

            override fun putStringSet(key: String, value: Set<String>) {
                values[key] = value.toSet()
            }

            override fun putLong(key: String, value: Long) {
                values[key] = value
            }

            override fun putBoolean(key: String, value: Boolean) {
                values[key] = value
            }

            override fun remove(key: String) {
                values.remove(key)
            }
        }
        editor.block()
        return true
    }
}
