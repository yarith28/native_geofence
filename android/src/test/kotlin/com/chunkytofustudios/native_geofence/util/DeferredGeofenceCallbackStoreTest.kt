package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.ActiveGeofenceWire
import com.chunkytofustudios.native_geofence.generated.AndroidGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.generated.IosGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.LocationWire
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class DeferredGeofenceCallbackStoreTest {
    @Test
    fun `deferred callback preserves its batch and delivery route`() {
        val store = DeferredGeofenceCallbackStore(
            backend = MemoryDeferredCallbackBackend(),
            nowMillis = { 123L },
        )

        assertEquals(
            DeferredGeofenceCallbackStoreResult.STORED,
            store.defer(
                request(
                    params(
                        active("a"),
                        active("b"),
                        eventId = "root-event",
                        contexts = mapOf("a" to 11L, "b" to 22L),
                    ),
                    route = "final_dart_callback",
                    source = "smart_geofence",
                )
            ),
        )

        val envelope = assertIs<DeferredGeofenceCallbackReadResult.Found>(
            store.snapshot(),
        ).entries.single()
        assertEquals(listOf("a", "b"), envelope.toWire().geofences.map { it.id })
        assertEquals("root-event", envelope.toWire().eventId)
        assertEquals(mapOf("a" to 11L, "b" to 22L), envelope.toWire().callbackContextsByGeofenceId)
        assertEquals("final_dart_callback", envelope.deliveryRoute)
        assertEquals("smart_geofence", envelope.deliverySource)
        assertEquals(setOf("a", "b"), envelope.rootGeofenceIds())
        assertEquals(123L, envelope.deferredAtMillis)
    }

    @Test
    fun `deferred events survive store recreation and duplicate ids stay singular`() {
        val backend = MemoryDeferredCallbackBackend()
        val first = DeferredGeofenceCallbackStore(
            backend = backend,
            nowMillis = { 123L },
        )
        val deferred = request(params(active("office"), eventId = "event-1"))

        assertEquals(
            DeferredGeofenceCallbackStoreResult.STORED,
            first.defer(deferred),
        )
        assertEquals(
            DeferredGeofenceCallbackStoreResult.DUPLICATE,
            first.defer(deferred),
        )

        val recreated = DeferredGeofenceCallbackStore(backend)
        val found = assertIs<DeferredGeofenceCallbackReadResult.Found>(
            recreated.snapshot(),
        )
        assertEquals(listOf("event-1"), found.entries.map { it.toWire().eventId })
        assertEquals(listOf(123L), found.entries.map { it.deferredAtMillis })
        assertEquals(true, recreated.remove("event-1"))
        assertEquals(
            emptyList(),
            assertIs<DeferredGeofenceCallbackReadResult.Found>(
                recreated.snapshot(),
            ).entries,
        )
    }

    @Test
    fun `queue capacity rejects a new event without replacing older events`() {
        val backend = MemoryDeferredCallbackBackend()
        val store = DeferredGeofenceCallbackStore(
            backend = backend,
            maximumEntries = 1,
        )
        assertEquals(
            DeferredGeofenceCallbackStoreResult.STORED,
            store.defer(request(params(active("a"), eventId = "event-a"))),
        )

        assertEquals(
            DeferredGeofenceCallbackStoreResult.FULL,
            store.defer(request(params(active("b"), eventId = "event-b"))),
        )
        assertEquals(
            listOf("event-a"),
            assertIs<DeferredGeofenceCallbackReadResult.Found>(
                store.snapshot(),
            ).entries.map { it.toWire().eventId },
        )
    }

    @Test
    fun `acknowledging one routed group retains the rest of the original batch`() {
        val store = DeferredGeofenceCallbackStore(MemoryDeferredCallbackBackend())
        assertEquals(
            DeferredGeofenceCallbackStoreResult.STORED,
            store.defer(
                request(
                    params(
                        active("a"),
                        active("b"),
                        eventId = "event-1",
                        contexts = mapOf("a" to 1L, "b" to 2L),
                    )
                )
            ),
        )

        assertEquals(true, store.acknowledge("event-1", setOf("a")))
        val retained = assertIs<DeferredGeofenceCallbackReadResult.Found>(
            store.snapshot(),
        ).entries.single()
        assertEquals(setOf("a", "b"), retained.rootGeofenceIds())
        val retainedParams = retained.toWire()
        assertEquals(listOf("b"), retainedParams.geofences.map { it.id })
        assertEquals(mapOf("b" to 2L), retainedParams.callbackContextsByGeofenceId)
        assertEquals(true, store.acknowledge("event-1", setOf("b")))
        assertEquals(
            emptyList(),
            assertIs<DeferredGeofenceCallbackReadResult.Found>(
                store.snapshot(),
            ).entries,
        )
    }

    @Test
    fun `replay waits for synchronized freshness then binds current callback metadata`() {
        val deferred = params(
            active("office"),
            eventId = "event-1",
            contexts = mapOf("office" to 1L),
        )
        val current = configured("office", callbackHandle = 99L, callbackContext = 77L)
        val registration = registration(current, expirationDeadlineMillis = 456L)

        assertEquals(
            DeferredGeofenceCallbackReplayDecision.WaitForRefresh,
            decide(
                deferred,
                synchronizedIds = emptySet(),
                lookup = { registration },
                isCallbackFresh = { true },
            ),
        )
        assertEquals(
            DeferredGeofenceCallbackReplayDecision.WaitForRefresh,
            decide(
                deferred,
                synchronizedIds = setOf("office"),
                lookup = { registration },
                isCallbackFresh = { false },
            ),
        )

        val decision = assertIs<DeferredGeofenceCallbackReplayDecision.Deliver>(
            decide(
                deferred,
                synchronizedIds = setOf("office"),
                lookup = { registration },
                isCallbackFresh = { true },
            ),
        )
        val routed = decision.callbackGroups.single()
        assertEquals(99L, routed.callbackHandle)
        assertEquals("event-1", routed.eventId)
        assertEquals(mapOf("office" to 77L), routed.callbackContextsByGeofenceId)
        assertEquals(456L, routed.geofences.single().expirationDeadlineMillis)
        assertEquals(current.location.latitude, routed.geofences.single().location.latitude)
    }

    @Test
    fun `replay preserves a batch while current registrations share a callback`() {
        val deferred = params(
            active("a"),
            active("b"),
            eventId = "event-1",
        )
        val registrations = mapOf(
            "a" to registration(configured("a", 99L, 1L)),
            "b" to registration(configured("b", 99L, 2L)),
        )

        val decision = assertIs<DeferredGeofenceCallbackReplayDecision.Deliver>(
            decide(
                deferred,
                synchronizedIds = registrations.keys,
                lookup = registrations::get,
                isCallbackFresh = { true },
            ),
        )

        assertEquals(1, decision.callbackGroups.size)
        assertEquals(listOf("a", "b"), decision.callbackGroups.single().geofences.map { it.id })
        assertEquals("event-1", decision.callbackGroups.single().eventId)
    }

    @Test
    fun `replay splits only when current callback handles differ`() {
        val deferred = params(
            active("a"),
            active("b"),
            eventId = "event-1",
        )
        val registrations = mapOf(
            "a" to registration(configured("a", 99L, 1L)),
            "b" to registration(configured("b", 100L, 2L)),
        )

        val decision = assertIs<DeferredGeofenceCallbackReplayDecision.Deliver>(
            decide(
                deferred,
                synchronizedIds = registrations.keys,
                lookup = registrations::get,
                isCallbackFresh = { true },
            ),
        )

        assertEquals(listOf(listOf("a"), listOf("b")), decision.callbackGroups.map { group ->
            group.geofences.map { it.id }
        })
        assertEquals(listOf("event-1:99", "event-1:100"), decision.callbackGroups.map { it.eventId })
        assertEquals(listOf("event-1", "event-1"), decision.callbackGroups.map { it.traceId })
    }

    @Test
    fun `partially acknowledged batch keeps its derived delivery identity`() {
        val current = registration(configured("b", 100L, 2L))

        val decision = assertIs<DeferredGeofenceCallbackReplayDecision.Deliver>(
            decide(
                params(active("b"), eventId = "event-1"),
                rootGeofenceIds = setOf("a", "b"),
                synchronizedIds = setOf("b"),
                lookup = { current },
                isCallbackFresh = { true },
            ),
        )

        assertEquals("event-1:100", decision.callbackGroups.single().eventId)
        assertEquals("event-1", decision.callbackGroups.single().traceId)
    }

    @Test
    fun `missing registration waits until an authoritative synchronization`() {
        val deferred = params(active("removed"), eventId = "event-1")

        assertEquals(
            DeferredGeofenceCallbackReplayDecision.WaitForRefresh,
            decide(
                deferred,
                synchronizedIds = emptySet(),
                registrationStateAuthoritative = false,
                lookup = { null },
                isCallbackFresh = { true },
            ),
        )
        assertEquals(
            DeferredGeofenceCallbackReplayDecision.Discard,
            decide(
                deferred,
                synchronizedIds = emptySet(),
                registrationStateAuthoritative = true,
                lookup = { null },
                isCallbackFresh = { true },
            ),
        )
    }

    @Test
    fun `replay preserves a missing event timestamp`() {
        val current = configured("office", callbackHandle = 99L, callbackContext = null)
        val decision = assertIs<DeferredGeofenceCallbackReplayDecision.Deliver>(
            decide(
                params(
                    active("office"),
                    eventId = "event-1",
                    eventAtMillis = null,
                ),
                synchronizedIds = setOf("office"),
                lookup = { registration(current) },
                isCallbackFresh = { true },
            ),
        )

        assertEquals(null, decision.callbackGroups.single().eventAtMillis)
    }

    private fun decide(
        deferred: GeofenceCallbackParamsWire,
        rootGeofenceIds: Set<String> = deferred.geofences.map { it.id }.toSet(),
        synchronizedIds: Set<String>,
        registrationStateAuthoritative: Boolean = false,
        lookup: (String) -> GeofenceCallbackRegistration?,
        isCallbackFresh: (String) -> Boolean,
    ) = DeferredGeofenceCallbackReplayPlanner.decide(
        deferred = deferred,
        rootGeofenceIds = rootGeofenceIds,
        synchronizedIds = synchronizedIds,
        registrationStateAuthoritative = registrationStateAuthoritative,
        lookup = lookup,
        isCallbackFresh = isCallbackFresh,
    )

    private fun request(
        params: GeofenceCallbackParamsWire,
        route: String = DEFAULT_DEFERRED_CALLBACK_ROUTE,
        source: String? = null,
    ) = DeferredGeofenceCallbackRequest(
        params = params,
        deliveryRoute = route,
        deliverySource = source,
    )

    private fun registration(
        geofence: GeofenceWire,
        expirationDeadlineMillis: Long? = null,
    ) = GeofenceCallbackRegistration(
        configuredGeofence = geofence,
        expirationDeadlineMillis = expirationDeadlineMillis,
    )

    private fun params(
        vararg geofences: ActiveGeofenceWire,
        eventId: String,
        contexts: Map<String, Long>? = null,
        eventAtMillis: Long? = 100L,
    ) = GeofenceCallbackParamsWire(
        geofences = geofences.toList(),
        event = GeofenceEvent.ENTER,
        location = LocationWire(
            latitude = 11.2,
            longitude = 104.2,
            accuracyMeters = 4.0,
            isMock = false,
        ),
        eventAtMillis = eventAtMillis,
        callbackHandle = 7L,
        eventId = eventId,
        callbackContextsByGeofenceId = contexts,
    )

    private fun active(id: String) = ActiveGeofenceWire(
        id = id,
        location = LocationWire(
            latitude = 11.0,
            longitude = 104.0,
            accuracyMeters = null,
            isMock = false,
        ),
        radiusMeters = 100.0,
        triggers = listOf(GeofenceEvent.ENTER, GeofenceEvent.EXIT),
        androidSettings = null,
    )

    private fun configured(
        id: String,
        callbackHandle: Long,
        callbackContext: Long?,
    ) = GeofenceWire(
        id = id,
        location = LocationWire(
            latitude = 12.0,
            longitude = 105.0,
            accuracyMeters = null,
            isMock = false,
        ),
        radiusMeters = 125.0,
        triggers = listOf(GeofenceEvent.ENTER),
        iosSettings = IosGeofenceSettingsWire(initialTrigger = false),
        androidSettings = AndroidGeofenceSettingsWire(
            initialTriggers = emptyList(),
            expirationDurationMillis = null,
            loiteringDelayMillis = 0,
            notificationResponsivenessMillis = null,
        ),
        callbackHandle = callbackHandle,
        callbackContext = callbackContext,
    )
}

private class MemoryDeferredCallbackBackend : DeferredGeofenceCallbackBackend {
    private var encoded: String? = null

    override fun read(): String? = encoded

    override fun write(encoded: String): Boolean {
        this.encoded = encoded
        return true
    }
}
