package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.AndroidGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.generated.IosGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.LocationWire
import com.chunkytofustudios.native_geofence.model.GeofenceStorage
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GeofenceRegistrationStoreTest {
    @Test
    fun `replacement snapshot restores exact record and deadline`() {
        var now = 1_000L
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { now }

        assertTrue(
            store.saveConfiguredGeofence(
                geofence(callbackHandle = 11, callbackContext = 111, duration = 500),
                callbackPackageFingerprint = "package-v1"
            )
        )
        val snapshot = store.snapshot("office")
        val originalJson = backend.values[recordKey("office")]
        val originalDeadline = backend.values[expirationKey("office")]

        now = 1_200L
        assertTrue(
            store.saveConfiguredGeofence(
                geofence(callbackHandle = 22, callbackContext = 222, duration = 900),
                callbackPackageFingerprint = "package-v2"
            )
        )
        assertEquals(22L, store.getConfiguredGeofence("office")?.configuredGeofence?.callbackHandle)

        assertTrue(store.restore(snapshot))
        assertEquals(originalJson, backend.values[recordKey("office")])
        assertEquals(originalDeadline, backend.values[expirationKey("office")])
        assertEquals(11L, store.getConfiguredGeofence("office")?.configuredGeofence?.callbackHandle)
        assertEquals(111L, store.getConfiguredGeofence("office")?.configuredGeofence?.callbackContext)
        assertEquals("package-v1", store.callbackPackageFingerprint("office"))
        assertEquals(1_500L, backend.values[expirationKey("office")])
    }

    @Test
    fun `delayed replacement commit preserves its prepared absolute deadline`() {
        var now = 1_000L
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { now }
        assertTrue(store.saveConfiguredGeofence(geofence(callbackHandle = 1, duration = 500)))
        val preparedDeadline = GeofenceRegistrationStore.safeDeadline(now, 900)

        now = 1_300L
        assertTrue(
            store.saveConfiguredGeofence(
                geofence(callbackHandle = 2, duration = 900),
                expirationDeadlineMillis = preparedDeadline,
            )
        )

        assertEquals(1_900L, backend.values[expirationKey("office")])
        assertEquals(
            600L,
            store.getRecoverableGeofence("office")
                ?.androidSettings
                ?.expirationDurationMillis,
        )
    }

    @Test
    fun `new insertion rollback removes every newly persisted field`() {
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { 1_000L }
        val emptySnapshot = store.snapshot("office")

        assertTrue(
            store.saveConfiguredGeofence(
                geofence(duration = 500),
                recoveryEligible = true,
                active = false
            )
        )
        assertTrue(store.restore(emptySnapshot))

        assertFalse(backend.values.containsKey(recordKey("office")))
        assertFalse(backend.values.containsKey(expirationKey("office")))
        assertTrue(store.rawIds().isEmpty())
        assertTrue(store.configuredIds().isEmpty())
    }

    @Test
    fun `expired registration stays canonical and raw but is not recoverable`() {
        var now = 5_000L
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { now }

        assertTrue(store.saveConfiguredGeofence(geofence(duration = 100)))
        now = 5_101L

        assertNull(store.getRecoverableGeofence("office"))
        val configured = assertNotNull(store.getConfiguredGeofence("office"))
        assertFalse(configured.recoveryEligible)
        assertFalse(configured.active)
        assertEquals(100L, configured.configuredGeofence.androidSettings.expirationDurationMillis)
        assertEquals(listOf("office"), store.rawIds())
    }

    @Test
    fun `registered getters share the active canonical registration set`() {
        var now = 1_000L
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { now }
        val alpha = geofence(id = "alpha")
        val office = geofence(id = "office", duration = 500)

        assertTrue(store.saveConfiguredGeofence(office))
        assertTrue(store.saveConfiguredGeofence(alpha))
        assertTrue(
            store.saveConfiguredGeofence(
                geofence(id = "inactive"),
                recoveryEligible = true,
                active = false,
            )
        )
        assertTrue(store.saveConfiguredGeofence(geofence(id = "expired", duration = 50)))
        assertTrue(store.saveConfiguredGeofence(geofence(id = "corrupt")))
        backend.values[recordKey("corrupt")] = "not-json"
        now = 1_100L

        val registered = store.getRegisteredGeofences()
        val snapshots = store.getRegisteredGeofenceSnapshots()

        assertEquals(listOf(alpha, office), registered)
        assertEquals(500L, registered.last().androidSettings.expirationDurationMillis)
        assertEquals(registered, snapshots.map { it.configuredGeofence })
        assertEquals(null, snapshots.first().expirationDeadlineMillis)
        assertEquals(1_500L, snapshots.last().expirationDeadlineMillis)
        assertEquals(registered.map(GeofenceWire::id), store.getRegisteredGeofenceIds())
        assertFalse(assertNotNull(store.getConfiguredGeofence("expired")).active)
    }

    @Test
    fun `legacy finite registration receives one absolute deadline`() {
        var now = 2_000L
        val backend = FakeGeofencePersistenceBackend()
        val legacy = geofence(duration = 500)
        backend.values[Constants.PERSISTENT_GEOFENCES_IDS_KEY] = setOf("office")
        backend.values[recordKey("office")] =
            Json.encodeToString(GeofenceStorage.fromWire(legacy))
        val store = GeofenceRegistrationStore(backend) { now }

        assertEquals(
            500L,
            store.getRecoverableGeofence("office")
                ?.androidSettings
                ?.expirationDurationMillis
        )
        assertEquals(2_500L, backend.values[expirationKey("office")])

        now = 2_100L
        assertEquals(
            400L,
            store.getRecoverableGeofence("office")
                ?.androidSettings
                ?.expirationDurationMillis
        )
        assertEquals(setOf("office"), backend.values[configuredIdsKey])
    }

    @Test
    fun `status inspection leaves legacy and expired lifecycle bytes unchanged`() {
        var now = 2_000L
        val legacyBackend = FakeGeofencePersistenceBackend()
        val legacy = geofence(duration = 500)
        legacyBackend.values[Constants.PERSISTENT_GEOFENCES_IDS_KEY] = setOf("office")
        legacyBackend.values[recordKey("office")] =
            Json.encodeToString(GeofenceStorage.fromWire(legacy))
        legacyBackend.values[callbackPackageFingerprintKey("office")] = "package-v1"
        val legacyStore = GeofenceRegistrationStore(legacyBackend) { now }
        val legacyBefore = legacyBackend.values.toMap()

        val unknown = legacyStore.statusInventory().single()

        assertEquals(GeofenceStatusDisposition.UNKNOWN_LIFECYCLE, unknown.disposition)
        assertEquals("package-v1", unknown.callbackPackageFingerprint)
        assertEquals(legacyBefore, legacyBackend.values)
        assertEquals(0, legacyBackend.editCalls)

        val activeBackend = FakeGeofencePersistenceBackend()
        val activeStore = GeofenceRegistrationStore(activeBackend) { now }
        assertTrue(activeStore.saveConfiguredGeofence(geofence(duration = 100)))
        activeBackend.editCalls = 0
        val activeBefore = activeBackend.values.toMap()
        now += 101

        val expired = activeStore.statusInventory().single()

        assertEquals(GeofenceStatusDisposition.PENDING_CLEANUP, expired.disposition)
        assertEquals(activeBefore, activeBackend.values)
        assertEquals(0, activeBackend.editCalls)
        assertEquals(true, activeBackend.values[recoveryEligibleKey("office")])
        assertEquals(true, activeBackend.values[activeKey("office")])
    }

    @Test
    fun `status inventory distinguishes every lifecycle disposition`() {
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { 1_000L }
        assertTrue(store.saveConfiguredGeofence(geofence()))
        assertEquals(
            GeofenceStatusDisposition.ACTIVE,
            store.statusInventory().single().disposition
        )

        assertTrue(store.setLifecycleState("office", recoveryEligible = true, active = false))
        assertEquals(
            GeofenceStatusDisposition.RECOVERABLE,
            store.statusInventory().single().disposition
        )

        assertTrue(store.setLifecycleState("office", recoveryEligible = false, active = false))
        assertEquals(
            GeofenceStatusDisposition.PENDING_CLEANUP,
            store.statusInventory().single().disposition
        )

        val corruptBackend = FakeGeofencePersistenceBackend()
        corruptBackend.values[Constants.PERSISTENT_GEOFENCES_IDS_KEY] = setOf("office")
        assertEquals(
            GeofenceStatusDisposition.CORRUPT_OR_RAW_ONLY,
            GeofenceRegistrationStore(corruptBackend).statusInventory().single().disposition
        )
    }

    @Test
    fun `failed finite lifecycle migration stays unknown and reuses derived deadline`() {
        var now = 2_000L
        val backend = FakeGeofencePersistenceBackend()
        val legacy = geofence(duration = 500)
        backend.values[Constants.PERSISTENT_GEOFENCES_IDS_KEY] = setOf("office")
        backend.values[recordKey("office")] =
            Json.encodeToString(GeofenceStorage.fromWire(legacy))
        backend.failNextCommit = true
        val store = GeofenceRegistrationStore(backend) { now }

        val unknown = store.recoveryInventory().single()
        assertEquals(GeofenceRecoveryDisposition.UNKNOWN_LIFECYCLE, unknown.disposition)
        assertEquals(legacy, unknown.storedRegistration?.configuredGeofence)
        assertNull(unknown.geofenceToRecover)
        assertEquals(listOf("office"), store.rawIds())
        assertEquals(2_500L, backend.values[expirationKey("office")])

        now = 2_100L
        val repaired = store.recoveryInventory().single()
        assertEquals(GeofenceRecoveryDisposition.RECOVERABLE, repaired.disposition)
        assertEquals(
            400L,
            repaired.geofenceToRecover?.androidSettings?.expirationDurationMillis,
        )
        assertEquals(2_500L, backend.values[expirationKey("office")])
    }

    @Test
    fun `failed infinite lifecycle migration retains canonical and raw evidence`() {
        val backend = FakeGeofencePersistenceBackend()
        val legacy = geofence(duration = null)
        val recordJson = Json.encodeToString(GeofenceStorage.fromWire(legacy))
        backend.values[Constants.PERSISTENT_GEOFENCES_IDS_KEY] = setOf("office")
        backend.values[recordKey("office")] = recordJson
        backend.failNextCommit = true
        val store = GeofenceRegistrationStore(backend) { 2_000L }

        val unknown = store.recoveryInventory().single()
        assertEquals(GeofenceRecoveryDisposition.UNKNOWN_LIFECYCLE, unknown.disposition)
        assertEquals(legacy, unknown.storedRegistration?.configuredGeofence)
        assertNull(unknown.geofenceToRecover)
        assertEquals(listOf("office"), store.rawIds())
        assertEquals(recordJson, backend.values[recordKey("office")])
        assertFalse(backend.values.containsKey(expirationKey("office")))
    }

    @Test
    fun `configured inspection reports legacy metadata without migrating persistence`() {
        val backend = FakeGeofencePersistenceBackend()
        val legacy = geofence(duration = 500)
        backend.values[Constants.PERSISTENT_GEOFENCES_IDS_KEY] = setOf("office")
        backend.values[recordKey("office")] =
            Json.encodeToString(GeofenceStorage.fromWire(legacy))
        backend.values[callbackPackageFingerprintKey("office")] = "package-v1"
        val store = GeofenceRegistrationStore(backend) { 2_000L }
        val before = backend.values.toMap()

        val inspected = assertNotNull(store.inspectConfiguredGeofences().singleOrNull())

        assertFalse(inspected.lifecycleMetadataDurable)
        assertEquals(2_500L, inspected.expirationDeadlineMillis)
        assertEquals("package-v1", store.callbackPackageFingerprint("office"))
        assertEquals(before, backend.values)
        assertEquals(0, backend.editCalls)
    }

    @Test
    fun `corrupt and missing records retain raw cleanup ids`() {
        val backend = FakeGeofencePersistenceBackend()
        backend.values[Constants.PERSISTENT_GEOFENCES_IDS_KEY] = setOf("corrupt", "missing")
        backend.values[recordKey("corrupt")] = "not-json"
        val store = GeofenceRegistrationStore(backend) { 1_000L }

        assertNull(store.getConfiguredGeofence("corrupt"))
        assertNull(store.getConfiguredGeofence("missing"))
        assertEquals(listOf("corrupt", "missing"), store.rawIds())
        assertEquals("not-json", backend.values[recordKey("corrupt")])
    }

    @Test
    fun `wrong typed finite deadline stays unknown and never receives a fresh lifetime`() {
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { 2_000L }
        assertTrue(store.saveConfiguredGeofence(geofence(duration = 500)))
        backend.values[expirationKey("office")] = "not-a-long"
        backend.editCalls = 0

        val entry = store.recoveryInventory().single()

        assertEquals(GeofenceRecoveryDisposition.UNKNOWN_LIFECYCLE, entry.disposition)
        assertNull(entry.geofenceToRecover)
        assertFalse(assertNotNull(entry.storedRegistration).recoveryEligible)
        assertFalse(assertNotNull(entry.storedRegistration).active)
        assertEquals("not-a-long", backend.values[expirationKey("office")])
        assertEquals(0, backend.editCalls)
        assertEquals(
            GeofenceStatusDisposition.UNKNOWN_LIFECYCLE,
            store.statusInventory().single().disposition,
        )
    }

    @Test
    fun `wrong typed lifecycle flags stay unknown and inactive`() {
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { 1_000L }
        assertTrue(store.saveConfiguredGeofence(geofence()))
        backend.values[recoveryEligibleKey("office")] = "not-a-boolean"
        backend.values[activeKey("office")] = 1L
        backend.editCalls = 0

        val entry = store.recoveryInventory().single()

        assertEquals(GeofenceRecoveryDisposition.UNKNOWN_LIFECYCLE, entry.disposition)
        assertNull(entry.geofenceToRecover)
        assertFalse(assertNotNull(entry.storedRegistration).recoveryEligible)
        assertFalse(assertNotNull(entry.storedRegistration).active)
        assertEquals("not-a-boolean", backend.values[recoveryEligibleKey("office")])
        assertEquals(1L, backend.values[activeKey("office")])
        assertEquals(0, backend.editCalls)
    }

    @Test
    fun `corrupt snapshot restoration fails without editing or throwing`() {
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { 1_000L }
        assertTrue(store.saveConfiguredGeofence(geofence(duration = 500)))
        backend.values[expirationKey("office")] = "not-a-long"
        val snapshot = store.snapshot("office")
        backend.values[activeKey("office")] = false
        backend.editCalls = 0
        val beforeRestore = backend.values.toMap()

        assertFalse(store.restore(snapshot))

        assertEquals(beforeRestore, backend.values)
        assertEquals(0, backend.editCalls)
    }

    @Test
    fun `snapshot restoration reports an editor exception without throwing`() {
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { 1_000L }
        assertTrue(store.saveConfiguredGeofence(geofence(duration = 500)))
        val snapshot = store.snapshot("office")
        backend.throwOnNextEdit = true

        assertFalse(store.restore(snapshot))
    }

    @Test
    fun `cleanup marker retains corrupt bytes and adds missing raw ids`() {
        val backend = FakeGeofencePersistenceBackend()
        backend.values[recordKey("corrupt")] = "not-json"
        val store = GeofenceRegistrationStore(backend) { 1_000L }

        assertTrue(store.markForPlatformCleanup("corrupt"))
        assertTrue(store.markForPlatformCleanup("missing"))

        assertEquals(listOf("corrupt", "missing"), store.rawIds())
        assertEquals("not-json", backend.values[recordKey("corrupt")])
        for (id in listOf("corrupt", "missing")) {
            assertEquals(false, backend.values[recoveryEligibleKey(id)])
            assertEquals(false, backend.values[activeKey(id)])
        }
    }

    @Test
    fun `bulk cleanup marker atomically makes every registration ineligible`() {
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { 1_000L }
        assertTrue(store.saveConfiguredGeofence(geofence(id = "office")))
        assertTrue(store.saveConfiguredGeofence(geofence(id = "home")))

        assertTrue(store.markAllForPlatformCleanup(listOf("office", "home")))

        assertEquals(
            listOf(
                GeofenceRecoveryDisposition.PENDING_CLEANUP,
                GeofenceRecoveryDisposition.PENDING_CLEANUP,
            ),
            store.recoveryInventory().map { it.disposition },
        )
    }

    @Test
    fun `recovery marker retains canonical bytes and adds missing raw id`() {
        val backend = FakeGeofencePersistenceBackend()
        val canonical = Json.encodeToString(GeofenceStorage.fromWire(geofence()))
        backend.values[recordKey("office")] = canonical
        val store = GeofenceRegistrationStore(backend) { 1_000L }

        assertTrue(store.markForRecovery("office"))

        assertEquals(listOf("office"), store.rawIds())
        assertEquals(canonical, backend.values[recordKey("office")])
        assertEquals(true, backend.values[recoveryEligibleKey("office")])
        assertEquals(false, backend.values[activeKey("office")])
    }

    @Test
    fun `failed lifecycle write is reported and not treated as saved`() {
        val backend = FakeGeofencePersistenceBackend().apply { failNextCommit = true }
        val store = GeofenceRegistrationStore(backend) { 1_000L }

        assertFalse(store.saveConfiguredGeofence(geofence(duration = 100)))
        assertFalse(backend.values.containsKey(recordKey("office")))
        assertTrue(store.rawIds().isEmpty())
    }

    @Test
    fun `callback refresh marker is checked and failed writes are not reported as durable`() {
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { 1_000L }

        assertFalse(store.isCallbackRefreshRequired())
        backend.failNextCommit = true
        assertFalse(store.markCallbackRefreshRequired())
        assertFalse(store.isCallbackRefreshRequired())

        assertTrue(store.markCallbackRefreshRequired())
        assertTrue(store.isCallbackRefreshRequired())
        assertEquals(true, backend.values[Constants.CALLBACK_REFRESH_REQUIRED_KEY])
    }

    @Test
    fun `callback refresh evidence is scoped to affected registration ids`() {
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { 1_000L }

        assertTrue(store.markCallbackRefreshRequired(setOf("office", "warehouse")))

        assertTrue(store.isCallbackRefreshRequired())
        assertTrue(store.isCallbackRefreshRequiredFor(setOf("office")))
        assertFalse(store.isCallbackRefreshRequiredFor(setOf("home")))
        assertFalse(store.isCallbackRefreshRequiredFor(emptySet()))
    }

    @Test
    fun `partial synchronization preserves authoritative and outside scope evidence`() {
        val backend = FakeGeofencePersistenceBackend().apply {
            values[Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY] = "authoritative"
        }
        val store = GeofenceRegistrationStore(backend) { 1_000L }
        assertTrue(store.markCallbackRefreshRequired(setOf("office", "warehouse")))

        assertTrue(store.commitPartialSynchronization(setOf("office")))

        assertEquals("authoritative", store.synchronizationFingerprint())
        assertFalse(store.isCallbackRefreshRequiredFor(setOf("office")))
        assertTrue(store.isCallbackRefreshRequiredFor(setOf("warehouse")))
        assertEquals(
            setOf("warehouse"),
            backend.values[Constants.CALLBACK_REFRESH_REQUIRED_IDS_KEY]
        )
    }

    @Test
    fun `partial synchronization cannot consume unattributed legacy refresh evidence`() {
        val backend = FakeGeofencePersistenceBackend().apply {
            values[Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY] = "authoritative"
            values[Constants.CALLBACK_REFRESH_REQUIRED_KEY] = true
        }
        val store = GeofenceRegistrationStore(backend) { 1_000L }

        assertTrue(store.commitPartialSynchronization(setOf("office")))

        assertEquals("authoritative", store.synchronizationFingerprint())
        assertTrue(store.isCallbackRefreshRequiredFor(setOf("office")))
        assertEquals(true, backend.values[Constants.CALLBACK_REFRESH_REQUIRED_KEY])
    }

    @Test
    fun `snapshot restores scoped callback refresh evidence`() {
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { 1_000L }
        assertTrue(store.markCallbackRefreshRequired(setOf("office")))
        val snapshot = store.callbackRefreshScopeSnapshot()
        assertTrue(store.commitPartialSynchronization(setOf("office")))
        assertFalse(store.isCallbackRefreshRequiredFor(setOf("office")))
        assertTrue(store.markCallbackRefreshRequired(setOf("warehouse")))

        assertTrue(store.restoreCallbackRefreshScope(snapshot))

        assertTrue(store.isCallbackRefreshRequiredFor(setOf("office")))
        assertTrue(store.isCallbackRefreshRequiredFor(setOf("warehouse")))
    }

    @Test
    fun `successful synchronization atomically publishes fingerprint and clears refresh marker`() {
        val backend = FakeGeofencePersistenceBackend().apply {
            values[Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY] = "old"
            values[Constants.CALLBACK_REFRESH_REQUIRED_KEY] = true
            values[Constants.CALLBACK_REFRESH_REQUIRED_IDS_KEY] = setOf("office")
        }
        val store = GeofenceRegistrationStore(backend) { 1_000L }

        assertTrue(store.commitSynchronization("new"))

        assertEquals("new", store.synchronizationFingerprint())
        assertFalse(store.isCallbackRefreshRequired())
        assertFalse(backend.values.containsKey(Constants.CALLBACK_REFRESH_REQUIRED_KEY))
        assertFalse(backend.values.containsKey(Constants.CALLBACK_REFRESH_REQUIRED_IDS_KEY))
    }

    @Test
    fun `failed synchronization commit preserves fingerprint and refresh marker`() {
        val backend = FakeGeofencePersistenceBackend().apply {
            values[Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY] = "old"
            values[Constants.CALLBACK_REFRESH_REQUIRED_KEY] = true
            failNextCommit = true
        }
        val store = GeofenceRegistrationStore(backend) { 1_000L }

        assertFalse(store.commitSynchronization("new"))

        assertEquals("old", store.synchronizationFingerprint())
        assertTrue(store.isCallbackRefreshRequired())
    }

    @Test
    fun `fingerprint rollback leaves refresh marker untouched`() {
        val backend = FakeGeofencePersistenceBackend().apply {
            values[Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY] = "changed"
            values[Constants.CALLBACK_REFRESH_REQUIRED_KEY] = true
        }
        val store = GeofenceRegistrationStore(backend) { 1_000L }

        assertTrue(store.restoreSynchronizationFingerprint("old"))

        assertEquals("old", store.synchronizationFingerprint())
        assertTrue(store.isCallbackRefreshRequired())
    }

    @Test
    fun `finite to infinite replacement removes the deadline`() {
        var now = 1_000L
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { now }

        assertTrue(store.saveConfiguredGeofence(geofence(duration = 500)))
        assertTrue(backend.values.containsKey(expirationKey("office")))

        now = 1_100L
        assertTrue(store.saveConfiguredGeofence(geofence(duration = null)))
        assertFalse(backend.values.containsKey(expirationKey("office")))
        assertNull(
            store.getConfiguredGeofence("office")
                ?.configuredGeofence
                ?.androidSettings
                ?.expirationDurationMillis
        )
    }

    @Test
    fun `deadline addition saturates instead of overflowing`() {
        assertEquals(
            Long.MAX_VALUE,
            GeofenceRegistrationStore.safeDeadline(Long.MAX_VALUE - 5, 10)
        )
    }

    @Test
    fun `synchronization metadata refresh preserves canonical finite deadline`() {
        var now = 1_000L
        val backend = FakeGeofencePersistenceBackend()
        val store = GeofenceRegistrationStore(backend) { now }
        assertTrue(
            store.saveConfiguredGeofence(
                geofence(callbackHandle = 1, callbackContext = 10, duration = 500),
                callbackPackageFingerprint = "old"
            )
        )
        now = 1_200L

        val prepared = store.prepareSynchronizedGeofence(
            geofence(callbackHandle = 2, callbackContext = 20, duration = 500)
        )
        assertEquals(1, store.getConfiguredGeofence("office")?.configuredGeofence?.callbackHandle)
        assertEquals(10, store.getConfiguredGeofence("office")?.configuredGeofence?.callbackContext)
        assertEquals(300L, prepared.platformGeofence?.androidSettings?.expirationDurationMillis)
        assertTrue(store.commitSynchronizedGeofence(prepared, "current"))

        assertEquals(1_500L, backend.values[expirationKey("office")])
        assertEquals(
            300L,
            store.getRecoverableGeofence("office")
                ?.androidSettings
                ?.expirationDurationMillis
        )
        assertEquals(
            500L,
            store.getConfiguredGeofence("office")
                ?.configuredGeofence
                ?.androidSettings
                ?.expirationDurationMillis
        )
    }

    private fun geofence(
        id: String = "office",
        callbackHandle: Long = 7,
        callbackContext: Long? = null,
        duration: Long? = null
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
            expirationDurationMillis = duration,
            loiteringDelayMillis = 0,
            notificationResponsivenessMillis = null
        ),
        callbackHandle = callbackHandle,
        callbackContext = callbackContext
    )

    private companion object {
        const val configuredIdsKey = Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY

        fun recordKey(id: String) = Constants.PERSISTENT_GEOFENCE_KEY_PREFIX + id

        fun expirationKey(id: String) =
            Constants.PERSISTENT_GEOFENCE_EXPIRATION_KEY_PREFIX + id

        fun recoveryEligibleKey(id: String) =
            Constants.PERSISTENT_GEOFENCE_RECOVERY_ELIGIBLE_KEY_PREFIX + id

        fun activeKey(id: String) = Constants.PERSISTENT_GEOFENCE_ACTIVE_KEY_PREFIX + id

        fun callbackPackageFingerprintKey(id: String) =
            Constants.PERSISTENT_GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_KEY_PREFIX + id
    }
}

private class FakeGeofencePersistenceBackend : GeofencePersistenceBackend {
    val values = mutableMapOf<String, Any>()
    var failNextCommit = false
    var throwOnNextEdit = false
    var editCalls = 0

    override fun keys(): Set<String> = values.keys.toSet()

    override fun contains(key: String): Boolean = values.containsKey(key)

    override fun getString(key: String): String? {
        val value = values[key] ?: return null
        return value as? String
            ?: throw ClassCastException("Value for $key is not a String")
    }

    override fun getStringSet(key: String): Set<String>? {
        val value = values[key] ?: return null
        if (value !is Set<*> || value.any { it !is String }) {
            throw ClassCastException("Value for $key is not a String set")
        }
        return value.filterIsInstance<String>().toSet()
    }

    override fun getLong(key: String, defaultValue: Long): Long {
        val value = values[key] ?: return defaultValue
        return value as? Long
            ?: throw ClassCastException("Value for $key is not a Long")
    }

    override fun getBoolean(key: String, defaultValue: Boolean): Boolean {
        val value = values[key] ?: return defaultValue
        return value as? Boolean
            ?: throw ClassCastException("Value for $key is not a Boolean")
    }

    override fun edit(block: GeofencePersistenceEditor.() -> Unit): Boolean {
        editCalls += 1
        if (throwOnNextEdit) {
            throwOnNextEdit = false
            throw IllegalStateException("Injected editor failure")
        }
        val pending = values.toMutableMap()
        val editor = object : GeofencePersistenceEditor {
            override fun putString(key: String, value: String) {
                pending[key] = value
            }

            override fun putStringSet(key: String, value: Set<String>) {
                pending[key] = value.toSet()
            }

            override fun putLong(key: String, value: Long) {
                pending[key] = value
            }

            override fun putBoolean(key: String, value: Boolean) {
                pending[key] = value
            }

            override fun remove(key: String) {
                pending.remove(key)
            }
        }
        editor.block()
        if (failNextCommit) {
            failNextCommit = false
            return false
        }
        values.clear()
        values.putAll(pending)
        return true
    }
}
