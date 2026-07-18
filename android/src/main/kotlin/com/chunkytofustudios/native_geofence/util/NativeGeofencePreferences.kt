package com.chunkytofustudios.native_geofence.util

import android.content.Context
import com.chunkytofustudios.native_geofence.Constants
import java.io.File
import java.io.FileOutputStream
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
private data class NativeGeofencePreferencesSnapshot(
    val strings: Map<String, String> = emptyMap(),
    val stringSets: Map<String, Set<String>> = emptyMap(),
    val longs: Map<String, Long> = emptyMap(),
    val ints: Map<String, Int> = emptyMap(),
    val booleans: Map<String, Boolean> = emptyMap(),
) {
    val keys: Set<String>
        get() = strings.keys + stringSets.keys + longs.keys + ints.keys + booleans.keys

    fun asMap(): Map<String, Any> = buildMap {
        putAll(strings)
        putAll(stringSets)
        putAll(longs)
        putAll(ints)
        putAll(booleans)
    }
}

private sealed interface NativeGeofencePreferenceValue {
    data class StringValue(val value: String) : NativeGeofencePreferenceValue
    data class StringSetValue(val value: Set<String>) : NativeGeofencePreferenceValue
    data class LongValue(val value: Long) : NativeGeofencePreferenceValue
    data class IntValue(val value: Int) : NativeGeofencePreferenceValue
    data class BooleanValue(val value: Boolean) : NativeGeofencePreferenceValue
}

/**
 * Small typed preference store rooted in `noBackupFilesDir`.
 *
 * Writes use a temporary file plus a recoverable backup so an interrupted
 * commit retains either the old snapshot or the complete new snapshot.
 */
internal class NoBackupNativeGeofencePreferences(
    private val file: File,
) {
    internal inner class Editor {
        private val puts = mutableMapOf<String, NativeGeofencePreferenceValue>()
        private val removals = mutableSetOf<String>()

        fun putString(key: String, value: String): Editor = put(
            key,
            NativeGeofencePreferenceValue.StringValue(value),
        )

        fun putStringSet(key: String, value: Set<String>): Editor = put(
            key,
            NativeGeofencePreferenceValue.StringSetValue(value.toSet()),
        )

        fun putLong(key: String, value: Long): Editor = put(
            key,
            NativeGeofencePreferenceValue.LongValue(value),
        )

        fun putInt(key: String, value: Int): Editor = put(
            key,
            NativeGeofencePreferenceValue.IntValue(value),
        )

        fun putBoolean(key: String, value: Boolean): Editor = put(
            key,
            NativeGeofencePreferenceValue.BooleanValue(value),
        )

        fun remove(key: String): Editor = apply {
            puts.remove(key)
            removals.add(key)
        }

        fun commit(): Boolean = commitMutations(puts, removals)

        fun apply() {
            commit()
        }

        private fun put(key: String, value: NativeGeofencePreferenceValue): Editor = apply {
            removals.remove(key)
            puts[key] = value
        }
    }

    private val lock = Object()
    private val backupFile = File(file.parentFile, "${file.name}.bak")
    private val temporaryFile = File(file.parentFile, "${file.name}.tmp")
    private val json = Json {
        encodeDefaults = true
        ignoreUnknownKeys = true
    }

    val all: Map<String, Any>
        get() = synchronized(lock) { loadLocked()?.asMap().orEmpty() }

    fun contains(key: String): Boolean = synchronized(lock) {
        loadLocked()?.keys?.contains(key) == true
    }

    fun getString(key: String, defaultValue: String?): String? = synchronized(lock) {
        loadLocked()?.strings?.get(key) ?: defaultValue
    }

    fun getStringSet(key: String, defaultValue: Set<String>?): Set<String>? =
        synchronized(lock) {
            loadLocked()?.stringSets?.get(key)?.toSet() ?: defaultValue?.toSet()
        }

    fun getLong(key: String, defaultValue: Long): Long = synchronized(lock) {
        loadLocked()?.longs?.get(key) ?: defaultValue
    }

    fun getInt(key: String, defaultValue: Int): Int = synchronized(lock) {
        loadLocked()?.ints?.get(key) ?: defaultValue
    }

    fun getBoolean(key: String, defaultValue: Boolean): Boolean = synchronized(lock) {
        loadLocked()?.booleans?.get(key) ?: defaultValue
    }

    fun edit(): Editor = Editor()

    /** Imports only keys not already committed in no-backup storage. */
    fun importMissing(values: Map<String, *>): Boolean = synchronized(lock) {
        val current = loadLocked() ?: return false
        val puts = values
            .filterKeys { it !in current.keys }
            .mapNotNull { (key, value) ->
                legacyValue(value)?.let { key to it }
            }
            .toMap()
        if (puts.isEmpty()) return true
        writeLocked(applyMutations(current, puts, emptySet()))
    }

    private fun commitMutations(
        puts: Map<String, NativeGeofencePreferenceValue>,
        removals: Set<String>,
    ): Boolean = synchronized(lock) {
        val current = loadLocked() ?: return false
        writeLocked(applyMutations(current, puts, removals))
    }

    private fun applyMutations(
        current: NativeGeofencePreferencesSnapshot,
        puts: Map<String, NativeGeofencePreferenceValue>,
        removals: Set<String>,
    ): NativeGeofencePreferencesSnapshot {
        val strings = current.strings.toMutableMap()
        val stringSets = current.stringSets.toMutableMap()
        val longs = current.longs.toMutableMap()
        val ints = current.ints.toMutableMap()
        val booleans = current.booleans.toMutableMap()

        fun remove(key: String) {
            strings.remove(key)
            stringSets.remove(key)
            longs.remove(key)
            ints.remove(key)
            booleans.remove(key)
        }

        for (key in removals) {
            remove(key)
        }
        for ((key, value) in puts) {
            remove(key)
            when (value) {
                is NativeGeofencePreferenceValue.StringValue -> strings[key] = value.value
                is NativeGeofencePreferenceValue.StringSetValue ->
                    stringSets[key] = value.value.toSet()
                is NativeGeofencePreferenceValue.LongValue -> longs[key] = value.value
                is NativeGeofencePreferenceValue.IntValue -> ints[key] = value.value
                is NativeGeofencePreferenceValue.BooleanValue -> booleans[key] = value.value
            }
        }
        return NativeGeofencePreferencesSnapshot(
            strings = strings,
            stringSets = stringSets,
            longs = longs,
            ints = ints,
            booleans = booleans,
        )
    }

    private fun loadLocked(): NativeGeofencePreferencesSnapshot? {
        if (!recoverBackupLocked()) return null
        if (!file.exists()) return NativeGeofencePreferencesSnapshot()
        return runCatching {
            json.decodeFromString<NativeGeofencePreferencesSnapshot>(file.readText())
        }.getOrNull()
    }

    private fun writeLocked(snapshot: NativeGeofencePreferencesSnapshot): Boolean {
        val directory = file.parentFile ?: return false
        if ((!directory.exists() && !directory.mkdirs()) || !directory.isDirectory) return false
        if (!recoverBackupLocked()) return false
        try {
            FileOutputStream(temporaryFile).use { output ->
                output.write(json.encodeToString(snapshot).toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }
            if (backupFile.exists() && !backupFile.delete()) return false
            if (file.exists() && !file.renameTo(backupFile)) return false
            if (!temporaryFile.renameTo(file)) {
                if (backupFile.exists()) backupFile.renameTo(file)
                return false
            }
            if (backupFile.exists()) backupFile.delete()
            return true
        } catch (_: Exception) {
            if (!file.exists() && backupFile.exists()) backupFile.renameTo(file)
            return false
        } finally {
            if (temporaryFile.exists()) temporaryFile.delete()
        }
    }

    private fun recoverBackupLocked(): Boolean = when {
        !file.exists() && backupFile.exists() -> backupFile.renameTo(file)
        file.exists() && backupFile.exists() -> backupFile.delete()
        else -> true
    }

    private fun legacyValue(value: Any?): NativeGeofencePreferenceValue? = when (value) {
        is String -> NativeGeofencePreferenceValue.StringValue(value)
        is Long -> NativeGeofencePreferenceValue.LongValue(value)
        is Int -> NativeGeofencePreferenceValue.IntValue(value)
        is Boolean -> NativeGeofencePreferenceValue.BooleanValue(value)
        is Set<*> -> value.filterIsInstance<String>()
            .takeIf { it.size == value.size }
            ?.toSet()
            ?.let(NativeGeofencePreferenceValue::StringSetValue)
        else -> null
    }
}

internal enum class LegacyPreferenceMigrationOutcome {
    NOTHING_TO_MIGRATE,
    MIGRATED,
    DISCARDED_RESTORED_BACKUP,
    RETAINED_AFTER_FAILURE,
}

internal fun migrateLegacyNativeGeofencePreferences(
    legacyValues: Map<String, *>,
    packageWasUpdated: Boolean,
    importMissing: (Map<String, *>) -> Boolean,
    clearLegacy: () -> Boolean,
): LegacyPreferenceMigrationOutcome {
    if (legacyValues.isEmpty()) return LegacyPreferenceMigrationOutcome.NOTHING_TO_MIGRATE
    if (packageWasUpdated && !importMissing(legacyValues)) {
        return LegacyPreferenceMigrationOutcome.RETAINED_AFTER_FAILURE
    }
    if (!clearLegacy()) return LegacyPreferenceMigrationOutcome.RETAINED_AFTER_FAILURE
    return if (packageWasUpdated) {
        LegacyPreferenceMigrationOutcome.MIGRATED
    } else {
        LegacyPreferenceMigrationOutcome.DISCARDED_RESTORED_BACKUP
    }
}

internal fun packageWasUpdated(firstInstallTime: Long, lastUpdateTime: Long): Boolean =
    firstInstallTime > 0L && lastUpdateTime > firstInstallTime

/** Process-wide access to the plugin's no-backup preference file. */
internal object NativeGeofencePreferences {
    private val lock = Object()
    private val storesByPath = mutableMapOf<String, NoBackupNativeGeofencePreferences>()

    fun get(context: Context): NoBackupNativeGeofencePreferences {
        val appContext = context.applicationContext
        val file = File(
            File(appContext.noBackupFilesDir, Constants.NO_BACKUP_STATE_DIRECTORY),
            Constants.NO_BACKUP_PREFERENCES_FILE,
        )
        val store = synchronized(lock) {
            storesByPath.getOrPut(file.absolutePath) {
                NoBackupNativeGeofencePreferences(file)
            }
        }
        migrateLegacy(appContext, store)
        return store
    }

    private fun migrateLegacy(
        context: Context,
        store: NoBackupNativeGeofencePreferences,
    ) {
        val legacy = context.getSharedPreferences(
            Constants.SHARED_PREFERENCES_KEY,
            Context.MODE_PRIVATE,
        )
        val legacyValues = legacy.all
        if (legacyValues.isEmpty()) return
        val packageWasUpdated = runCatching {
            @Suppress("DEPRECATION")
            val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
            packageWasUpdated(packageInfo.firstInstallTime, packageInfo.lastUpdateTime)
        }.getOrNull() ?: return
        migrateLegacyNativeGeofencePreferences(
            legacyValues = legacyValues,
            packageWasUpdated = packageWasUpdated,
            importMissing = store::importMissing,
            clearLegacy = { legacy.edit().clear().commit() },
        )
    }
}
