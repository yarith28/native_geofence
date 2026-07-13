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

internal data class PersistedValue<T>(
    val present: Boolean,
    val value: T?
)

internal data class GeofencePersistenceSnapshot(
    val id: String,
    val rawIds: PersistedValue<Set<String>>,
    val configuredIds: PersistedValue<Set<String>>,
    val recordJson: PersistedValue<String>,
    val expirationDeadlineMillis: PersistedValue<Long>,
    val recoveryEligible: PersistedValue<Boolean>,
    val active: PersistedValue<Boolean>
)

internal data class StoredGeofenceRegistration(
    val configuredGeofence: GeofenceWire,
    val expirationDeadlineMillis: Long?,
    val recoveryEligible: Boolean,
    val active: Boolean,
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
        active: Boolean = true
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
        }
    }

    fun getConfiguredGeofence(id: String): StoredGeofenceRegistration? = load(id)

    fun getRecoverableGeofence(id: String): GeofenceWire? =
        recoveryEntry(id).geofenceToRecover

    fun recoveryInventory(): List<GeofenceRecoveryInventoryEntry> =
        rawIds().map(::recoveryEntry)

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
        return backend.edit {
            putStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, rawIds)
            putBoolean(recoveryEligibleKey(id), false)
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
        active = booleanValue(activeKey(id))
    )

    fun restore(snapshot: GeofencePersistenceSnapshot): Boolean = backend.edit {
        restoreStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, snapshot.rawIds)
        restoreStringSet(
            Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY,
            snapshot.configuredIds
        )
        restoreString(recordKey(snapshot.id), snapshot.recordJson)
        restoreLong(expirationKey(snapshot.id), snapshot.expirationDeadlineMillis)
        restoreBoolean(recoveryEligibleKey(snapshot.id), snapshot.recoveryEligible)
        restoreBoolean(activeKey(snapshot.id), snapshot.active)
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
            }
        }
    }

    private fun load(id: String): StoredGeofenceRegistration? {
        val rawRecord = safeRead { backend.getString(recordKey(id)) } ?: return null
        val geofence = try {
            Json.decodeFromString<GeofenceStorage>(rawRecord).toWire()
        } catch (_: Exception) {
            // The raw ID and bytes intentionally remain available for cleanup and
            // exact rollback. Never log the stored JSON or callback metadata.
            return null
        }

        val durationMillis = geofence.androidSettings.expirationDurationMillis
        val hasDeadline = safeRead { backend.contains(expirationKey(id)) } ?: false
        var deadlineMillis =
            if (hasDeadline) safeRead { backend.getLong(expirationKey(id), 0L) } else null

        val hasRecoveryEligible =
            safeRead { backend.contains(recoveryEligibleKey(id)) } ?: false
        val hasActive = safeRead { backend.contains(activeKey(id)) } ?: false
        val recoveryEligible =
            if (hasRecoveryEligible) {
                safeRead { backend.getBoolean(recoveryEligibleKey(id), true) } ?: true
            } else {
                true
            }
        val active =
            if (hasActive) safeRead { backend.getBoolean(activeKey(id), true) } ?: true else true

        var metadataDurable = true
        val needsDeadlineMigration = durationMillis != null && !hasDeadline
        val staleDeadline = durationMillis == null && hasDeadline
        val needsStateMigration = !hasRecoveryEligible || !hasActive
        val needsConfiguredIndexMigration =
            !(safeRead {
                backend.contains(Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY)
            } ?: false)

        if (needsDeadlineMigration) {
            deadlineMillis = safeDeadline(nowMillis(), durationMillis!!)
        }

        if (
            needsDeadlineMigration || staleDeadline || needsStateMigration ||
            needsConfiguredIndexMigration
        ) {
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
            if (staleDeadline) {
                deadlineMillis = null
            }
        }

        return StoredGeofenceRegistration(
            configuredGeofence = geofence,
            expirationDeadlineMillis = deadlineMillis,
            recoveryEligible = recoveryEligible,
            active = active,
            lifecycleMetadataDurable = metadataDurable
        )
    }

    private fun rawIndex(): Set<String> =
        safeRead { backend.getStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY) }
            ?: emptySet()

    private fun configuredIndex(): Set<String> {
        val hasConfiguredIndex =
            safeRead {
                backend.contains(Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY)
            } ?: false
        return if (hasConfiguredIndex) {
            safeRead {
                backend.getStringSet(Constants.PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY)
            } ?: emptySet()
        } else {
            // Legacy records used the raw index as their configured index.
            rawIndex()
        }
    }

    private fun stringValue(key: String): PersistedValue<String> {
        val present = safeRead { backend.contains(key) } ?: false
        return PersistedValue(present, if (present) safeRead { backend.getString(key) } else null)
    }

    private fun stringSetValue(key: String): PersistedValue<Set<String>> {
        val present = safeRead { backend.contains(key) } ?: false
        return PersistedValue(
            present,
            if (present) safeRead { backend.getStringSet(key)?.toSet() } else null
        )
    }

    private fun longValue(key: String): PersistedValue<Long> {
        val present = safeRead { backend.contains(key) } ?: false
        return PersistedValue(
            present,
            if (present) safeRead { backend.getLong(key, 0L) } else null
        )
    }

    private fun booleanValue(key: String): PersistedValue<Boolean> {
        val present = safeRead { backend.contains(key) } ?: false
        return PersistedValue(
            present,
            if (present) safeRead { backend.getBoolean(key, false) } else null
        )
    }

    private fun GeofencePersistenceEditor.restoreStringSet(
        key: String,
        value: PersistedValue<Set<String>>
    ) {
        if (value.present) putStringSet(key, requireNotNull(value.value)) else remove(key)
    }

    private fun GeofencePersistenceEditor.restoreString(
        key: String,
        value: PersistedValue<String>
    ) {
        if (value.present) putString(key, requireNotNull(value.value)) else remove(key)
    }

    private fun GeofencePersistenceEditor.restoreLong(
        key: String,
        value: PersistedValue<Long>
    ) {
        if (value.present) putLong(key, requireNotNull(value.value)) else remove(key)
    }

    private fun GeofencePersistenceEditor.restoreBoolean(
        key: String,
        value: PersistedValue<Boolean>
    ) {
        if (value.present) putBoolean(key, requireNotNull(value.value)) else remove(key)
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

        private fun ownedIdFromKey(key: String): String? = when {
            key.startsWith(Constants.PERSISTENT_GEOFENCE_KEY_PREFIX) ->
                key.removePrefix(Constants.PERSISTENT_GEOFENCE_KEY_PREFIX)
            key.startsWith(Constants.PERSISTENT_GEOFENCE_EXPIRATION_KEY_PREFIX) ->
                key.removePrefix(Constants.PERSISTENT_GEOFENCE_EXPIRATION_KEY_PREFIX)
            key.startsWith(Constants.PERSISTENT_GEOFENCE_RECOVERY_ELIGIBLE_KEY_PREFIX) ->
                key.removePrefix(Constants.PERSISTENT_GEOFENCE_RECOVERY_ELIGIBLE_KEY_PREFIX)
            key.startsWith(Constants.PERSISTENT_GEOFENCE_ACTIVE_KEY_PREFIX) ->
                key.removePrefix(Constants.PERSISTENT_GEOFENCE_ACTIVE_KEY_PREFIX)
            else -> null
        }?.takeIf(String::isNotEmpty)
    }
}
