package com.chunkytofustudios.native_geofence.util

import android.content.Context
import android.util.Log
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.model.GeofenceStorage
import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString

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
                context.getSharedPreferences(Constants.SHARED_PREFERENCES_KEY, Context.MODE_PRIVATE)
                    .edit()
                    .putStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, persistentGeofences)
                    .putString(getGeofenceKey(geofence.id), jsonData)
                    .remove(getLastDeliveredGeofenceEventKey(geofence.id))
                    .remove(getLastDeliveredGeofenceEventTimeKey(geofence.id))
                    .apply()
                Log.d(TAG, "Saved Geofence ID=${geofence.id} to storage.")
            }
        }

        @JvmStatic
        fun getAllGeofenceIds(context: Context): List<String> {
            synchronized(sharedPreferencesLock) {
                val p = context.getSharedPreferences(
                    Constants.SHARED_PREFERENCES_KEY,
                    Context.MODE_PRIVATE
                )
                val persistentGeofences =
                    p.getStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, null)
                        ?: return emptyList()
                Log.d(TAG, "There are ${persistentGeofences.size} Geofences saved.")
                return persistentGeofences.toList()
            }
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

                val result = mutableListOf<GeofenceWire>()
                for (id in persistentGeofences) {
                    val jsonData = p.getString(getGeofenceKey(id), null)
                    if (jsonData == null) {
                        Log.e(TAG, "No data found for Geofence ID=${id} in storage.")
                        continue
                    }
                    try {
                        val geofenceStorage = Json.decodeFromString<GeofenceStorage>(jsonData)
                        result.add(geofenceStorage.toWire())
                    } catch (e: Exception) {
                        Log.e(
                            TAG,
                            "Failed to parse Geofence ID=${id} from storage. Data=${jsonData}"
                        )
                    }
                }
                Log.d(TAG, "Retrieved ${result.size} Geofences from storage.")
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
                context.getSharedPreferences(Constants.SHARED_PREFERENCES_KEY, Context.MODE_PRIVATE)
                    .edit()
                    .putStringSet(Constants.PERSISTENT_GEOFENCES_IDS_KEY, persistentGeofences)
                    .remove(getGeofenceKey(geofenceId))
                    .remove(getLastDeliveredGeofenceEventKey(geofenceId))
                    .remove(getLastDeliveredGeofenceEventTimeKey(geofenceId))
                    .apply()
                Log.d(TAG, "Removed Geofence ID=${geofenceId} from storage.")
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
                val editor = context.getSharedPreferences(
                    Constants.SHARED_PREFERENCES_KEY,
                    Context.MODE_PRIVATE
                )
                    .edit()
                    .remove(Constants.PERSISTENT_GEOFENCES_IDS_KEY)
                for (id in persistentGeofences) {
                    editor.remove(getGeofenceKey(id))
                    editor.remove(getLastDeliveredGeofenceEventKey(id))
                    editor.remove(getLastDeliveredGeofenceEventTimeKey(id))
                }
                editor.apply()
                Log.d(TAG, "Removed ${persistentGeofences.size} Geofences from storage.")
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
                context.getSharedPreferences(
                    Constants.SHARED_PREFERENCES_KEY,
                    Context.MODE_PRIVATE
                )
                    .edit()
                    .putString(getLastDeliveredGeofenceEventKey(geofenceId), event.name)
                    .putLong(getLastDeliveredGeofenceEventTimeKey(geofenceId), timestampMillis)
                    .apply()
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
    }
}
