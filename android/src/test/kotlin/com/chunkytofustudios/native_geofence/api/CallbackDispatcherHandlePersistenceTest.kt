package com.chunkytofustudios.native_geofence.api

import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode
import com.chunkytofustudios.native_geofence.receivers.InitializationRepairAdmissionGate
import com.chunkytofustudios.native_geofence.util.GeofenceStatusDisposition
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class CallbackDispatcherHandlePersistenceTest {
    @Test
    fun `passes the dispatcher handle to durable storage`() {
        var persistedHandle: Long? = null

        persistCallbackDispatcherHandle(42L) { handle ->
            persistedHandle = handle
            true
        }

        assertEquals(42L, persistedHandle)
    }

    @Test
    fun `reports a typed error when durable storage fails`() {
        val error = assertFailsWith<FlutterError> {
            persistCallbackDispatcherHandle(42L) { false }
        }

        assertEquals(
            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
            error.code
        )
        assertEquals(
            "Failed to durably persist the callback dispatcher handle.",
            error.message
        )
    }

    @Test
    fun `starts initialization recovery only after dispatcher persistence`() {
        val events = mutableListOf<String>()

        initializeCallbackDispatcher(
            callbackDispatcherHandle = 42L,
            persist = {
                events.add("persist")
                true
            },
            afterPersisted = { events.add("recover") },
        )

        assertEquals(listOf("persist", "recover"), events)
    }

    @Test
    fun `does not start initialization recovery when persistence fails`() {
        var recoveryStarted = false

        assertFailsWith<FlutterError> {
            initializeCallbackDispatcher(
                callbackDispatcherHandle = 42L,
                persist = { false },
                afterPersisted = { recoveryStarted = true },
            )
        }

        assertFalse(recoveryStarted)
    }

    @Test
    fun `recovery admission waits for evidence and admits one start`() {
        val admission = InitializationRepairAdmissionGate()

        assertFalse(admission.tryAcquire(hasRecoveryEvidence = false))
        assertTrue(admission.tryAcquire(hasRecoveryEvidence = true))
        assertFalse(admission.tryAcquire(hasRecoveryEvidence = true))
    }

    @Test
    fun `synchronous start failure reopens recovery admission`() {
        val admission = InitializationRepairAdmissionGate()

        assertTrue(admission.tryAcquire(hasRecoveryEvidence = true))
        admission.releaseAfterStartFailure()

        assertTrue(admission.tryAcquire(hasRecoveryEvidence = true))
    }

    @Test
    fun `healthy active inventory does not need initialization recovery`() {
        assertFalse(
            initializationRecoveryNeeded(
                recoveryRequired = false,
                recoveryScheduled = false,
                dispositions = listOf(GeofenceStatusDisposition.ACTIVE),
            )
        )
    }

    @Test
    fun `durable recovery requirement repairs even active inventory`() {
        assertTrue(
            initializationRecoveryNeeded(
                recoveryRequired = true,
                recoveryScheduled = false,
                dispositions = listOf(GeofenceStatusDisposition.ACTIVE),
            )
        )
    }

    @Test
    fun `non-active inventory needs initialization recovery`() {
        GeofenceStatusDisposition.entries
            .filter { it != GeofenceStatusDisposition.ACTIVE }
            .forEach { disposition ->
                assertTrue(
                    initializationRecoveryNeeded(
                        recoveryRequired = false,
                        recoveryScheduled = false,
                        dispositions = listOf(disposition),
                    ),
                    "Expected $disposition to require repair.",
                )
            }
    }

    @Test
    fun `unreadable inventory needs initialization recovery`() {
        assertTrue(
            initializationRecoveryNeeded(
                recoveryRequired = false,
                recoveryScheduled = false,
                inventoryInspectionFailed = true,
                dispositions = emptyList(),
            )
        )
    }

    @Test
    fun `scheduled recovery suppresses duplicate initialization recovery`() {
        assertFalse(
            initializationRecoveryNeeded(
                recoveryRequired = true,
                recoveryScheduled = true,
                dispositions = listOf(GeofenceStatusDisposition.RECOVERABLE),
            )
        )
    }
}
