package com.chunkytofustudios.native_geofence.util

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NativeGeofencePreferencesTest {
    @Test
    fun `typed state survives a new no-backup store instance`() = withTemporaryDirectory { root ->
        val file = root.resolve("native_geofence/preferences.json")
        val first = NoBackupNativeGeofencePreferences(file)

        assertTrue(
            first.edit()
                .putString("string", "value")
                .putStringSet("set", setOf("a", "b"))
                .putLong("long", 42L)
                .putInt("int", 7)
                .putBoolean("boolean", true)
                .commit()
        )

        val restored = NoBackupNativeGeofencePreferences(file)
        assertEquals("value", restored.getString("string", null))
        assertEquals(setOf("a", "b"), restored.getStringSet("set", null))
        assertEquals(42L, restored.getLong("long", 0L))
        assertEquals(7, restored.getInt("int", 0))
        assertTrue(restored.getBoolean("boolean", false))
        assertEquals(setOf("string", "set", "long", "int", "boolean"), restored.all.keys)
    }

    @Test
    fun `edits replace types and remove state atomically`() = withTemporaryDirectory { root ->
        val file = root.resolve("preferences.json")
        val preferences = NoBackupNativeGeofencePreferences(file)
        assertTrue(preferences.edit().putLong("key", 42L).commit())
        assertTrue(
            preferences.edit()
                .putString("key", "replacement")
                .putBoolean("removed", true)
                .commit()
        )
        assertTrue(preferences.edit().remove("removed").commit())

        assertEquals("replacement", preferences.getString("key", null))
        assertEquals(0L, preferences.getLong("key", 0L))
        assertFalse(preferences.contains("removed"))
    }

    @Test
    fun `corrupt state fails closed without overwriting evidence`() = withTemporaryDirectory { root ->
        val file = root.resolve("preferences.json")
        file.writeText("not-json")
        val preferences = NoBackupNativeGeofencePreferences(file)

        assertNull(preferences.getString("key", null))
        assertFalse(preferences.edit().putString("key", "value").commit())
        assertEquals("not-json", file.readText())
    }

    @Test
    fun `interrupted replacement restores the previous complete snapshot`() =
        withTemporaryDirectory { root ->
            val file = root.resolve("preferences.json")
            val preferences = NoBackupNativeGeofencePreferences(file)
            assertTrue(preferences.edit().putLong("generation", 9L).commit())
            val backup = root.resolve("preferences.json.bak")
            assertTrue(file.renameTo(backup))

            val restored = NoBackupNativeGeofencePreferences(file)

            assertEquals(9L, restored.getLong("generation", 0L))
            assertTrue(file.exists())
            assertFalse(backup.exists())
        }

    @Test
    fun `same-device update migrates legacy state then clears backed-up bytes`() {
        val events = mutableListOf<String>()
        val legacy = mapOf<String, Any>("registration" to "json")

        val outcome = migrateLegacyNativeGeofencePreferences(
            legacyValues = legacy,
            packageWasUpdated = true,
            importMissing = {
                assertEquals(legacy, it)
                events += "import"
                true
            },
            clearLegacy = {
                events += "clear"
                true
            },
        )

        assertEquals(LegacyPreferenceMigrationOutcome.MIGRATED, outcome)
        assertEquals(listOf("import", "clear"), events)
    }

    @Test
    fun `fresh install discards restored device state instead of rearming it`() {
        var imported = false
        var cleared = false

        val outcome = migrateLegacyNativeGeofencePreferences(
            legacyValues = mapOf("registration" to "json"),
            packageWasUpdated = false,
            importMissing = {
                imported = true
                true
            },
            clearLegacy = {
                cleared = true
                true
            },
        )

        assertEquals(LegacyPreferenceMigrationOutcome.DISCARDED_RESTORED_BACKUP, outcome)
        assertFalse(imported)
        assertTrue(cleared)
    }

    @Test
    fun `failed same-device import retains legacy state for a later retry`() {
        var cleared = false

        val outcome = migrateLegacyNativeGeofencePreferences(
            legacyValues = mapOf("registration" to "json"),
            packageWasUpdated = true,
            importMissing = { false },
            clearLegacy = {
                cleared = true
                true
            },
        )

        assertEquals(LegacyPreferenceMigrationOutcome.RETAINED_AFTER_FAILURE, outcome)
        assertFalse(cleared)
    }

    @Test
    fun `package update detection excludes first install and reinstall`() {
        assertFalse(packageWasUpdated(firstInstallTime = 0L, lastUpdateTime = 2L))
        assertFalse(packageWasUpdated(firstInstallTime = 2L, lastUpdateTime = 2L))
        assertTrue(packageWasUpdated(firstInstallTime = 2L, lastUpdateTime = 3L))
    }

    private fun withTemporaryDirectory(block: (java.io.File) -> Unit) {
        val directory = Files.createTempDirectory("native-geofence-preferences").toFile()
        try {
            block(directory)
        } finally {
            directory.deleteRecursively()
        }
    }
}
