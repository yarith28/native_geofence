package com.chunkytofustudios.native_geofence.util

import android.Manifest
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceStatusWire
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability

object NativeGeofenceDiagnostics {
    private const val TAG = "NativeGeofenceDiagnostics"

    private const val LAST_REGISTER_ATTEMPT_AT = "diagnostic_last_register_attempt_at"
    private const val LAST_REGISTER_SUCCESS_AT = "diagnostic_last_register_success_at"
    private const val LAST_REGISTER_FAILURE_AT = "diagnostic_last_register_failure_at"
    private const val LAST_REGISTER_GEOFENCE_ID = "diagnostic_last_register_geofence_id"
    private const val LAST_REGISTER_FAILURE_CODE = "diagnostic_last_register_failure_code"
    private const val LAST_REGISTER_FAILURE_MESSAGE = "diagnostic_last_register_failure_message"

    private const val LAST_REMOVE_ATTEMPT_AT = "diagnostic_last_remove_attempt_at"
    private const val LAST_REMOVE_SUCCESS_AT = "diagnostic_last_remove_success_at"
    private const val LAST_REMOVE_FAILURE_AT = "diagnostic_last_remove_failure_at"
    private const val LAST_REMOVE_GEOFENCE_IDS = "diagnostic_last_remove_geofence_ids"
    private const val LAST_REMOVE_FAILURE_MESSAGE = "diagnostic_last_remove_failure_message"

    private const val LAST_BROADCAST_RECEIVED_AT = "diagnostic_last_broadcast_received_at"
    private const val LAST_BROADCAST_EVENT = "diagnostic_last_broadcast_event"
    private const val LAST_BROADCAST_GEOFENCE_IDS = "diagnostic_last_broadcast_geofence_ids"
    private const val LAST_BROADCAST_ERROR_CODE = "diagnostic_last_broadcast_error_code"
    private const val LAST_BROADCAST_ERROR_MESSAGE = "diagnostic_last_broadcast_error_message"

    private const val LAST_CALLBACK_ENQUEUE_AT = "diagnostic_last_callback_enqueue_at"
    private const val LAST_CALLBACK_ENQUEUE_FAILURE_AT =
        "diagnostic_last_callback_enqueue_failure_at"
    private const val LAST_CALLBACK_ENQUEUE_FAILURE_MESSAGE =
        "diagnostic_last_callback_enqueue_failure_message"

    fun recordRegisterAttempt(context: Context, geofenceId: String) {
        persist(
            "register_attempt",
            preferences(context).edit()
                .putLong(LAST_REGISTER_ATTEMPT_AT, System.currentTimeMillis())
                .putString(LAST_REGISTER_GEOFENCE_ID, geofenceId)
        )
    }

    fun recordRegisterSuccess(context: Context, geofenceId: String) {
        persist(
            "register_success",
            preferences(context).edit()
                .putLong(LAST_REGISTER_SUCCESS_AT, System.currentTimeMillis())
                .putString(LAST_REGISTER_GEOFENCE_ID, geofenceId)
                .remove(LAST_REGISTER_FAILURE_CODE)
                .remove(LAST_REGISTER_FAILURE_MESSAGE)
        )
    }

    fun recordRegisterFailure(
        context: Context,
        geofenceId: String,
        code: String?,
        message: String?
    ) {
        persist(
            "register_failure",
            preferences(context).edit()
                .putLong(LAST_REGISTER_FAILURE_AT, System.currentTimeMillis())
                .putString(LAST_REGISTER_GEOFENCE_ID, geofenceId)
                .putNullableString(LAST_REGISTER_FAILURE_CODE, code)
                .putNullableString(LAST_REGISTER_FAILURE_MESSAGE, message)
        )
    }

    fun recordRemoveAttempt(context: Context, geofenceIds: List<String>) {
        persist(
            "remove_attempt",
            preferences(context).edit()
                .putLong(LAST_REMOVE_ATTEMPT_AT, System.currentTimeMillis())
                .putStringSet(LAST_REMOVE_GEOFENCE_IDS, geofenceIds.toSet())
        )
    }

    fun recordRemoveSuccess(context: Context, geofenceIds: List<String>) {
        persist(
            "remove_success",
            preferences(context).edit()
                .putLong(LAST_REMOVE_SUCCESS_AT, System.currentTimeMillis())
                .putStringSet(LAST_REMOVE_GEOFENCE_IDS, geofenceIds.toSet())
                .remove(LAST_REMOVE_FAILURE_MESSAGE)
        )
    }

    fun recordRemoveFailure(context: Context, geofenceIds: List<String>, message: String?) {
        persist(
            "remove_failure",
            preferences(context).edit()
                .putLong(LAST_REMOVE_FAILURE_AT, System.currentTimeMillis())
                .putStringSet(LAST_REMOVE_GEOFENCE_IDS, geofenceIds.toSet())
                .putNullableString(LAST_REMOVE_FAILURE_MESSAGE, message)
        )
    }

    fun recordBroadcastReceived(context: Context) {
        persist(
            "broadcast_received",
            preferences(context).edit()
                .putLong(LAST_BROADCAST_RECEIVED_AT, System.currentTimeMillis())
        )
    }

    fun recordBroadcastEvent(
        context: Context,
        event: GeofenceEvent,
        geofenceIds: List<String>
    ) {
        persist(
            "broadcast_event",
            preferences(context).edit()
                .putString(LAST_BROADCAST_EVENT, event.name)
                .putStringSet(LAST_BROADCAST_GEOFENCE_IDS, geofenceIds.toSet())
                .remove(LAST_BROADCAST_ERROR_CODE)
                .remove(LAST_BROADCAST_ERROR_MESSAGE)
        )
    }

    fun recordBroadcastError(context: Context, code: String, message: String?) {
        persist(
            "broadcast_error",
            preferences(context).edit()
                .putString(LAST_BROADCAST_ERROR_CODE, code)
                .putNullableString(LAST_BROADCAST_ERROR_MESSAGE, message)
        )
    }

    fun recordCallbackEnqueueAttempt(
        context: Context,
        event: GeofenceEvent,
        geofenceIds: List<String>
    ) {
        persist(
            "callback_enqueue_attempt",
            preferences(context).edit()
                .putLong(LAST_CALLBACK_ENQUEUE_AT, System.currentTimeMillis())
                .putString(LAST_BROADCAST_EVENT, event.name)
                .putStringSet(LAST_BROADCAST_GEOFENCE_IDS, geofenceIds.toSet())
        )
    }

    fun recordCallbackEnqueueFailure(
        context: Context,
        event: GeofenceEvent?,
        geofenceIds: List<String>,
        message: String?
    ) {
        val editor = preferences(context).edit()
            .putLong(LAST_CALLBACK_ENQUEUE_FAILURE_AT, System.currentTimeMillis())
            .putNullableString(LAST_CALLBACK_ENQUEUE_FAILURE_MESSAGE, message)
            .putStringSet(LAST_BROADCAST_GEOFENCE_IDS, geofenceIds.toSet())
        event?.let { editor.putString(LAST_BROADCAST_EVENT, it.name) }
        persist("callback_enqueue_failure", editor)
    }

    fun getStatus(
        context: Context,
        geofencePendingIntentExists: Boolean?
    ): NativeGeofenceStatusWire {
        val playServicesCode =
            GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context)
        return NativeGeofenceStatusWire(
            platform = "android",
            androidSdkInt = Build.VERSION.SDK_INT.toLong(),
            deviceManufacturer = Build.MANUFACTURER,
            deviceModel = Build.MODEL,
            persistedGeofenceIds = NativeGeofencePersistence.getAllGeofenceIds(context).sorted(),
            locationPermissionGranted = hasFineLocationPermission(context),
            backgroundLocationPermissionGranted = hasBackgroundLocationPermission(context),
            notificationPermissionGranted = hasNotificationPermission(context),
            locationAuthorizationStatus = null,
            locationServicesEnabled = isLocationEnabled(context),
            batteryOptimizationsIgnored = isIgnoringBatteryOptimizations(context),
            googlePlayServicesAvailable = playServicesCode == ConnectionResult.SUCCESS,
            googlePlayServicesAvailabilityCode = playServicesCode.toLong(),
            geofencePendingIntentExists = geofencePendingIntentExists,
            lastRegisterAttemptAtMillis = readLong(context, LAST_REGISTER_ATTEMPT_AT),
            lastRegisterSuccessAtMillis = readLong(context, LAST_REGISTER_SUCCESS_AT),
            lastRegisterFailureAtMillis = readLong(context, LAST_REGISTER_FAILURE_AT),
            lastRegisterGeofenceId = readString(context, LAST_REGISTER_GEOFENCE_ID),
            lastRegisterFailureCode = readString(context, LAST_REGISTER_FAILURE_CODE),
            lastRegisterFailureMessage = readString(context, LAST_REGISTER_FAILURE_MESSAGE),
            lastRemoveAttemptAtMillis = readLong(context, LAST_REMOVE_ATTEMPT_AT),
            lastRemoveSuccessAtMillis = readLong(context, LAST_REMOVE_SUCCESS_AT),
            lastRemoveFailureAtMillis = readLong(context, LAST_REMOVE_FAILURE_AT),
            lastRemoveGeofenceIds = readStringList(context, LAST_REMOVE_GEOFENCE_IDS),
            lastRemoveFailureMessage = readString(context, LAST_REMOVE_FAILURE_MESSAGE),
            lastBroadcastReceivedAtMillis = readLong(context, LAST_BROADCAST_RECEIVED_AT),
            lastBroadcastEvent = readString(context, LAST_BROADCAST_EVENT),
            lastBroadcastGeofenceIds = readStringList(context, LAST_BROADCAST_GEOFENCE_IDS),
            lastBroadcastErrorCode = readString(context, LAST_BROADCAST_ERROR_CODE),
            lastBroadcastErrorMessage = readString(context, LAST_BROADCAST_ERROR_MESSAGE),
            lastCallbackEnqueueAtMillis = readLong(context, LAST_CALLBACK_ENQUEUE_AT),
            lastCallbackEnqueueFailureAtMillis =
                readLong(context, LAST_CALLBACK_ENQUEUE_FAILURE_AT),
            lastCallbackEnqueueFailureMessage =
                readString(context, LAST_CALLBACK_ENQUEUE_FAILURE_MESSAGE)
        )
    }

    private fun preferences(context: Context): SharedPreferences {
        return context.getSharedPreferences(Constants.SHARED_PREFERENCES_KEY, Context.MODE_PRIVATE)
    }

    private fun persist(label: String, editor: SharedPreferences.Editor) {
        if (!editor.commit()) {
            Log.e(TAG, "Failed to persist diagnostic event=$label.")
        }
        Log.d(TAG, "Recorded diagnostic event=$label.")
    }

    private fun SharedPreferences.Editor.putNullableString(
        key: String,
        value: String?
    ): SharedPreferences.Editor {
        return if (value == null) remove(key) else putString(key, value)
    }

    private fun readLong(context: Context, key: String): Long? {
        val p = preferences(context)
        return if (p.contains(key)) p.getLong(key, 0L) else null
    }

    private fun readString(context: Context, key: String): String? {
        return preferences(context).getString(key, null)
    }

    private fun readStringList(context: Context, key: String): List<String> {
        return preferences(context).getStringSet(key, emptySet())?.toList()?.sorted() ?: emptyList()
    }

    private fun hasFineLocationPermission(context: Context): Boolean {
        return ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun hasBackgroundLocationPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return true
        }
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_BACKGROUND_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasNotificationPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun isLocationEnabled(context: Context): Boolean? {
        val locationManager =
            context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                locationManager.isLocationEnabled
            } else {
                locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read location enabled state.", e)
            null
        }
    }

    private fun isIgnoringBatteryOptimizations(context: Context): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        val powerManager =
            context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return null
        return powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }
}
