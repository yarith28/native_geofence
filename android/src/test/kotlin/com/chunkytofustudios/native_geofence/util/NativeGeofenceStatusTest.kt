package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.NativeGeofenceCallbackRefreshState
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceRegistrationHealth
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NativeGeofenceDiagnosticFactStoreTest {
    @Test
    fun `facts are bounded privacy-safe and survive a new provider instance`() {
        val backend = MemoryDiagnosticFactBackend()
        val recorder = NativeGeofenceDiagnosticFactStore(backend) { 123L }
        assertTrue(
            recorder.record(
                NativeGeofenceDiagnosticStage.WORKER,
                succeeded = false,
                outcome = "Callback failed: secret details and spaces",
                geofenceCount = -2
            )
        )

        val afterProcessDeath = NativeGeofenceDiagnosticFactStore(backend).read(
            NativeGeofenceDiagnosticStage.WORKER
        )
        assertEquals(123L, afterProcessDeath?.occurredAtMillis)
        assertFalse(requireNotNull(afterProcessDeath).succeeded)
        assertEquals("callback_failed__secret_details_and_spaces", afterProcessDeath.outcome)
        assertEquals(0, afterProcessDeath.geofenceCount)
        assertNull(backend.lastRawPayload?.takeIf { it.contains("callbackHandle") })
    }
}

class NativeGeofenceStatusHealthTest {
    @Test
    fun `health distinguishes empty unavailable degraded unknown and healthy`() {
        val healthy = evidence()
        assertEquals(
            NativeGeofenceRegistrationHealth.NO_REGISTRATIONS,
            NativeGeofenceStatusHealth.compute(healthy.copy(persistedRegistrationCount = 0))
        )
        assertEquals(
            NativeGeofenceRegistrationHealth.UNAVAILABLE,
            NativeGeofenceStatusHealth.compute(
                healthy.copy(locationServicesEnabled = false)
            )
        )
        assertEquals(
            NativeGeofenceRegistrationHealth.DEGRADED,
            NativeGeofenceStatusHealth.compute(
                healthy.copy(
                    callbackRefreshState =
                        NativeGeofenceCallbackRefreshState.REFRESH_REQUIRED
                )
            )
        )
        assertEquals(
            NativeGeofenceRegistrationHealth.DEGRADED,
            NativeGeofenceStatusHealth.compute(
                healthy.copy(pluginOwnedMonitoringCount = 0)
            )
        )
        assertEquals(
            NativeGeofenceRegistrationHealth.UNKNOWN,
            NativeGeofenceStatusHealth.compute(
                healthy.copy(callbackInfrastructureAvailable = null)
            )
        )
        assertEquals(
            NativeGeofenceRegistrationHealth.HEALTHY,
            NativeGeofenceStatusHealth.compute(healthy)
        )
    }

    @Test
    fun `android health requires every durable registration to be active`() {
        val healthy = evidence()

        assertEquals(
            NativeGeofenceRegistrationHealth.HEALTHY,
            NativeGeofenceStatusHealth.compute(
                healthy.copy(androidLifecycleEvidence = lifecycle(GeofenceStatusDisposition.ACTIVE))
            )
        )
        for (
            disposition in listOf(
                GeofenceStatusDisposition.RECOVERABLE,
                GeofenceStatusDisposition.PENDING_CLEANUP,
                GeofenceStatusDisposition.CORRUPT_OR_RAW_ONLY
            )
        ) {
            assertEquals(
                NativeGeofenceRegistrationHealth.DEGRADED,
                NativeGeofenceStatusHealth.compute(
                    healthy.copy(androidLifecycleEvidence = lifecycle(disposition))
                ),
                disposition.name
            )
        }
        assertEquals(
            NativeGeofenceRegistrationHealth.UNKNOWN,
            NativeGeofenceStatusHealth.compute(
                healthy.copy(
                    androidLifecycleEvidence = lifecycle(
                        GeofenceStatusDisposition.UNKNOWN_LIFECYCLE
                    )
                )
            )
        )
    }

    private fun evidence() = NativeGeofenceHealthEvidence(
        persistedRegistrationCount = 1,
        locationPermissionGranted = true,
        backgroundLocationPermissionGranted = true,
        locationServicesEnabled = true,
        platformMonitoringAvailable = true,
        callbackInfrastructureAvailable = true,
        callbackDispatcherRegistered = true,
        callbackRefreshState = NativeGeofenceCallbackRefreshState.CURRENT,
        pluginOwnedMonitoringCount = 1
    )

    private fun lifecycle(disposition: GeofenceStatusDisposition) =
        AndroidGeofenceLifecycleEvidence.from(
            listOf(
                GeofenceStatusInventoryEntry(
                    id = "opaque-id",
                    disposition = disposition,
                    callbackPackageFingerprint = "package-v1"
                )
            )
        )
}

class AndroidCallbackRefreshPolicyTest {
    @Test
    fun `provider policy applies registration marker and evidence precedence`() {
        assertEquals(
            NativeGeofenceCallbackRefreshState.NOT_APPLICABLE,
            AndroidCallbackRefreshPolicy.evaluate(
                "v2",
                null,
                emptyList(),
                callbackRefreshRequired = true
            )
        )
        assertEquals(
            NativeGeofenceCallbackRefreshState.REFRESH_REQUIRED,
            AndroidCallbackRefreshPolicy.evaluate(
                "v2",
                "v2",
                listOf("v2"),
                callbackRefreshRequired = true
            )
        )
        assertEquals(
            NativeGeofenceCallbackRefreshState.REFRESH_REQUIRED,
            AndroidCallbackRefreshPolicy.evaluate(
                "v2",
                null,
                listOf(null),
                callbackRefreshRequired = true
            )
        )
        assertEquals(
            NativeGeofenceCallbackRefreshState.CURRENT,
            AndroidCallbackRefreshPolicy.evaluate(
                "v2",
                "v2",
                listOf("v2", "v2"),
                callbackRefreshRequired = false
            )
        )
        assertEquals(
            NativeGeofenceCallbackRefreshState.REFRESH_REQUIRED,
            AndroidCallbackRefreshPolicy.evaluate(
                "v2",
                "v1",
                listOf("v2"),
                callbackRefreshRequired = false
            )
        )
        assertEquals(
            NativeGeofenceCallbackRefreshState.REFRESH_REQUIRED,
            AndroidCallbackRefreshPolicy.evaluate(
                "v2",
                "v2",
                listOf("v1"),
                callbackRefreshRequired = false
            )
        )
        assertEquals(
            NativeGeofenceCallbackRefreshState.REFRESH_REQUIRED,
            AndroidCallbackRefreshPolicy.evaluate(
                "v2",
                null,
                listOf("v1"),
                callbackRefreshRequired = false
            )
        )
        assertEquals(
            NativeGeofenceCallbackRefreshState.UNKNOWN,
            AndroidCallbackRefreshPolicy.evaluate(
                "v2",
                null,
                listOf("v2"),
                callbackRefreshRequired = false
            )
        )
        assertEquals(
            NativeGeofenceCallbackRefreshState.UNKNOWN,
            AndroidCallbackRefreshPolicy.evaluate(
                "v2",
                "v2",
                listOf(null),
                callbackRefreshRequired = false
            )
        )
    }
}

private class MemoryDiagnosticFactBackend : DiagnosticFactBackend {
    private val values = mutableMapOf<NativeGeofenceDiagnosticStage, String>()
    var lastRawPayload: String? = null

    override fun put(stage: NativeGeofenceDiagnosticStage, encoded: String): Boolean {
        lastRawPayload = encoded
        values[stage] = encoded
        return true
    }

    override fun get(stage: NativeGeofenceDiagnosticStage): String? = values[stage]
}
