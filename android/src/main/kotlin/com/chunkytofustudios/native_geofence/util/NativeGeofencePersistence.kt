package com.chunkytofustudios.native_geofence.util

import android.content.Context
import android.content.SharedPreferences
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceWire

class NativeGeofencePersistence {
    companion object {
        @JvmStatic
        private val TAG = "NativeGeofencePersistence"

        @JvmStatic
        private val sharedPreferencesLock = Object()

        @JvmStatic
        fun saveGeofence(
            context: Context,
            geofence: GeofenceWire,
            recoveryEligible: Boolean = true,
            active: Boolean = true
        ): Boolean = synchronized(sharedPreferencesLock) {
            val saved = store(context).saveConfiguredGeofence(
                geofence,
                recoveryEligible = recoveryEligible,
                active = active,
                callbackPackageFingerprint = AndroidPackageFingerprint.current(context)
            )
            if (saved) {
                NativeGeofenceLogger.d(context, TAG, "Saved Geofence ID=${geofence.id}.")
            } else {
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Failed to durably persist Geofence ID=${geofence.id}."
                )
            }
            saved
        }

        @JvmStatic
        fun getGeofence(context: Context, id: String): GeofenceWire? =
            synchronized(sharedPreferencesLock) {
                store(context).getConfiguredGeofence(id)?.configuredGeofence
            }

        @JvmStatic
        internal fun getStoredGeofence(
            context: Context,
            id: String,
        ): StoredGeofenceRegistration? = synchronized(sharedPreferencesLock) {
            store(context).getConfiguredGeofence(id)
        }

        @JvmStatic
        fun getRecoverableGeofence(context: Context, id: String): GeofenceWire? =
            synchronized(sharedPreferencesLock) {
                store(context).getRecoverableGeofence(id)
            }

        @JvmStatic
        fun getAllGeofenceIds(context: Context): List<String> =
            synchronized(sharedPreferencesLock) {
                store(context).configuredIds()
            }

        @JvmStatic
        fun getAllRawGeofenceIds(context: Context): List<String> =
            synchronized(sharedPreferencesLock) {
                store(context).rawIds()
            }

        @JvmStatic
        fun getAllGeofences(context: Context): List<GeofenceWire> =
            synchronized(sharedPreferencesLock) {
                store(context).getRecoverableGeofences()
            }

        @JvmStatic
        internal fun getRecoveryInventory(
            context: Context,
        ): List<GeofenceRecoveryInventoryEntry> = synchronized(sharedPreferencesLock) {
            store(context).recoveryInventory()
        }

        @JvmStatic
        internal fun inspectStatusInventory(
            context: Context,
        ): List<GeofenceStatusInventoryEntry> = synchronized(sharedPreferencesLock) {
            store(context).statusInventory()
        }

        @JvmStatic
        fun getAllConfiguredGeofences(context: Context): List<GeofenceWire> =
            synchronized(sharedPreferencesLock) {
                store(context).getConfiguredGeofences().map { it.configuredGeofence }
            }

        @JvmStatic
        internal fun inspectAllStoredConfiguredGeofences(
            context: Context
        ): List<StoredGeofenceRegistration> = synchronized(sharedPreferencesLock) {
            store(context).inspectConfiguredGeofences()
        }

        @JvmStatic
        internal fun prepareGeofenceForSynchronization(
            context: Context,
            geofence: GeofenceWire
        ): PreparedSynchronizedGeofence = synchronized(sharedPreferencesLock) {
            store(context).prepareSynchronizedGeofence(geofence)
        }

        @JvmStatic
        internal fun commitGeofenceForSynchronization(
            context: Context,
            prepared: PreparedSynchronizedGeofence
        ): Boolean = synchronized(sharedPreferencesLock) {
            store(context).commitSynchronizedGeofence(
                prepared,
                AndroidPackageFingerprint.current(context)
            )
        }

        @JvmStatic
        internal fun updateCallbackMetadata(
            context: Context,
            geofence: GeofenceWire
        ): Boolean = synchronized(sharedPreferencesLock) {
            store(context).updateCallbackMetadata(
                geofence.id,
                geofence.callbackHandle,
                geofence.callbackContext,
                AndroidPackageFingerprint.current(context)
            )
        }

        @JvmStatic
        fun getSynchronizationFingerprint(context: Context): String? =
            synchronized(sharedPreferencesLock) {
                store(context).synchronizationFingerprint()
            }

        @JvmStatic
        internal fun commitSynchronization(
            context: Context,
            fingerprint: String
        ): Boolean = synchronized(sharedPreferencesLock) {
            store(context).commitSynchronization(fingerprint)
        }

        @JvmStatic
        fun restoreSynchronizationFingerprint(
            context: Context,
            fingerprint: String?
        ): Boolean = synchronized(sharedPreferencesLock) {
            store(context).restoreSynchronizationFingerprint(fingerprint)
        }

        @JvmStatic
        fun getCallbackPackageFingerprint(context: Context, id: String): String? =
            synchronized(sharedPreferencesLock) {
                store(context).callbackPackageFingerprint(id)
            }

        @JvmStatic
        fun isCallbackPackageCurrent(context: Context, id: String): Boolean =
            synchronized(sharedPreferencesLock) {
                val recorded = store(context).callbackPackageFingerprint(id)
                    ?: return@synchronized true
                recorded == AndroidPackageFingerprint.current(context)
            }

        @JvmStatic
        fun isCallbackRefreshRequired(context: Context): Boolean =
            synchronized(sharedPreferencesLock) {
                store(context).isCallbackRefreshRequired()
            }

        @JvmStatic
        fun markCallbackRefreshRequired(context: Context): Boolean =
            synchronized(sharedPreferencesLock) {
                store(context).markCallbackRefreshRequired()
            }

        @JvmStatic
        internal fun snapshot(
            context: Context,
            id: String
        ): GeofencePersistenceSnapshot = synchronized(sharedPreferencesLock) {
            store(context).snapshot(id)
        }

        @JvmStatic
        internal fun restore(
            context: Context,
            snapshot: GeofencePersistenceSnapshot
        ): Boolean = synchronized(sharedPreferencesLock) {
            val restored = store(context).restore(snapshot)
            if (!restored) {
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Failed to restore the persisted Geofence ID=${snapshot.id}."
                )
            }
            restored
        }

        @JvmStatic
        fun setLifecycleState(
            context: Context,
            id: String,
            recoveryEligible: Boolean,
            active: Boolean
        ): Boolean = synchronized(sharedPreferencesLock) {
            store(context).setLifecycleState(id, recoveryEligible, active)
        }

        @JvmStatic
        fun markGeofenceForPlatformCleanup(context: Context, id: String): Boolean =
            synchronized(sharedPreferencesLock) {
                store(context).markForPlatformCleanup(id)
            }

        @JvmStatic
        fun markGeofenceForRecovery(context: Context, id: String): Boolean =
            synchronized(sharedPreferencesLock) {
                store(context).markForRecovery(id)
            }

        /** Call only after Play services confirms cleanup for [geofenceId]. */
        @JvmStatic
        fun removeGeofence(context: Context, geofenceId: String): Boolean =
            synchronized(sharedPreferencesLock) {
                val removed = store(context).removeAfterPlatformCleanup(geofenceId)
                if (removed) {
                    NativeGeofenceLogger.d(context, TAG, "Removed Geofence ID=$geofenceId.")
                } else {
                    NativeGeofenceLogger.e(
                        context,
                        TAG,
                        "Failed to remove Geofence ID=$geofenceId from durable storage."
                    )
                }
                removed
            }

        /** Call only after Play services confirms cleanup for all plugin-owned IDs. */
        @JvmStatic
        fun removeAllGeofences(context: Context): Boolean = synchronized(sharedPreferencesLock) {
            val rawCount = store(context).rawIds().size
            val removed = store(context).removeAllAfterPlatformCleanup()
            if (removed) {
                NativeGeofenceLogger.d(context, TAG, "Removed $rawCount Geofences.")
            } else {
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Failed to remove all Geofences from durable storage."
                )
            }
            removed
        }

        private fun store(context: Context): GeofenceRegistrationStore =
            GeofenceRegistrationStore(
                SharedPreferencesGeofencePersistenceBackend(
                    context.getSharedPreferences(
                        Constants.SHARED_PREFERENCES_KEY,
                        Context.MODE_PRIVATE
                    )
                )
            )
    }
}

private class SharedPreferencesGeofencePersistenceBackend(
    private val preferences: SharedPreferences
) : GeofencePersistenceBackend {
    override fun keys(): Set<String> = preferences.all.keys

    override fun contains(key: String): Boolean = preferences.contains(key)

    override fun getString(key: String): String? = preferences.getString(key, null)

    override fun getStringSet(key: String): Set<String>? =
        preferences.getStringSet(key, null)?.toSet()

    override fun getLong(key: String, defaultValue: Long): Long =
        preferences.getLong(key, defaultValue)

    override fun getBoolean(key: String, defaultValue: Boolean): Boolean =
        preferences.getBoolean(key, defaultValue)

    override fun edit(block: GeofencePersistenceEditor.() -> Unit): Boolean {
        val editor = preferences.edit()
        SharedPreferencesGeofencePersistenceEditor(editor).block()
        return editor.commit()
    }
}

private class SharedPreferencesGeofencePersistenceEditor(
    private val editor: SharedPreferences.Editor
) : GeofencePersistenceEditor {
    override fun putString(key: String, value: String) {
        editor.putString(key, value)
    }

    override fun putStringSet(key: String, value: Set<String>) {
        editor.putStringSet(key, value.toSet())
    }

    override fun putLong(key: String, value: Long) {
        editor.putLong(key, value)
    }

    override fun putBoolean(key: String, value: Boolean) {
        editor.putBoolean(key, value)
    }

    override fun remove(key: String) {
        editor.remove(key)
    }
}
