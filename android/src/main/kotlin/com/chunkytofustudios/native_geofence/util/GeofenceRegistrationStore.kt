package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.model.GeofenceStorage
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal interface GeofencePersistenceEditor {
    fun putString(key: String, value: String)
    fun putStringSet(key: String, value: Set<String>)
    fun putLong(key: String, value: Long)
    fun putBoolean(key: String, value: Boolean)
    fun remove(key: String)
}

internal interface GeofencePersistenceBackend {
    fun keys(): Set<String>
    fun contains(key: String): Boolean
    fun getString(key: String): String?
    fun getStringSet(key: String): Set<String>?
    fun getLong(key: String, defaultValue: Long): Long
    fun getBoolean(key: String, defaultValue: Boolean): Boolean
    fun edit(block: GeofencePersistenceEditor.() -> Unit): Boolean
}

internal sealed interface PersistedValue<out T> {
    data object Absent : PersistedValue<Nothing>

    data class Readable<T>(val value: T) : PersistedValue<T>

    data object Corrupt : PersistedValue<Nothing>
}

internal data class GeofencePersistenceSnapshot(
    val id: String,
    val rawIds: PersistedValue<Set<String>>,
    val configuredIds: PersistedValue<Set<String>>,
    val recordJson: PersistedValue<String>,
    val expirationDeadlineMillis: PersistedValue<Long>,
    val recoveryEligible: PersistedValue<Boolean>,
    val active: PersistedValue<Boolean>,
    val callbackPackageFingerprint: PersistedValue<String>
)

internal data class StoredGeofenceRegistration(
    val configuredGeofence: GeofenceWire,
    val expirationDeadlineMillis: Long?,
    val recoveryEligible: Boolean,
    val active: Boolean,
    val callbackPackageFingerprint: String?,
    val lifecycleMetadataDurable: Boolean
)

internal enum class GeofenceRecoveryDisposition {
    RECOVERABLE,
    PENDING_CLEANUP,
    CORRUPT_OR_RAW_ONLY,
    UNKNOWN_LIFECYCLE
}

internal data class GeofenceRecoveryInventoryEntry(
    val id: String,
    val disposition: GeofenceRecoveryDisposition,
    val storedRegistration: StoredGeofenceRegistration?,
    val geofenceToRecover: GeofenceWire?
)

internal enum class GeofenceStatusDisposition {
    ACTIVE,
    RECOVERABLE,
    PENDING_CLEANUP,
    CORRUPT_OR_RAW_ONLY,
    UNKNOWN_LIFECYCLE
}

internal data class GeofenceStatusInventoryEntry(
    val id: String,
    val disposition: GeofenceStatusDisposition,
    val callbackPackageFingerprint: String?
)

internal data class PreparedSynchronizedGeofence(
    val configuredGeofence: GeofenceWire,
    val platformGeofence: GeofenceWire?,
    val expirationDeadlineMillis: Long?
)

/**
 * Durable Android registration state with a deliberately small backend seam so
 * lifecycle and rollback behavior can be tested without Android framework IO.
 */
internal class GeofenceRegistrationStore(
    private val backend: GeofencePersistenceBackend,
    private val nowMillis: () -> Long = System::currentTimeMillis
) {
    fun saveConfiguredGeofence(
        geofence: GeofenceWire,
        recoveryEligible: Boolean = true,
        active: Boolean = true,
        callbackPackageFingerprint: String? = null
    ): Boolean {
        val rawIds = rawIndex().toMutableSet().apply { add(geofence.id) }
        val configuredIds = configuredIndex().toMutableSet().apply { add(geofence.id) }
        val recordJson = Json.encodeToString(GeofenceStorage.fromWire(geofence))
        val durationMillis = geofence.androidSettings.expirationDurationMillis
        val deadlineMillis = durationMillis?.let { safeDeadline(nowMillis(), it) }

        return backend.edit {
            putStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, rawIds)
            putStringSet(Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY, configuredIds)
            putString(recordKey(geofence.id), recordJson)
            if (deadlineMillis == null) {
                remove(expirationKey(geofence.id))
            } else {
                putLong(expirationKey(geofence.id), deadlineMillis)
            }
            putBoolean(recoveryEligibleKey(geofence.id), recoveryEligible)
            putBoolean(activeKey(geofence.id), active)
            if (callbackPackageFingerprint == null) {
                remove(callbackPackageFingerprintKey(geofence.id))
            } else {
                putString(callbackPackageFingerprintKey(geofence.id), callbackPackageFingerprint)
            }
        }
    }

    /**
     * Prepares an app-owned synchronization update without publishing its new
     * callback metadata or extending an existing finite lifetime. A new or
     * already-expired desired registration receives a fresh explicit lifetime;
     * an active replacement keeps its old deadline.
     */
    fun prepareSynchronizedGeofence(
        geofence: GeofenceWire
    ): PreparedSynchronizedGeofence {
        val previous = load(geofence.id)
        val durationMillis = geofence.androidSettings.expirationDurationMillis
        val previousDuration = previous
            ?.configuredGeofence
            ?.androidSettings
            ?.expirationDurationMillis
        val previousDeadline = previous?.expirationDeadlineMillis
        val now = nowMillis()
        val deadlineMillis = if (
            durationMillis != null &&
            durationMillis == previousDuration &&
            previousDeadline != null &&
            previousDeadline > now
        ) {
            previousDeadline
        } else {
            durationMillis?.let { safeDeadline(now, it) }
        }
        val platformGeofence = deadlineMillis?.let { deadline ->
            val remaining = deadline - now
            if (remaining <= 0L) null else geofence.copy(
                androidSettings = geofence.androidSettings.copy(
                    expirationDurationMillis = remaining
                )
            )
        } ?: if (durationMillis == null) geofence else null
        return PreparedSynchronizedGeofence(
            configuredGeofence = geofence,
            platformGeofence = platformGeofence,
            expirationDeadlineMillis = deadlineMillis
        )
    }

    fun commitSynchronizedGeofence(
        prepared: PreparedSynchronizedGeofence,
        callbackPackageFingerprint: String
    ): Boolean {
        val geofence = prepared.configuredGeofence
        val rawIds = rawIndex().toMutableSet().apply { add(geofence.id) }
        val configuredIds = configuredIndex().toMutableSet().apply { add(geofence.id) }
        val recordJson = Json.encodeToString(GeofenceStorage.fromWire(geofence))
        return backend.edit {
            putStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, rawIds)
            putStringSet(Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY, configuredIds)
            putString(recordKey(geofence.id), recordJson)
            if (prepared.expirationDeadlineMillis == null) {
                remove(expirationKey(geofence.id))
            } else {
                putLong(
                    expirationKey(geofence.id),
                    prepared.expirationDeadlineMillis
                )
            }
            putBoolean(recoveryEligibleKey(geofence.id), true)
            putBoolean(activeKey(geofence.id), true)
            putString(
                callbackPackageFingerprintKey(geofence.id),
                callbackPackageFingerprint
            )
        }
    }

    fun updateCallbackMetadata(
        id: String,
        callbackHandle: Long,
        callbackContext: Long?,
        callbackPackageFingerprint: String
    ): Boolean {
        val stored = load(id) ?: return false
        val updated = stored.configuredGeofence.copy(
            callbackHandle = callbackHandle,
            callbackContext = callbackContext
        )
        val recordJson = Json.encodeToString(GeofenceStorage.fromWire(updated))
        return backend.edit {
            putString(recordKey(id), recordJson)
            putString(callbackPackageFingerprintKey(id), callbackPackageFingerprint)
        }
    }

    fun getConfiguredGeofence(id: String): StoredGeofenceRegistration? = load(id)

    fun getRecoverableGeofence(id: String): GeofenceWire? =
        recoveryEntry(id).geofenceToRecover

    fun recoveryInventory(): List<GeofenceRecoveryInventoryEntry> =
        rawIds().map(::recoveryEntry)

    /**
     * Inspects lifecycle evidence without repairing legacy metadata, expiring a
     * record, or otherwise changing durable state.
     */
    fun statusInventory(): List<GeofenceStatusInventoryEntry> {
        val configured = configuredIds().toSet()
        return rawIds().map { id ->
            val stored = load(id, migrateLegacyMetadata = false)
            val disposition = when {
                stored == null -> GeofenceStatusDisposition.CORRUPT_OR_RAW_ONLY
                !stored.lifecycleMetadataDurable || id !in configured ->
                    GeofenceStatusDisposition.UNKNOWN_LIFECYCLE
                stored.expirationDeadlineMillis?.let { it <= nowMillis() } == true ->
                    GeofenceStatusDisposition.PENDING_CLEANUP
                stored.active && stored.recoveryEligible -> GeofenceStatusDisposition.ACTIVE
                !stored.active && stored.recoveryEligible ->
                    GeofenceStatusDisposition.RECOVERABLE
                !stored.active && !stored.recoveryEligible ->
                    GeofenceStatusDisposition.PENDING_CLEANUP
                else -> GeofenceStatusDisposition.UNKNOWN_LIFECYCLE
            }
            GeofenceStatusInventoryEntry(
                id = id,
                disposition = disposition,
                callbackPackageFingerprint = callbackPackageFingerprint(id)
            )
        }
    }

    private fun recoveryEntry(id: String): GeofenceRecoveryInventoryEntry {
        val stored = load(id) ?: return GeofenceRecoveryInventoryEntry(
            id = id,
            disposition = GeofenceRecoveryDisposition.CORRUPT_OR_RAW_ONLY,
            storedRegistration = null,
            geofenceToRecover = null,
        )
        if (!stored.lifecycleMetadataDurable) {
            return stored.asRecoveryEntry(id, GeofenceRecoveryDisposition.UNKNOWN_LIFECYCLE)
        }
        if (!stored.recoveryEligible) {
            return stored.asRecoveryEntry(id, GeofenceRecoveryDisposition.PENDING_CLEANUP)
        }

        val deadline = stored.expirationDeadlineMillis
            ?: return stored.asRecoveryEntry(
                id,
                GeofenceRecoveryDisposition.RECOVERABLE,
                stored.configuredGeofence
            )
        val now = nowMillis()
        if (deadline <= now) {
            // Keep the canonical record and raw ID until Play services cleanup
            // succeeds, but never make an expired registration recoverable.
            setLifecycleState(id, recoveryEligible = false, active = false)
            return stored.asRecoveryEntry(id, GeofenceRecoveryDisposition.PENDING_CLEANUP)
        }

        val geofenceToRecover = stored.configuredGeofence.copy(
            androidSettings = stored.configuredGeofence.androidSettings.copy(
                expirationDurationMillis = deadline - now,
            ),
        )
        return stored.asRecoveryEntry(
            id,
            GeofenceRecoveryDisposition.RECOVERABLE,
            geofenceToRecover,
        )
    }

    fun getConfiguredGeofences(): List<StoredGeofenceRegistration> =
        configuredIds().mapNotNull(::getConfiguredGeofence)

    /** Reads configured state without performing legacy metadata migrations. */
    fun inspectConfiguredGeofences(): List<StoredGeofenceRegistration> =
        configuredIds().mapNotNull { id -> load(id, migrateLegacyMetadata = false) }

    fun callbackPackageFingerprint(id: String): String? =
        safeRead { backend.getString(callbackPackageFingerprintKey(id)) }

    fun isCallbackRefreshRequired(): Boolean =
        safeRead { backend.getBoolean(Constants.CALLBACK_REFRESH_REQUIRED_KEY, false) } ?: false

    fun markCallbackRefreshRequired(): Boolean = backend.edit {
        putBoolean(Constants.CALLBACK_REFRESH_REQUIRED_KEY, true)
    }

    fun synchronizationFingerprint(): String? = safeRead {
        backend.getString(Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY)
    }

    /** Restores only the transaction fingerprint; callback-refresh evidence is independent. */
    fun restoreSynchronizationFingerprint(fingerprint: String?): Boolean = backend.edit {
        if (fingerprint == null) {
            remove(Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY)
        } else {
            putString(Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY, fingerprint)
        }
    }

    /** Publishes successful synchronization and clears prior stale-callback evidence atomically. */
    fun commitSynchronization(fingerprint: String): Boolean = backend.edit {
        putString(Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY, fingerprint)
        remove(Constants.CALLBACK_REFRESH_REQUIRED_KEY)
    }

    fun getRecoverableGeofences(): List<GeofenceWire> =
        recoveryInventory().mapNotNull(GeofenceRecoveryInventoryEntry::geofenceToRecover)

    fun configuredIds(): List<String> = configuredIndex().toList().sorted()

    fun rawIds(): List<String> {
        val result = rawIndex().toMutableSet()
        result.addAll(configuredIndex())
        for (key in backend.keys()) {
            ownedIdFromKey(key)?.let(result::add)
        }
        return result.toList().sorted()
    }

    fun setLifecycleState(
        id: String,
        recoveryEligible: Boolean,
        active: Boolean
    ): Boolean = backend.edit {
        putBoolean(recoveryEligibleKey(id), recoveryEligible)
        putBoolean(activeKey(id), active)
    }

    /**
     * Retains an orphan ID and any canonical bytes while marking it ineligible
     * for recovery. Platform cleanup must succeed before the caller removes it.
     */
    fun markForPlatformCleanup(id: String): Boolean {
        val rawIds = rawIndex().toMutableSet().apply { add(id) }
        return safeEdit {
            putStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, rawIds)
            putBoolean(recoveryEligibleKey(id), false)
            putBoolean(activeKey(id), false)
        }
    }

    /**
     * Retains a canonical registration as positive ownership evidence while
     * ensuring recovery cannot mistake an unconfirmed platform rearm for active.
     */
    fun markForRecovery(id: String): Boolean {
        val rawIds = rawIndex().toMutableSet().apply { add(id) }
        return safeEdit {
            putStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, rawIds)
            putBoolean(recoveryEligibleKey(id), true)
            putBoolean(activeKey(id), false)
        }
    }

    fun snapshot(id: String): GeofencePersistenceSnapshot = GeofencePersistenceSnapshot(
        id = id,
        rawIds = stringSetValue(Constants.PERSISTENT_GEOFENCES_IDS_KEY),
        configuredIds = stringSetValue(Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY),
        recordJson = stringValue(recordKey(id)),
        expirationDeadlineMillis = longValue(expirationKey(id)),
        recoveryEligible = booleanValue(recoveryEligibleKey(id)),
        active = booleanValue(activeKey(id)),
        callbackPackageFingerprint = stringValue(callbackPackageFingerprintKey(id))
    )

    fun restore(snapshot: GeofencePersistenceSnapshot): Boolean {
        if (snapshot.persistedValues().any { it is PersistedValue.Corrupt }) {
            // An unreadable value cannot be reproduced through the typed editor.
            // Preserve every current byte instead of applying a partial rollback.
            return false
        }
        return safeEdit {
            restoreStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, snapshot.rawIds)
            restoreStringSet(
                Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY,
                snapshot.configuredIds
            )
            restoreString(recordKey(snapshot.id), snapshot.recordJson)
            restoreLong(expirationKey(snapshot.id), snapshot.expirationDeadlineMillis)
            restoreBoolean(recoveryEligibleKey(snapshot.id), snapshot.recoveryEligible)
            restoreBoolean(activeKey(snapshot.id), snapshot.active)
            restoreString(
                callbackPackageFingerprintKey(snapshot.id),
                snapshot.callbackPackageFingerprint
            )
        }
    }

    /** Call only after platform cleanup for [id] has succeeded. */
    fun removeAfterPlatformCleanup(id: String): Boolean {
        val rawIds = rawIndex().toMutableSet().apply { remove(id) }
        val configuredIds = configuredIndex().toMutableSet().apply { remove(id) }
        return backend.edit {
            putStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, rawIds)
            putStringSet(Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY, configuredIds)
            remove(recordKey(id))
            remove(expirationKey(id))
            remove(recoveryEligibleKey(id))
            remove(activeKey(id))
            remove(callbackPackageFingerprintKey(id))
        }
    }

    /** Call only after platform cleanup for every raw plugin-owned ID succeeds. */
    fun removeAllAfterPlatformCleanup(): Boolean {
        val ids = rawIds()
        return backend.edit {
            remove(Constants.PERSISTENT_GEOFENCES_IDS_KEY)
            remove(Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY)
            for (id in ids) {
                remove(recordKey(id))
                remove(expirationKey(id))
                remove(recoveryEligibleKey(id))
                remove(activeKey(id))
                remove(callbackPackageFingerprintKey(id))
            }
        }
    }

    private fun load(
        id: String,
        migrateLegacyMetadata: Boolean = true
    ): StoredGeofenceRegistration? {
        val rawRecord = when (val stored = stringValue(recordKey(id))) {
            is PersistedValue.Readable -> stored.value
            PersistedValue.Absent,
            PersistedValue.Corrupt -> return null
        }
        val geofence = try {
            Json.decodeFromString<GeofenceStorage>(rawRecord).toWire()
        } catch (_: Exception) {
            // The raw ID and bytes intentionally remain available for cleanup and
            // exact rollback. Never log the stored JSON or callback metadata.
            return null
        }

        val durationMillis = geofence.androidSettings.expirationDurationMillis
        val deadline = longValue(expirationKey(id))
        val storedRecoveryEligible = booleanValue(recoveryEligibleKey(id))
        val storedActive = booleanValue(activeKey(id))
        val rawIndex = stringSetValue(Constants.PERSISTENT_GEOFENCES_IDS_KEY)
        val configuredIndex =
            stringSetValue(Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY)
        val lifecycleCorrupt = listOf<PersistedValue<*>>(
            deadline,
            storedRecoveryEligible,
            storedActive,
            rawIndex,
            configuredIndex,
        ).any { it is PersistedValue.Corrupt }

        var deadlineMillis: Long? = when (deadline) {
            is PersistedValue.Readable -> deadline.value
            PersistedValue.Absent,
            PersistedValue.Corrupt -> null
        }
        val readableRecoveryEligible = when (storedRecoveryEligible) {
            is PersistedValue.Readable -> storedRecoveryEligible.value
            PersistedValue.Absent -> true
            PersistedValue.Corrupt -> false
        }
        val readableActive = when (storedActive) {
            is PersistedValue.Readable -> storedActive.value
            PersistedValue.Absent -> true
            PersistedValue.Corrupt -> false
        }
        val recoveryEligible = if (lifecycleCorrupt) false else readableRecoveryEligible
        val active = if (lifecycleCorrupt) false else readableActive
        val callbackPackageFingerprint = when (
            val stored = stringValue(callbackPackageFingerprintKey(id))
        ) {
            is PersistedValue.Readable -> stored.value
            PersistedValue.Absent,
            PersistedValue.Corrupt -> null
        }

        val needsDeadlineMigration =
            durationMillis != null && deadline is PersistedValue.Absent
        val staleDeadline =
            durationMillis == null && deadline is PersistedValue.Readable
        val needsStateMigration =
            storedRecoveryEligible is PersistedValue.Absent ||
                storedActive is PersistedValue.Absent
        val needsRawIndexMigration = rawIndex is PersistedValue.Absent
        val needsConfiguredIndexMigration = configuredIndex is PersistedValue.Absent

        if (needsDeadlineMigration) {
            deadlineMillis = safeDeadline(nowMillis(), durationMillis!!)
        }

        val needsMigration =
            needsDeadlineMigration || staleDeadline || needsStateMigration ||
                needsRawIndexMigration || needsConfiguredIndexMigration
        var metadataDurable = !lifecycleCorrupt && !needsMigration
        if (!lifecycleCorrupt && needsMigration && migrateLegacyMetadata) {
            val rawIds = rawIndex().toMutableSet().apply { add(id) }
            val configuredIds = configuredIndex().toMutableSet().apply { add(id) }
            metadataDurable = safeEdit {
                putStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, rawIds)
                putStringSet(Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY, configuredIds)
                if (durationMillis == null) {
                    remove(expirationKey(id))
                } else {
                    putLong(expirationKey(id), requireNotNull(deadlineMillis))
                }
                putBoolean(recoveryEligibleKey(id), recoveryEligible)
                putBoolean(activeKey(id), active)
            }
            if (!metadataDurable && needsDeadlineMigration) {
                // Preserve the one derived absolute deadline even when the larger
                // legacy lifecycle migration cannot commit. A later repair can
                // then reuse this evidence instead of granting a fresh lifetime.
                safeEdit {
                    putLong(expirationKey(id), requireNotNull(deadlineMillis))
                }
            }
        }
        if (staleDeadline) {
            deadlineMillis = null
        }

        return StoredGeofenceRegistration(
            configuredGeofence = geofence,
            expirationDeadlineMillis = deadlineMillis,
            recoveryEligible = recoveryEligible,
            active = active,
            callbackPackageFingerprint = callbackPackageFingerprint,
            lifecycleMetadataDurable = metadataDurable
        )
    }

    private fun rawIndex(): Set<String> = when (
        val stored = stringSetValue(Constants.PERSISTENT_GEOFENCES_IDS_KEY)
    ) {
        is PersistedValue.Readable -> stored.value
        PersistedValue.Absent,
        PersistedValue.Corrupt -> emptySet()
    }

    private fun configuredIndex(): Set<String> = when (
        val stored = stringSetValue(Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY)
    ) {
        is PersistedValue.Readable -> stored.value
        PersistedValue.Absent -> {
            // Legacy records used the raw index as their configured index.
            rawIndex()
        }
        PersistedValue.Corrupt -> emptySet()
    }

    private fun stringValue(key: String): PersistedValue<String> =
        persistedValue(key) { backend.getString(key) }

    private fun stringSetValue(key: String): PersistedValue<Set<String>> =
        persistedValue(key) { backend.getStringSet(key)?.toSet() }

    private fun longValue(key: String): PersistedValue<Long> =
        persistedValue(key) { backend.getLong(key, 0L) }

    private fun booleanValue(key: String): PersistedValue<Boolean> =
        persistedValue(key) { backend.getBoolean(key, false) }

    private inline fun <T : Any> persistedValue(
        key: String,
        read: () -> T?,
    ): PersistedValue<T> {
        val present = safeRead { backend.contains(key) } ?: return PersistedValue.Corrupt
        if (!present) return PersistedValue.Absent
        val value = safeRead(read) ?: return PersistedValue.Corrupt
        return PersistedValue.Readable(value)
    }

    private fun GeofencePersistenceSnapshot.persistedValues(): List<PersistedValue<*>> =
        listOf(
            rawIds,
            configuredIds,
            recordJson,
            expirationDeadlineMillis,
            recoveryEligible,
            active,
            callbackPackageFingerprint,
        )

    private fun GeofencePersistenceEditor.restoreStringSet(
        key: String,
        value: PersistedValue<Set<String>>
    ) {
        when (value) {
            PersistedValue.Absent -> remove(key)
            is PersistedValue.Readable -> putStringSet(key, value.value)
            PersistedValue.Corrupt -> Unit
        }
    }

    private fun GeofencePersistenceEditor.restoreString(
        key: String,
        value: PersistedValue<String>
    ) {
        when (value) {
            PersistedValue.Absent -> remove(key)
            is PersistedValue.Readable -> putString(key, value.value)
            PersistedValue.Corrupt -> Unit
        }
    }

    private fun GeofencePersistenceEditor.restoreLong(
        key: String,
        value: PersistedValue<Long>
    ) {
        when (value) {
            PersistedValue.Absent -> remove(key)
            is PersistedValue.Readable -> putLong(key, value.value)
            PersistedValue.Corrupt -> Unit
        }
    }

    private fun GeofencePersistenceEditor.restoreBoolean(
        key: String,
        value: PersistedValue<Boolean>
    ) {
        when (value) {
            PersistedValue.Absent -> remove(key)
            is PersistedValue.Readable -> putBoolean(key, value.value)
            PersistedValue.Corrupt -> Unit
        }
    }

    private inline fun <T> safeRead(block: () -> T): T? = try {
        block()
    } catch (_: RuntimeException) {
        null
    }

    private fun safeEdit(block: GeofencePersistenceEditor.() -> Unit): Boolean = try {
        backend.edit(block)
    } catch (_: RuntimeException) {
        false
    }

    private fun StoredGeofenceRegistration.asRecoveryEntry(
        id: String,
        disposition: GeofenceRecoveryDisposition,
        geofenceToRecover: GeofenceWire? = null
    ) = GeofenceRecoveryInventoryEntry(
        id = id,
        disposition = disposition,
        storedRegistration = this,
        geofenceToRecover = geofenceToRecover
    )

    companion object {
        internal fun safeDeadline(nowMillis: Long, durationMillis: Long): Long {
            if (durationMillis <= 0L) {
                return nowMillis
            }
            return if (nowMillis > Long.MAX_VALUE - durationMillis) {
                Long.MAX_VALUE
            } else {
                nowMillis + durationMillis
            }
        }

        private fun recordKey(id: String) = Constants.PERSISTENT_GEOFENCE_KEY_PREFIX + id

        private fun expirationKey(id: String) =
            Constants.PERSISTENT_GEOFENCE_EXPIRATION_KEY_PREFIX + id

        private fun recoveryEligibleKey(id: String) =
            Constants.PERSISTENT_GEOFENCE_RECOVERY_ELIGIBLE_KEY_PREFIX + id

        private fun activeKey(id: String) = Constants.PERSISTENT_GEOFENCE_ACTIVE_KEY_PREFIX + id

        private fun callbackPackageFingerprintKey(id: String) =
            Constants.PERSISTENT_GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_KEY_PREFIX + id

        private fun ownedIdFromKey(key: String): String? = when {
            key.startsWith(Constants.PERSISTENT_GEOFENCE_KEY_PREFIX) ->
                key.removePrefix(Constants.PERSISTENT_GEOFENCE_KEY_PREFIX)
            key.startsWith(Constants.PERSISTENT_GEOFENCE_EXPIRATION_KEY_PREFIX) ->
                key.removePrefix(Constants.PERSISTENT_GEOFENCE_EXPIRATION_KEY_PREFIX)
            key.startsWith(Constants.PERSISTENT_GEOFENCE_RECOVERY_ELIGIBLE_KEY_PREFIX) ->
                key.removePrefix(Constants.PERSISTENT_GEOFENCE_RECOVERY_ELIGIBLE_KEY_PREFIX)
            key.startsWith(Constants.PERSISTENT_GEOFENCE_ACTIVE_KEY_PREFIX) ->
                key.removePrefix(Constants.PERSISTENT_GEOFENCE_ACTIVE_KEY_PREFIX)
            key.startsWith(
                Constants.PERSISTENT_GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_KEY_PREFIX
            ) -> key.removePrefix(
                Constants.PERSISTENT_GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_KEY_PREFIX
            )
            else -> null
        }?.takeIf(String::isNotEmpty)
    }
}
