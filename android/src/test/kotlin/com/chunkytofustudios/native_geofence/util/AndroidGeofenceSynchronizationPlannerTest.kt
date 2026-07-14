package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.AndroidGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.generated.IosGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.LocationWire
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AndroidGeofenceSynchronizationPlannerTest {
    @Test
    fun `authoritative decision preserves the native no-op path`() {
        val desired = listOf(geofence("office", handle = 1, context = 10))
        val fingerprint = AndroidGeofenceSynchronizationPlanner
            .desiredRegistrationFingerprint(desired)

        val decision = AndroidGeofenceSynchronizationPlanner.decide(
            current = listOf(stored(desired.single())),
            rawIds = listOf("office"),
            desired = desired,
            removeUnlisted = true,
            currentPackageFingerprint = "current",
            currentRegistrationFingerprint = fingerprint,
            callbackFingerprintCurrent = true,
            nowMillis = 1_000
        )

        assertFalse(decision.requiresSynchronization)
        assertTrue(decision.reasons.isEmpty())
        assertEquals(1, decision.desiredCount)
        assertEquals(1, decision.previousCount)
    }

    @Test
    fun `authoritative decision reports current state after another caller wins`() {
        val current = geofence("office", handle = 1, context = 10)
        val desired = listOf(current)
        val fingerprint = AndroidGeofenceSynchronizationPlanner
            .desiredRegistrationFingerprint(desired)

        // A Dart isolate may have inspected an empty snapshot, but the shared
        // native transaction sees the registration committed by an earlier
        // caller and therefore returns the authoritative no-op result.
        val decision = AndroidGeofenceSynchronizationPlanner.decide(
            current = listOf(stored(current)),
            rawIds = listOf("office"),
            desired = desired,
            removeUnlisted = true,
            currentPackageFingerprint = "current",
            currentRegistrationFingerprint = fingerprint,
            callbackFingerprintCurrent = true,
            nowMillis = 1_000
        )

        assertFalse(decision.requiresSynchronization)
        assertEquals(emptyList(), decision.reasons)
        assertTrue(decision.plan.removeIds.isEmpty())
        assertTrue(decision.plan.platformUpserts.isEmpty())
        assertTrue(decision.plan.metadataOnlyUpdates.isEmpty())
    }

    @Test
    fun `decision reasons are derived from the transaction snapshot`() {
        val current = geofence("office", handle = 1, context = 10)
        val desired = listOf(geofence("office", handle = 2, context = 20))
        val desiredFingerprint = AndroidGeofenceSynchronizationPlanner
            .desiredRegistrationFingerprint(desired)

        val callbackOnly = AndroidGeofenceSynchronizationPlanner.decide(
            current = listOf(stored(current)),
            rawIds = listOf("office", "office"),
            desired = desired,
            removeUnlisted = true,
            currentPackageFingerprint = "current",
            // Deliberately simulate a corrupted/stale durable fingerprint that
            // already equals the desired bytes: callback drift still remains.
            currentRegistrationFingerprint = desiredFingerprint,
            callbackFingerprintCurrent = true,
            nowMillis = 1_000
        )

        assertEquals(
            listOf(AndroidGeofenceSynchronizationReason.CALLBACK_FINGERPRINT_CHANGED),
            callbackOnly.reasons
        )
        assertEquals(1, callbackOnly.previousCount)

        val firstRun = AndroidGeofenceSynchronizationPlanner.decide(
            current = emptyList(),
            rawIds = emptyList(),
            desired = desired,
            removeUnlisted = true,
            currentPackageFingerprint = "current",
            currentRegistrationFingerprint = null,
            callbackFingerprintCurrent = true,
            nowMillis = 1_000
        )
        assertEquals(
            listOf(
                AndroidGeofenceSynchronizationReason.FIRST_RUN,
                AndroidGeofenceSynchronizationReason.REGISTRATION_DRIFT
            ),
            firstRun.reasons
        )
    }

    @Test
    fun `native fingerprint retains the original Android v1 canonical form`() {
        val fingerprint = AndroidGeofenceSynchronizationPlanner
            .desiredRegistrationFingerprint(
                listOf(geofence("office", handle = 1, context = 10))
            )

        assertEquals(
            "{\"version\":1,\"platform\":\"android\",\"registrations\":[" +
                "{\"id\":\"office\",\"latitude\":11.0,\"longitude\":104.0," +
                "\"radiusMeters\":100.0,\"triggers\":[\"enter\",\"exit\"]," +
                "\"android\":{\"expirationDurationMillis\":null," +
                "\"loiteringDelayMillis\":0," +
                "\"notificationResponsivenessMillis\":null}," +
                "\"callbackHandle\":1,\"callbackContext\":10}]}",
            fingerprint
        )
    }

    @Test
    fun `unchanged active registration is not rearmed`() {
        val current = stored(geofence("office", handle = 1, context = 10))

        val plan = AndroidGeofenceSynchronizationPlanner.plan(
            current = listOf(current),
            rawIds = listOf("office"),
            desired = listOf(geofence("office", handle = 1, context = 10)),
            removeUnlisted = true,
            currentPackageFingerprint = "current",
            nowMillis = 1_000
        )

        assertTrue(plan.platformUpserts.isEmpty())
        assertTrue(plan.metadataOnlyUpdates.isEmpty())
        assertTrue(plan.removeIds.isEmpty())
    }

    @Test
    fun `callback drift refreshes metadata without platform rearm`() {
        val current = stored(geofence("office", handle = 1, context = 10))

        val plan = AndroidGeofenceSynchronizationPlanner.plan(
            current = listOf(current),
            rawIds = listOf("office"),
            desired = listOf(geofence("office", handle = 2, context = 20)),
            removeUnlisted = true,
            currentPackageFingerprint = "current",
            nowMillis = 1_000
        )

        assertTrue(plan.platformUpserts.isEmpty())
        assertEquals(listOf("office"), plan.metadataOnlyUpdates.map { it.id })
    }

    @Test
    fun `inactive geometry drift and unlisted raw ids are deterministic`() {
        val current = stored(
            geofence("office", handle = 1, context = null, radius = 50.0),
            active = false
        )

        val plan = AndroidGeofenceSynchronizationPlanner.plan(
            current = listOf(current),
            rawIds = listOf("zombie", "office"),
            desired = listOf(geofence("office", handle = 1, context = null)),
            removeUnlisted = true,
            currentPackageFingerprint = "current",
            nowMillis = 1_000
        )

        assertEquals(listOf("office"), plan.platformUpserts.map { it.id })
        assertEquals(listOf("zombie"), plan.removeIds)
    }

    @Test
    fun `unknown and expired lifecycle evidence cannot take the no-op path`() {
        val desiredWire = geofence("office", handle = 1, context = null).let { wire ->
            wire.copy(
                androidSettings = wire.androidSettings.copy(
                    expirationDurationMillis = 500
                )
            )
        }
        val desired = listOf(desiredWire)
        val desiredFingerprint = AndroidGeofenceSynchronizationPlanner
            .desiredRegistrationFingerprint(desired)
        val expired = stored(
            desired.single(),
            expirationDeadlineMillis = 999
        )
        val unknown = stored(
            geofence("legacy", handle = 2, context = null),
            lifecycleMetadataDurable = false
        )

        val decision = AndroidGeofenceSynchronizationPlanner.decide(
            current = listOf(expired, unknown),
            rawIds = listOf("office", "legacy", "corrupt"),
            desired = desired,
            removeUnlisted = false,
            currentPackageFingerprint = "current",
            currentRegistrationFingerprint = desiredFingerprint,
            callbackFingerprintCurrent = true,
            nowMillis = 1_000
        )

        assertTrue(decision.requiresSynchronization)
        assertEquals(listOf("office"), decision.plan.platformUpserts.map { it.id })
        assertEquals(
            listOf(AndroidGeofenceSynchronizationReason.REGISTRATION_DRIFT),
            decision.reasons
        )
    }

    @Test
    fun `incomplete inspection state is repairable and deterministic`() {
        val legacy = stored(
            geofence("legacy", handle = 1, context = null),
            lifecycleMetadataDurable = false
        )

        assertEquals(
            listOf("corrupt", "legacy"),
            AndroidGeofenceSynchronizationPlanner.incompleteRegistrationIds(
                current = listOf(legacy),
                rawIds = listOf("legacy", "corrupt"),
                nowMillis = 1_000
            )
        )

        val plan = AndroidGeofenceSynchronizationPlanner.plan(
            current = listOf(legacy),
            rawIds = listOf("legacy", "corrupt"),
            desired = listOf(
                geofence("legacy", handle = 1, context = null),
                geofence("corrupt", handle = 2, context = null)
            ),
            removeUnlisted = true,
            currentPackageFingerprint = "current",
            nowMillis = 1_000
        )

        assertEquals(
            listOf("corrupt", "legacy"),
            plan.platformUpserts.map { it.id }
        )
    }

    @Test
    fun `rollback lifetime is derived from the original absolute deadline`() {
        val configured = geofence("office", handle = 1, context = null).copy(
            androidSettings = geofence(
                "office",
                handle = 1,
                context = null
            ).androidSettings.copy(expirationDurationMillis = 1_000)
        )

        val restored = AndroidGeofenceSynchronizationPlanner
            .platformRegistrationForRollback(
                configured,
                expirationDeadlineMillis = 1_500,
                nowMillis = 1_200
            )

        assertEquals(300L, restored?.androidSettings?.expirationDurationMillis)
        assertEquals(1_000L, configured.androidSettings.expirationDurationMillis)
        assertEquals(
            null,
            AndroidGeofenceSynchronizationPlanner.platformRegistrationForRollback(
                configured,
                expirationDeadlineMillis = 1_500,
                nowMillis = 1_500
            )
        )
        assertEquals(
            null,
            AndroidGeofenceSynchronizationPlanner.platformRegistrationForRollback(
                configured,
                expirationDeadlineMillis = 1_500,
                nowMillis = 1_700
            ),
            "rollback must not restart an expired registration's configured duration"
        )
    }

    @Test
    fun `rollback touches only registrations owned by the failed transaction`() {
        val office = stored(
            geofence("office", handle = 1, context = null),
            expirationDeadlineMillis = 1_500
        )
        val unrelated = stored(
            geofence("unrelated", handle = 2, context = null),
            expirationDeadlineMillis = null
        )

        val rollback = AndroidGeofenceSynchronizationPlanner.rollbackPlan(
            platformTouchedIds = setOf("new", "office"),
            previouslyActive = listOf(unrelated, office)
        )

        assertEquals(listOf("new", "office"), rollback.cleanupIds)
        assertEquals(
            listOf("office"),
            rollback.platformRegistrationsToRestore.map { it.configuredGeofence.id }
        )
    }

    @Test
    fun `failed rollback cleanup retains newly touched ownership evidence`() {
        val evidence = AndroidGeofenceSynchronizationPlanner.rollbackEvidencePlan(
            cleanupFailed = true,
            cleanupIds = listOf("new"),
            previouslyActive = emptyList(),
            restorationOutcomes = emptyMap()
        )

        assertEquals(listOf("new"), evidence.cleanupMarkerIds)
        assertTrue(evidence.inactiveRecoveryIds.isEmpty())
        assertTrue(evidence.requiresRecovery)
    }

    @Test
    fun `successful previous rearm remains active after ambiguous cleanup`() {
        val office = stored(geofence("office", handle = 1, context = null))
        val unrelated = stored(geofence("unrelated", handle = 2, context = null))

        val evidence = AndroidGeofenceSynchronizationPlanner.rollbackEvidencePlan(
            cleanupFailed = true,
            cleanupIds = listOf("new", "office"),
            previouslyActive = listOf(unrelated, office),
            restorationOutcomes = mapOf(
                "office" to AndroidGeofenceRollbackRestorationOutcome.RESTORED
            )
        )

        assertEquals(listOf("new"), evidence.cleanupMarkerIds)
        assertTrue(evidence.inactiveRecoveryIds.isEmpty())
    }

    @Test
    fun `failed previous rearm is retained as inactive recovery evidence`() {
        val office = stored(geofence("office", handle = 1, context = null))

        val evidence = AndroidGeofenceSynchronizationPlanner.rollbackEvidencePlan(
            cleanupFailed = false,
            cleanupIds = listOf("office"),
            previouslyActive = listOf(office),
            restorationOutcomes = mapOf(
                "office" to AndroidGeofenceRollbackRestorationOutcome.FAILED
            )
        )

        assertTrue(evidence.cleanupMarkerIds.isEmpty())
        assertEquals(listOf("office"), evidence.inactiveRecoveryIds)
    }

    @Test
    fun `expired nonrecoverable and unknown rearms require cleanup evidence`() {
        val expired = stored(geofence("expired", handle = 1, context = null))
        val nonrecoverable = stored(
            geofence("nonrecoverable", handle = 2, context = null),
            recoveryEligible = false
        )
        val unknown = stored(geofence("unknown", handle = 3, context = null))

        val evidence = AndroidGeofenceSynchronizationPlanner.rollbackEvidencePlan(
            cleanupFailed = false,
            cleanupIds = listOf("unknown", "nonrecoverable", "expired"),
            previouslyActive = listOf(expired, nonrecoverable, unknown),
            restorationOutcomes = mapOf(
                "expired" to AndroidGeofenceRollbackRestorationOutcome.EXPIRED,
                "nonrecoverable" to AndroidGeofenceRollbackRestorationOutcome.FAILED
            )
        )

        assertEquals(
            listOf("expired", "nonrecoverable", "unknown"),
            evidence.cleanupMarkerIds
        )
        assertTrue(evidence.inactiveRecoveryIds.isEmpty())
    }

    private fun stored(
        geofence: GeofenceWire,
        active: Boolean = true,
        expirationDeadlineMillis: Long? = null,
        recoveryEligible: Boolean = true,
        lifecycleMetadataDurable: Boolean = true
    ) = StoredGeofenceRegistration(
        configuredGeofence = geofence,
        expirationDeadlineMillis = expirationDeadlineMillis,
        recoveryEligible = recoveryEligible,
        active = active,
        callbackPackageFingerprint = "current",
        lifecycleMetadataDurable = lifecycleMetadataDurable
    )

    private fun geofence(
        id: String,
        handle: Long,
        context: Long?,
        radius: Double = 100.0
    ) = GeofenceWire(
        id = id,
        location = LocationWire(11.0, 104.0, null, false),
        radiusMeters = radius,
        triggers = listOf(GeofenceEvent.ENTER, GeofenceEvent.EXIT),
        iosSettings = IosGeofenceSettingsWire(initialTrigger = false),
        androidSettings = AndroidGeofenceSettingsWire(
            initialTriggers = emptyList(),
            expirationDurationMillis = null,
            loiteringDelayMillis = 0,
            notificationResponsivenessMillis = null
        ),
        callbackHandle = handle,
        callbackContext = context
    )
}
