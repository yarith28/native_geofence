package com.chunkytofustudios.native_geofence.util

import android.content.Context
import android.content.SharedPreferences
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.model.GeofenceStorage
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class NativeGeofencePersistence {
    companion object {
        @JvmStatic
        private val TAG = "NativeGeofencePersistence"

        @JvmStatic
        private val sharedPreferencesLock = Object()

        @JvmStatic
        private fun getGeofenceKey(id: String): String {
            return Constants.PERSISTENT_GEOFENCE_KEY_PREFIX + id
        }

        @JvmStatic
        private fun getGeofenceExpirationKey(id: String): String {
            return Constants.PERSISTENT_GEOFENCE_EXPIRATION_KEY_PREFIX + id
        }

        @JvmStatic
        private fun getLastDeliveredGeofenceEventKey(id: String): String {
            return Constants.LAST_DELIVERED_GEOFENCE_EVENT_KEY_PREFIX + id
        }

        @JvmStatic
        private fun getLastDeliveredGeofenceEventTimeKey(id: String): String {
            return Constants.LAST_DELIVERED_GEOFENCE_EVENT_TIME_KEY_PREFIX + id
        }

        @JvmStatic
        fun saveGeofence(context: Context, geofence: GeofenceWire) {
            synchronized(sharedPreferencesLock) {
                val p = context.getSharedPreferences(
                    Constants.SHARED_PREFERENCES_KEY,
                    Context.MODE_PRIVATE
                )
                val jsonData = Json.encodeToString(GeofenceStorage.fromWire(geofence))
                var persistentGeofences =
                    p.getStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, null)
                persistentGeofences = if (persistentGeofences == null) {
                    HashSet<String>()
                } else {
                    HashSet<String>(persistentGeofences)
                }
                persistentGeofences.add(geofence.id)
                val editor = p.edit()
                    .putStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, persistentGeofences)
                    .putString(getGeofenceKey(geofence.id), jsonData)
                    .remove(getLastDeliveredGeofenceEventKey(geofence.id))
                    .remove(getLastDeliveredGeofenceEventTimeKey(geofence.id))

                val expirationDuration = geofence.androidSettings.expirationDurationMillis
                // Persist a deadline, not the original duration, so reboot recovery
                // can restore only the remaining lifetime.
                if (expirationDuration == null) {
                    editor.remove(getGeofenceExpirationKey(geofence.id))
                } else {
                    editor.putLong(
                        getGeofenceExpirationKey(geofence.id),
                        System.currentTimeMillis() + expirationDuration
                    )
                }
                // Geofence storage is lifecycle-critical; wait for it to reach disk.
                if (!editor.commit()) {
                    NativeGeofenceLogger.e(context, TAG, "Failed to persist Geofence ID=${geofence.id}.")
                }
                NativeGeofenceLogger.d(context, TAG, "Saved Geofence ID=${geofence.id} to storage.")
            }
        }

        @JvmStatic
        fun getGeofence(context: Context, id: String): GeofenceWire? {
            synchronized(sharedPreferencesLock) {
                val p = context.getSharedPreferences(
                    Constants.SHARED_PREFERENCES_KEY,
                    Context.MODE_PRIVATE
                )
                return getGeofenceLocked(context, p, id)
            }
        }

        @JvmStatic
        fun getAllGeofenceIds(context: Context): List<String> {
            return getAllGeofences(context).map { it.id }
        }

        @JvmStatic
        fun getAllGeofences(context: Context): List<GeofenceWire> {
            synchronized(sharedPreferencesLock) {
                val p = context.getSharedPreferences(
                    Constants.SHARED_PREFERENCES_KEY,
                    Context.MODE_PRIVATE
                )
                val persistentGeofences =
                    p.getStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, null)
                        ?: return emptyList()

                // Loading also cleans stale/corrupt/expired entries so callers see
                // the best approximation of currently recoverable geofences.
                val result = mutableListOf<GeofenceWire>()
                for (id in persistentGeofences) {
                    getGeofenceLocked(context, p, id)?.let { result.add(it) }
                }
                NativeGeofenceLogger.d(context, TAG, "Retrieved ${result.size} Geofences from storage.")
                return result
            }
        }

        @JvmStatic
        fun removeGeofence(context: Context, geofenceId: String) {
            synchronized(sharedPreferencesLock) {
                val p = context.getSharedPreferences(
                    Constants.SHARED_PREFERENCES_KEY,
                    Context.MODE_PRIVATE
                )
                var persistentGeofences =
                    p.getStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, null)
                persistentGeofences = if (persistentGeofences == null) {
                    HashSet<String>()
                } else {
                    HashSet<String>(persistentGeofences)
                }
                persistentGeofences.remove(geofenceId)
                val editor = p.edit()
                    .putStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, persistentGeofences)
                    .remove(getGeofenceKey(geofenceId))
                    .remove(getGeofenceExpirationKey(geofenceId))
                    .remove(getLastDeliveredGeofenceEventKey(geofenceId))
                    .remove(getLastDeliveredGeofenceEventTimeKey(geofenceId))

                if (!editor.commit()) {
                    NativeGeofenceLogger.e(context, TAG, "Failed to remove Geofence ID=${geofenceId} from storage.")
                }
                NativeGeofenceLogger.d(context, TAG, "Removed Geofence ID=${geofenceId} from storage.")
            }
        }

        @JvmStatic
        fun removeAllGeofences(context: Context) {
            synchronized(sharedPreferencesLock) {
                val p = context.getSharedPreferences(
                    Constants.SHARED_PREFERENCES_KEY,
                    Context.MODE_PRIVATE
                )
                var persistentGeofences =
                    p.getStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, null)
                persistentGeofences = if (persistentGeofences == null) {
                    HashSet<String>()
                } else {
                    HashSet<String>(persistentGeofences)
                }
                val editor = p.edit()
                    .remove(Constants.PERSISTENT_GEOFENCES_IDS_KEY)
                for (id in persistentGeofences) {
                    editor.remove(getGeofenceKey(id))
                    editor.remove(getGeofenceExpirationKey(id))
                    editor.remove(getLastDeliveredGeofenceEventKey(id))
                    editor.remove(getLastDeliveredGeofenceEventTimeKey(id))
                }
                if (!editor.commit()) {
                    NativeGeofenceLogger.e(context, TAG, "Failed to remove all Geofences from storage.")
                }
                NativeGeofenceLogger.d(context, TAG, "Removed ${persistentGeofences.size} Geofences from storage.")
            }
        }

        @JvmStatic
        fun recordDeliveredGeofenceEvent(
            context: Context,
            geofenceId: String,
            event: GeofenceEvent,
            timestampMillis: Long = System.currentTimeMillis()
        ) {
            synchronized(sharedPreferencesLock) {
                val editor = context.getSharedPreferences(
                    Constants.SHARED_PREFERENCES_KEY,
                    Context.MODE_PRIVATE
                )
                    .edit()
                    .putString(getLastDeliveredGeofenceEventKey(geofenceId), event.name)
                    .putLong(getLastDeliveredGeofenceEventTimeKey(geofenceId), timestampMillis)
                if (!editor.commit()) {
                    NativeGeofenceLogger.e(context, TAG, "Failed to record delivered state for Geofence ID=${geofenceId}.")
                }
            }
        }

        @JvmStatic
        fun wasSameGeofenceTransitionStateDelivered(
            context: Context,
            geofenceId: String,
            event: GeofenceEvent
        ): Boolean {
            if (event == GeofenceEvent.DWELL) {
                return false
            }
            synchronized(sharedPreferencesLock) {
                val p = context.getSharedPreferences(
                    Constants.SHARED_PREFERENCES_KEY,
                    Context.MODE_PRIVATE
                )
                val lastEventName = p.getString(getLastDeliveredGeofenceEventKey(geofenceId), null)
                    ?: return false
                val lastEvent = try {
                    GeofenceEvent.valueOf(lastEventName)
                } catch (e: IllegalArgumentException) {
                    return false
                }
                val lastInside = when (lastEvent) {
                    GeofenceEvent.ENTER -> true
                    GeofenceEvent.DWELL -> true
                    GeofenceEvent.EXIT -> false
                }
                val currentInside = when (event) {
                    GeofenceEvent.ENTER -> true
                    GeofenceEvent.DWELL -> true
                    GeofenceEvent.EXIT -> false
                }
                return lastInside == currentInside
            }
        }

        @JvmStatic
        private fun getGeofenceLocked(
            context: Context,
            p: SharedPreferences,
            id: String
        ): GeofenceWire? {
            val jsonData = p.getString(getGeofenceKey(id), null)
            if (jsonData == null) {
                NativeGeofenceLogger.e(context, TAG, "No data found for Geofence ID=${id} in storage.")
                removeGeofence(context, id)
                return null
            }
            val geofence = try {
                Json.decodeFromString<GeofenceStorage>(jsonData).toWire()
            } catch (e: Exception) {
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Failed to parse Geofence ID=${id} from storage. Data=${jsonData}",
                    e
                )
                removeGeofence(context, id)
                return null
            }

            if (!p.contains(getGeofenceExpirationKey(id))) {
                return geofence
            }

            // Recreate with remaining time only; never grant a fresh full duration.
            val remainingMillis = p.getLong(getGeofenceExpirationKey(id), 0) - System.currentTimeMillis()
            if (remainingMillis <= 0) {
                NativeGeofenceLogger.d(context, TAG, "Geofence ID=${id} expired; removing it from storage.")
                removeGeofence(context, id)
                return null
            }

            return geofence.copy(
                androidSettings = geofence.androidSettings.copy(
                    expirationDurationMillis = remainingMillis
                )
            )
        }
    }
}
