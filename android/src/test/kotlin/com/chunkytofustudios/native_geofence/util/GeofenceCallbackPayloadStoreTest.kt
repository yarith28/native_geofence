package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.ActiveGeofenceWire
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.LocationWire
import com.chunkytofustudios.native_geofence.model.GeofenceCallbackParamsStorage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class GeofenceCallbackPayloadStoreTest {
    @Test
    fun `payload survives a new store instance and is not constrained by WorkManager data`() {
        val backend = MemoryCallbackPayloadBackend()
        val reference = "00000000-0000-0000-0000-000000000001"
        val params = params(
            geofenceId = "g".repeat(12_000),
            eventId = "delivery-1"
        )
        val firstProcess = GeofenceCallbackPayloadStore(
            backend = backend,
            nowMillis = { 123L },
            referenceGenerator = { reference }
        )

        assertEquals(reference, firstProcess.store(params, "package-v1"))
        assertTrue(requireNotNull(backend.values[reference]).length > 10_000)

        val afterProcessDeath = GeofenceCallbackPayloadStore(backend)
        val found = assertIs<CallbackPayloadReadResult.Found>(
            afterProcessDeath.read(reference)
        )
        assertEquals("delivery-1", found.envelope.toWire().eventId)
        assertEquals("package-v1", found.envelope.packageFingerprint)
        assertEquals(123L, found.envelope.enqueuedAtMillis)
    }

    @Test
    fun `ambiguous enqueue recovery metadata survives process death`() {
        val backend = MemoryCallbackPayloadBackend()
        val reference = "00000000-0000-0000-0000-000000000010"
        val firstProcess = GeofenceCallbackPayloadStore(
            backend = backend,
            nowMillis = { 123L },
            referenceGenerator = { reference },
        )

        assertEquals(
            reference,
            firstProcess.store(
                params = params(eventId = "delivery-recovery"),
                packageFingerprint = "package-v1",
                deliveryRoute = "final_dart_callback",
                deliverySource = "smart_geofence",
                recoverAmbiguousEnqueue = true,
            ),
        )

        val recovered = GeofenceCallbackPayloadStore(backend)
            .recoverablePayloads()
            .getOrThrow()
            .single()
        assertEquals(reference, recovered.reference)
        assertEquals(reference, recovered.envelope.workRequestId)
        assertEquals("final_dart_callback", recovered.envelope.deliveryRoute)
        assertEquals("smart_geofence", recovered.envelope.deliverySource)
        assertEquals("delivery-recovery", recovered.envelope.toWire().eventId)
    }

    @Test
    fun `legacy payload without stable work ownership is not blindly recovered`() {
        val backend = MemoryCallbackPayloadBackend()
        val reference = "00000000-0000-0000-0000-000000000011"
        val store = GeofenceCallbackPayloadStore(
            backend = backend,
            referenceGenerator = { reference },
        )
        assertEquals(
            reference,
            store.store(params(eventId = "legacy-current-envelope"), "package"),
        )

        assertTrue(store.recoverablePayloads().getOrThrow().isEmpty())
        assertIs<CallbackPayloadReadResult.Found>(store.read(reference))
    }

    @Test
    fun `success or terminal cleanup removes the durable payload`() {
        val backend = MemoryCallbackPayloadBackend()
        val reference = "00000000-0000-0000-0000-000000000002"
        val store = GeofenceCallbackPayloadStore(
            backend,
            referenceGenerator = { reference }
        )
        assertEquals(reference, store.store(params(eventId = "delivery-2"), "package"))

        assertTrue(store.delete(reference))
        assertIs<CallbackPayloadReadResult.Missing>(store.read(reference))
        assertNull(backend.values[reference])
    }

    @Test
    fun `missing event id and corrupt payload are terminally identifiable`() {
        val backend = MemoryCallbackPayloadBackend()
        val reference = "00000000-0000-0000-0000-000000000003"
        val store = GeofenceCallbackPayloadStore(
            backend,
            referenceGenerator = { reference }
        )

        assertNull(store.store(params(eventId = null), "package"))
        backend.values[reference] = "not-json"
        assertIs<CallbackPayloadReadResult.Corrupt>(store.read(reference))
    }

    @Test
    fun `migration input selection preserves authoritative format precedence`() {
        assertEquals(
            CallbackPayloadInput.CurrentReference("current"),
            CallbackPayloadMigration.selectInput("current", "inline", "legacy")
        )
        assertEquals(
            CallbackPayloadInput.LegacyInline("inline"),
            CallbackPayloadMigration.selectInput(null, "inline", "legacy")
        )
        assertEquals(
            CallbackPayloadInput.LegacyReference("legacy"),
            CallbackPayloadMigration.selectInput(null, null, "legacy")
        )
        assertIs<CallbackPayloadInput.Missing>(
            CallbackPayloadMigration.selectInput(null, null, null)
        )
    }

    @Test
    fun `improvement era raw file payload loads and receives a stable event id`() {
        val backend = MemoryCallbackPayloadBackend()
        val reference = "00000000-0000-0000-0000-0000000000AA"
        val workerId = "10000000-0000-0000-0000-000000000001"
        backend.values[reference.lowercase()] = Json.encodeToString(
            GeofenceCallbackParamsStorage.fromWire(params(eventId = null))
        )
        val store = LegacyGeofenceCallbackPayloadStore(backend)

        val found = assertIs<LegacyCallbackPayloadReadResult.Found>(
            store.read(reference)
        )
        val withEventId = CallbackPayloadMigration.withStableEventId(
            found.params,
            workerId
        )

        assertEquals(workerId, withEventId.eventId)
        assertEquals(listOf(reference.lowercase()), backend.readReferences)
        assertTrue(store.delete(reference))
        assertEquals(listOf(reference.lowercase()), backend.deleteReferences)
    }

    @Test
    fun `legacy payload keeps an existing event id and accepts future fields`() {
        val backend = MemoryCallbackPayloadBackend()
        val reference = "00000000-0000-0000-0000-000000000004"
        val raw = Json.encodeToString(
            GeofenceCallbackParamsStorage.fromWire(params(eventId = "existing"))
        )
        backend.values[reference] = raw.dropLast(1) +
            ",\"callbackContextsByGeofenceId\":{\"office\":9}}"

        val found = assertIs<LegacyCallbackPayloadReadResult.Found>(
            LegacyGeofenceCallbackPayloadStore(backend).read(reference)
        )

        assertEquals(
            "existing",
            CallbackPayloadMigration.withStableEventId(found.params, "worker").eventId
        )
        assertEquals(mapOf("office" to 9L), found.params.callbackContextsByGeofenceId)
    }

    @Test
    fun `legacy file rejects traversal and distinguishes missing from corrupt`() {
        val backend = MemoryCallbackPayloadBackend()
        val store = LegacyGeofenceCallbackPayloadStore(backend)
        val missing = "00000000-0000-0000-0000-000000000005"
        val corrupt = "00000000-0000-0000-0000-000000000006"
        backend.values[corrupt] = "not-json"

        assertIs<LegacyCallbackPayloadReadResult.Corrupt>(store.read("../../payload"))
        assertTrue(backend.readReferences.isEmpty())
        assertIs<LegacyCallbackPayloadReadResult.Missing>(store.read(missing))
        assertIs<LegacyCallbackPayloadReadResult.Corrupt>(store.read(corrupt))
    }

    @Test
    fun `payload lease retains retries and deletes exactly once at terminal completion`() {
        val backend = MemoryCallbackPayloadBackend()
        val reference = "00000000-0000-0000-0000-000000000007"
        backend.values[reference] = "payload"
        val lease = CallbackPayloadLease { backend.delete(reference) }
        val outcomes = mutableListOf<CallbackPayloadSettlement>()

        lease.settle(
            CallbackDeliveryPolicy.failure(
                CallbackDeliveryFailure.INFRASTRUCTURE,
                runAttemptCount = 0
            ),
            dispatch = { it() },
            completion = outcomes::add
        )
        assertEquals(listOf(CallbackPayloadSettlement.RETAINED), outcomes)
        assertEquals("payload", backend.values[reference])
        assertTrue(backend.deleteReferences.isEmpty())

        lease.settle(
            CallbackDeliveryPolicy.success(),
            dispatch = { it() },
            completion = outcomes::add
        )
        lease.settle(
            CallbackDeliveryPolicy.success(),
            dispatch = { it() },
            completion = outcomes::add
        )

        assertEquals(
            listOf(
                CallbackPayloadSettlement.RETAINED,
                CallbackPayloadSettlement.DELETED,
                CallbackPayloadSettlement.ALREADY_SETTLED
            ),
            outcomes
        )
        assertNull(backend.values[reference])
        assertEquals(listOf(reference), backend.deleteReferences)
    }

    @Test
    fun `payload lease reports cleanup failures once and still completes`() {
        var deletes = 0
        val outcomes = mutableListOf<CallbackPayloadSettlement>()
        val lease = CallbackPayloadLease {
            deletes += 1
            throw IllegalStateException("disk")
        }

        lease.settle(
            CallbackDeliveryPolicy.success(),
            dispatch = { cleanup ->
                cleanup()
                throw IllegalStateException("late dispatch failure")
            },
            completion = outcomes::add
        )

        assertEquals(1, deletes)
        assertEquals(listOf(CallbackPayloadSettlement.DELETE_FAILED), outcomes)
    }

    private fun params(
        geofenceId: String = "office",
        eventId: String?
    ) = GeofenceCallbackParamsWire(
        geofences = listOf(
            ActiveGeofenceWire(
                id = geofenceId,
                location = LocationWire(
                    latitude = 11.0,
                    longitude = 104.0,
                    accuracyMeters = null,
                    isMock = false
                ),
                radiusMeters = 100.0,
                triggers = listOf(GeofenceEvent.ENTER),
                androidSettings = null
            )
        ),
        event = GeofenceEvent.ENTER,
        location = null,
        eventAtMillis = 100L,
        callbackHandle = 7L,
        eventId = eventId
    )
}

private class MemoryCallbackPayloadBackend : CallbackPayloadBackend {
    val values = mutableMapOf<String, String>()
    val readReferences = mutableListOf<String>()
    val deleteReferences = mutableListOf<String>()

    override fun write(reference: String, value: String): Boolean {
        if (values.containsKey(reference)) return false
        values[reference] = value
        return true
    }

    override fun read(reference: String): Result<String?> {
        readReferences += reference
        return Result.success(values[reference])
    }

    override fun delete(reference: String): Boolean {
        deleteReferences += reference
        values.remove(reference)
        return true
    }

    override fun listReferences(): Result<List<String>> =
        Result.success(values.keys.toList())
}
