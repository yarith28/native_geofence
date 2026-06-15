package com.chunkytofustudios.native_geofence.util

import android.Manifest
import android.app.ActivityManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.PowerManager
import androidx.core.content.ContextCompat
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
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
    private const val LAST_BROADCAST_LOCATION_LATITUDE =
        "diagnostic_last_broadcast_location_latitude"
    private const val LAST_BROADCAST_LOCATION_LONGITUDE =
        "diagnostic_last_broadcast_location_longitude"
    private const val LAST_BROADCAST_NEAREST_GEOFENCE_ID =
        "diagnostic_last_broadcast_nearest_geofence_id"
    private const val LAST_BROADCAST_DISTANCE_FROM_NEAREST_GEOFENCE =
        "diagnostic_last_broadcast_distance_from_nearest_geofence"
    private const val LAST_BROADCAST_NEAREST_GEOFENCE_RADIUS =
        "diagnostic_last_broadcast_nearest_geofence_radius"
    private const val LAST_BROADCAST_ERROR_CODE = "diagnostic_last_broadcast_error_code"
    private const val LAST_BROADCAST_ERROR_MESSAGE = "diagnostic_last_broadcast_error_message"

    private const val LAST_CALLBACK_ENQUEUE_AT = "diagnostic_last_callback_enqueue_at"
    private const val LAST_CALLBACK_ENQUEUE_FAILURE_AT =
        "diagnostic_last_callback_enqueue_failure_at"
    private const val LAST_CALLBACK_ENQUEUE_FAILURE_MESSAGE =
        "diagnostic_last_callback_enqueue_failure_message"

    private const val LAST_CALLBACK_WORKER_START_AT = "diagnostic_last_callback_worker_start_at"
    private const val LAST_CALLBACK_WORKER_API_READY_AT =
        "diagnostic_last_callback_worker_api_ready_at"
    private const val LAST_CALLBACK_WORKER_FINISH_AT = "diagnostic_last_callback_worker_finish_at"
    private const val LAST_CALLBACK_WORKER_FAILURE_AT =
        "diagnostic_last_callback_worker_failure_at"
    private const val LAST_CALLBACK_WORKER_RESULT = "diagnostic_last_callback_worker_result"
    private const val LAST_CALLBACK_WORKER_FAILURE_CODE =
        "diagnostic_last_callback_worker_failure_code"
    private const val LAST_CALLBACK_WORKER_FAILURE_MESSAGE =
        "diagnostic_last_callback_worker_failure_message"
    private const val LAST_CALLBACK_WORKER_RUN_ATTEMPT =
        "diagnostic_last_callback_worker_run_attempt"
    private const val LAST_CALLBACK_WORKER_EVENT = "diagnostic_last_callback_worker_event"
    private const val LAST_CALLBACK_WORKER_GEOFENCE_IDS =
        "diagnostic_last_callback_worker_geofence_ids"

    private const val LAST_RECREATE_ATTEMPT_AT = "diagnostic_last_recreate_attempt_at"
    private const val LAST_RECREATE_SUCCESS_AT = "diagnostic_last_recreate_success_at"
    private const val LAST_RECREATE_FAILURE_AT = "diagnostic_last_recreate_failure_at"
    private const val LAST_RECREATE_GEOFENCE_COUNT = "diagnostic_last_recreate_geofence_count"
    private const val LAST_RECREATE_REASON = "diagnostic_last_recreate_reason"
    private const val LAST_RECREATE_FAILURE_MESSAGE = "diagnostic_last_recreate_failure_message"

    fun recordRegisterAttempt(context: Context, geofenceId: String) {
        persist(
            context,
            "register_attempt",
            preferences(context).edit()
                .putLong(LAST_REGISTER_ATTEMPT_AT, System.currentTimeMillis())
                .putString(LAST_REGISTER_GEOFENCE_ID, geofenceId)
        )
    }

    fun recordRegisterSuccess(context: Context, geofenceId: String) {
        persist(
            context,
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
            context,
            "register_failure",
            preferences(context).edit()
                .putLong(LAST_REGISTER_FAILURE_AT, System.currentTimeMillis())
                .putString(LAST_REGISTER_GEOFENCE_ID, geofenceId)
                .putNullableString(LAST_REGISTER_FAILURE_CODE, code)
                .putNullableString(LAST_REGISTER_FAILURE_MESSAGE, message),
            detail = "id=$geofenceId, code=$code, message=$message"
        )
    }

    fun recordRemoveAttempt(context: Context, geofenceIds: List<String>) {
        persist(
            context,
            "remove_attempt",
            preferences(context).edit()
                .putLong(LAST_REMOVE_ATTEMPT_AT, System.currentTimeMillis())
                .putStringSet(LAST_REMOVE_GEOFENCE_IDS, geofenceIds.toSet())
        )
    }

    fun recordRemoveSuccess(context: Context, geofenceIds: List<String>) {
        persist(
            context,
            "remove_success",
            preferences(context).edit()
                .putLong(LAST_REMOVE_SUCCESS_AT, System.currentTimeMillis())
                .putStringSet(LAST_REMOVE_GEOFENCE_IDS, geofenceIds.toSet())
                .remove(LAST_REMOVE_FAILURE_MESSAGE)
        )
    }

    fun recordRemoveFailure(context: Context, geofenceIds: List<String>, message: String?) {
        persist(
            context,
            "remove_failure",
            preferences(context).edit()
                .putLong(LAST_REMOVE_FAILURE_AT, System.currentTimeMillis())
                .putStringSet(LAST_REMOVE_GEOFENCE_IDS, geofenceIds.toSet())
                .putNullableString(LAST_REMOVE_FAILURE_MESSAGE, message),
            detail = "ids=${geofenceIds.joinToString(",")}, message=$message"
        )
    }

    fun recordBroadcastReceived(context: Context) {
        persist(
            context,
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
            context,
            "broadcast_event",
            preferences(context).edit()
                .putString(LAST_BROADCAST_EVENT, event.name)
                .putStringSet(LAST_BROADCAST_GEOFENCE_IDS, geofenceIds.toSet())
                .remove(LAST_BROADCAST_ERROR_CODE)
                .remove(LAST_BROADCAST_ERROR_MESSAGE),
            detail = "event=${event.name}, ids=${geofenceIds.joinToString(",")}"
        )
    }

    fun recordBroadcastLocation(
        context: Context,
        latitude: Double,
        longitude: Double,
        nearestGeofenceId: String?,
        distanceFromNearestGeofenceMeters: Double?,
        nearestGeofenceRadiusMeters: Double?
    ) {
        persist(
            context,
            "broadcast_location",
            preferences(context).edit()
                .putDoubleString(LAST_BROADCAST_LOCATION_LATITUDE, latitude)
                .putDoubleString(LAST_BROADCAST_LOCATION_LONGITUDE, longitude)
                .putNullableString(LAST_BROADCAST_NEAREST_GEOFENCE_ID, nearestGeofenceId)
                .putNullableDoubleString(
                    LAST_BROADCAST_DISTANCE_FROM_NEAREST_GEOFENCE,
                    distanceFromNearestGeofenceMeters
                )
                .putNullableDoubleString(
                    LAST_BROADCAST_NEAREST_GEOFENCE_RADIUS,
                    nearestGeofenceRadiusMeters
                )
        )
    }

    fun recordBroadcastError(context: Context, code: String, message: String?) {
        persist(
            context,
            "broadcast_error",
            preferences(context).edit()
                .putString(LAST_BROADCAST_ERROR_CODE, code)
                .putNullableString(LAST_BROADCAST_ERROR_MESSAGE, message),
            detail = "code=$code, message=$message"
        )
    }

    fun recordCallbackEnqueueAttempt(
        context: Context,
        event: GeofenceEvent,
        geofenceIds: List<String>
    ) {
        persist(
            context,
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
        persist(
            context,
            "callback_enqueue_failure",
            editor,
            detail = "event=${event?.name}, ids=${geofenceIds.joinToString(",")}, message=$message"
        )
    }

    fun recordCallbackWorkerStart(
        context: Context,
        params: GeofenceCallbackParamsWire?,
        runAttempt: Int
    ) {
        val editor = callbackWorkerEditor(context, params, runAttempt)
            .putLong(LAST_CALLBACK_WORKER_START_AT, System.currentTimeMillis())
            .putString(LAST_CALLBACK_WORKER_RESULT, "started")
        if (params != null) {
            editor.remove(LAST_CALLBACK_WORKER_FAILURE_CODE)
                .remove(LAST_CALLBACK_WORKER_FAILURE_MESSAGE)
        }
        persist(
            context,
            "callback_worker_start",
            editor
        )
    }

    fun recordCallbackWorkerApiReady(
        context: Context,
        params: GeofenceCallbackParamsWire?,
        runAttempt: Int
    ) {
        persist(
            context,
            "callback_worker_api_ready",
            callbackWorkerEditor(context, params, runAttempt)
                .putLong(LAST_CALLBACK_WORKER_API_READY_AT, System.currentTimeMillis())
                .putString(LAST_CALLBACK_WORKER_RESULT, "api_ready")
        )
    }

    fun recordCallbackWorkerFinish(
        context: Context,
        params: GeofenceCallbackParamsWire?,
        runAttempt: Int,
        result: String
    ) {
        val editor = callbackWorkerEditor(context, params, runAttempt)
            .putLong(LAST_CALLBACK_WORKER_FINISH_AT, System.currentTimeMillis())
            .putString(LAST_CALLBACK_WORKER_RESULT, result)
        if (result == "success") {
            editor.remove(LAST_CALLBACK_WORKER_FAILURE_CODE)
                .remove(LAST_CALLBACK_WORKER_FAILURE_MESSAGE)
        }
        persist(context, "callback_worker_finish", editor)
    }

    fun recordCallbackWorkerFailure(
        context: Context,
        params: GeofenceCallbackParamsWire?,
        runAttempt: Int,
        code: String,
        message: String?
    ) {
        persist(
            context,
            "callback_worker_failure",
            callbackWorkerEditor(context, params, runAttempt)
                .putLong(LAST_CALLBACK_WORKER_FAILURE_AT, System.currentTimeMillis())
                .putString(LAST_CALLBACK_WORKER_FAILURE_CODE, code)
                .putNullableString(LAST_CALLBACK_WORKER_FAILURE_MESSAGE, message),
            detail = "event=${params?.event?.name}, " +
                "ids=${geofenceIds(params).joinToString(",")}, " +
                "runAttempt=$runAttempt, code=$code, message=$message"
        )
    }

    fun recordRecreateAttempt(context: Context, geofenceCount: Int, reason: String?) {
        persist(
            context,
            "recreate_attempt",
            preferences(context).edit()
                .putLong(LAST_RECREATE_ATTEMPT_AT, System.currentTimeMillis())
                .putLong(LAST_RECREATE_GEOFENCE_COUNT, geofenceCount.toLong())
                .putNullableString(LAST_RECREATE_REASON, reason)
        )
    }

    fun recordRecreateSuccess(context: Context, geofenceCount: Int, reason: String?) {
        persist(
            context,
            "recreate_success",
            preferences(context).edit()
                .putLong(LAST_RECREATE_SUCCESS_AT, System.currentTimeMillis())
                .putLong(LAST_RECREATE_GEOFENCE_COUNT, geofenceCount.toLong())
                .putNullableString(LAST_RECREATE_REASON, reason)
                .remove(LAST_RECREATE_FAILURE_MESSAGE)
        )
    }

    fun recordRecreateFailure(
        context: Context,
        geofenceCount: Int,
        reason: String?,
        message: String?
    ) {
        persist(
            context,
            "recreate_failure",
            preferences(context).edit()
                .putLong(LAST_RECREATE_FAILURE_AT, System.currentTimeMillis())
                .putLong(LAST_RECREATE_GEOFENCE_COUNT, geofenceCount.toLong())
                .putNullableString(LAST_RECREATE_REASON, reason)
                .putNullableString(LAST_RECREATE_FAILURE_MESSAGE, message),
            detail = "count=$geofenceCount, reason=$reason, message=$message"
        )
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
            powerSaveMode = isPowerSaveMode(context),
            backgroundRestricted = isBackgroundRestricted(context),
            appStandbyBucket = getAppStandbyBucket(context),
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
            lastBroadcastLocationLatitude =
                readDouble(context, LAST_BROADCAST_LOCATION_LATITUDE),
            lastBroadcastLocationLongitude =
                readDouble(context, LAST_BROADCAST_LOCATION_LONGITUDE),
            lastBroadcastNearestGeofenceId =
                readString(context, LAST_BROADCAST_NEAREST_GEOFENCE_ID),
            lastBroadcastDistanceFromNearestGeofenceMeters =
                readDouble(context, LAST_BROADCAST_DISTANCE_FROM_NEAREST_GEOFENCE),
            lastBroadcastNearestGeofenceRadiusMeters =
                readDouble(context, LAST_BROADCAST_NEAREST_GEOFENCE_RADIUS),
            lastBroadcastErrorCode = readString(context, LAST_BROADCAST_ERROR_CODE),
            lastBroadcastErrorMessage = readString(context, LAST_BROADCAST_ERROR_MESSAGE),
            lastCallbackEnqueueAtMillis = readLong(context, LAST_CALLBACK_ENQUEUE_AT),
            lastCallbackEnqueueFailureAtMillis =
                readLong(context, LAST_CALLBACK_ENQUEUE_FAILURE_AT),
            lastCallbackEnqueueFailureMessage =
                readString(context, LAST_CALLBACK_ENQUEUE_FAILURE_MESSAGE),
            lastCallbackWorkerStartAtMillis =
                readLong(context, LAST_CALLBACK_WORKER_START_AT),
            lastCallbackWorkerApiReadyAtMillis =
                readLong(context, LAST_CALLBACK_WORKER_API_READY_AT),
            lastCallbackWorkerFinishAtMillis =
                readLong(context, LAST_CALLBACK_WORKER_FINISH_AT),
            lastCallbackWorkerFailureAtMillis =
                readLong(context, LAST_CALLBACK_WORKER_FAILURE_AT),
            lastCallbackWorkerResult = readString(context, LAST_CALLBACK_WORKER_RESULT),
            lastCallbackWorkerFailureCode =
                readString(context, LAST_CALLBACK_WORKER_FAILURE_CODE),
            lastCallbackWorkerFailureMessage =
                readString(context, LAST_CALLBACK_WORKER_FAILURE_MESSAGE),
            lastCallbackWorkerRunAttempt =
                readLong(context, LAST_CALLBACK_WORKER_RUN_ATTEMPT),
            lastCallbackWorkerEvent = readString(context, LAST_CALLBACK_WORKER_EVENT),
            lastCallbackWorkerGeofenceIds =
                readStringList(context, LAST_CALLBACK_WORKER_GEOFENCE_IDS),
            lastRecreateAttemptAtMillis = readLong(context, LAST_RECREATE_ATTEMPT_AT),
            lastRecreateSuccessAtMillis = readLong(context, LAST_RECREATE_SUCCESS_AT),
            lastRecreateFailureAtMillis = readLong(context, LAST_RECREATE_FAILURE_AT),
            lastRecreateGeofenceCount = readLong(context, LAST_RECREATE_GEOFENCE_COUNT),
            lastRecreateReason = readString(context, LAST_RECREATE_REASON),
            lastRecreateFailureMessage = readString(context, LAST_RECREATE_FAILURE_MESSAGE)
        )
    }

    private fun preferences(context: Context): SharedPreferences {
        return context.getSharedPreferences(Constants.SHARED_PREFERENCES_KEY, Context.MODE_PRIVATE)
    }

    private fun persist(
        context: Context,
        label: String,
        editor: SharedPreferences.Editor,
        detail: String? = null
    ) {
        if (!editor.commit()) {
            NativeGeofenceLogger.e(context, TAG, "Failed to persist diagnostic event=$label.")
        }
        // Funnel every diagnostic event into the file logger (and logcat).
        // Failures surface as warnings so host apps can filter on level.
        val message =
            if (detail == null) "event=$label" else "event=$label ($detail)"
        if (label.endsWith("_failure") || label.endsWith("_error")) {
            NativeGeofenceLogger.w(context, TAG, message)
        } else {
            NativeGeofenceLogger.d(context, TAG, message)
        }
    }

    private fun SharedPreferences.Editor.putNullableString(
        key: String,
        value: String?
    ): SharedPreferences.Editor {
        return if (value == null) remove(key) else putString(key, value)
    }

    private fun SharedPreferences.Editor.putDoubleString(
        key: String,
        value: Double
    ): SharedPreferences.Editor {
        return putString(key, value.toString())
    }

    private fun SharedPreferences.Editor.putNullableDoubleString(
        key: String,
        value: Double?
    ): SharedPreferences.Editor {
        return if (value == null) remove(key) else putDoubleString(key, value)
    }

    private fun callbackWorkerEditor(
        context: Context,
        params: GeofenceCallbackParamsWire?,
        runAttempt: Int
    ): SharedPreferences.Editor {
        val editor = preferences(context).edit()
            .putLong(LAST_CALLBACK_WORKER_RUN_ATTEMPT, runAttempt.toLong())
            .putStringSet(LAST_CALLBACK_WORKER_GEOFENCE_IDS, geofenceIds(params).toSet())
        if (params == null) {
            editor.remove(LAST_CALLBACK_WORKER_EVENT)
        } else {
            editor.putString(LAST_CALLBACK_WORKER_EVENT, params.event.name)
        }
        return editor
    }

    private fun geofenceIds(params: GeofenceCallbackParamsWire?): List<String> {
        return params?.geofences?.map { it.id } ?: emptyList()
    }

    private fun readLong(context: Context, key: String): Long? {
        val p = preferences(context)
        return if (p.contains(key)) p.getLong(key, 0L) else null
    }

    private fun readString(context: Context, key: String): String? {
        return preferences(context).getString(key, null)
    }

    private fun readDouble(context: Context, key: String): Double? {
        return preferences(context).getString(key, null)?.toDoubleOrNull()
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
            NativeGeofenceLogger.e(context, TAG, "Failed to read location enabled state.", e)
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

    private fun isPowerSaveMode(context: Context): Boolean? {
        val powerManager =
            context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return null
        return powerManager.isPowerSaveMode
    }

    private fun isBackgroundRestricted(context: Context): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return null
        }
        val activityManager =
            context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return null
        return activityManager.isBackgroundRestricted
    }

    private fun getAppStandbyBucket(context: Context): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return null
        }
        val usageStatsManager =
            context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
                ?: return null
        val bucket = usageStatsManager.appStandbyBucket
        return when (bucket) {
            5 -> "exempted(5)"
            10 -> "active(10)"
            20 -> "working_set(20)"
            30 -> "frequent(30)"
            40 -> "rare(40)"
            45 -> "restricted(45)"
            50 -> "never(50)"
            else -> "unknown($bucket)"
        }
    }
}
