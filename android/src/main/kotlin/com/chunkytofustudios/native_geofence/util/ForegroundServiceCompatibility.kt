package com.chunkytofustudios.native_geofence.util

import android.Manifest
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.chunkytofustudios.native_geofence.NativeGeofenceForegroundService
import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode

internal object ForegroundServiceCompatibility {
    const val RUNTIME_FOREGROUND_SERVICE_TYPE =
        ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION

    fun validatePrerequisites(context: Context): FlutterError? {
        val serviceInfo = serviceInfo(context) ?: return configurationError(
            "NativeGeofenceForegroundService is missing from the merged Android manifest."
        )
        val component = ComponentName(context, NativeGeofenceForegroundService::class.java)
        val enabledSetting = context.packageManager.getComponentEnabledSetting(component)
        if (
            !serviceInfo.enabled ||
            enabledSetting == PackageManager.COMPONENT_ENABLED_STATE_DISABLED ||
            enabledSetting == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER ||
            enabledSetting == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED
        ) {
            return configurationError(
                "NativeGeofenceForegroundService is disabled in the merged Android manifest."
            )
        }

        val requiredPermissions = buildList {
            add(Manifest.permission.WAKE_LOCK)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                add(Manifest.permission.FOREGROUND_SERVICE)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                add("android.permission.FOREGROUND_SERVICE_LOCATION")
            }
        }
        val missingPermission = requiredPermissions.firstOrNull { permission ->
            ContextCompat.checkSelfPermission(context, permission) !=
                PackageManager.PERMISSION_GRANTED
        }
        if (missingPermission != null) {
            return configurationError(
                "A required Android foreground-service permission is missing.",
                missingPermission
            )
        }

        if (!LocationState.hasFinePermission(context)) {
            return FlutterError(
                NativeGeofenceErrorCode.MISSING_LOCATION_PERMISSION.raw.toString(),
                "ACCESS_FINE_LOCATION is required for a location foreground service."
            )
        }
        if (!LocationState.hasBackgroundPermission(context)) {
            return FlutterError(
                NativeGeofenceErrorCode.MISSING_BACKGROUND_LOCATION_PERMISSION.raw.toString(),
                "ACCESS_BACKGROUND_LOCATION is required for callback foreground promotion."
            )
        }

        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            !declaresRequiredForegroundServiceType(serviceInfo.foregroundServiceType)
        ) {
            return configurationError(
                "NativeGeofenceForegroundService must declare foregroundServiceType=location."
            )
        }

        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, POST_NOTIFICATIONS_PERMISSION) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return notificationPermissionError(
                "POST_NOTIFICATIONS permission is required before foreground promotion."
            )
        }
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            return notificationPermissionError(
                "Notifications are disabled, so foreground promotion is unavailable."
            )
        }
        return null
    }

    internal fun declaresRequiredForegroundServiceType(declaredTypes: Int): Boolean =
        declaredTypes and RUNTIME_FOREGROUND_SERVICE_TYPE != 0

    fun start(context: Context, intent: Intent): Result<Unit> = try {
        val component = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
        if (component == null) {
            Result.failure(configurationError("Android did not resolve the foreground service."))
        } else {
            Result.success(Unit)
        }
    } catch (error: Throwable) {
        Result.failure(mapStartError(error))
    }

    fun stop(context: Context) {
        try {
            context.stopService(Intent(context, NativeGeofenceForegroundService::class.java))
        } catch (error: RuntimeException) {
            NativeGeofenceLogger.w(
                context,
                "ForegroundServiceCompatibility",
                "Failed to stop the geofence foreground service.",
                error
            )
        }
    }

    fun stopForeground(service: Service) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            service.stopForeground(true)
        }
    }

    fun mapStartError(error: Throwable): FlutterError = when {
        isForegroundStartNotAllowed(error) -> FlutterError(
            NativeGeofenceErrorCode.ANDROID_FOREGROUND_SERVICE_START_NOT_ALLOWED.raw.toString(),
            "Android does not allow foreground-service start from the current app state."
        )
        error is SecurityException -> configurationError(
            "Android rejected foreground-service promotion because a prerequisite is missing.",
            error.toString()
        )
        else -> FlutterError(
            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
            "Android foreground-service promotion failed.",
            error.toString()
        )
    }

    private fun serviceInfo(context: Context): ServiceInfo? = try {
        val component = ComponentName(context, NativeGeofenceForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getServiceInfo(
                component,
                PackageManager.ComponentInfoFlags.of(0L)
            )
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getServiceInfo(component, 0)
        }
    } catch (_: PackageManager.NameNotFoundException) {
        null
    }

    private fun configurationError(message: String, details: String? = null) = FlutterError(
        NativeGeofenceErrorCode.ANDROID_FOREGROUND_SERVICE_CONFIGURATION_MISSING.raw.toString(),
        message,
        details
    )

    private fun notificationPermissionError(message: String) = FlutterError(
        NativeGeofenceErrorCode.MISSING_NOTIFICATION_PERMISSION.raw.toString(),
        message
    )

    private fun isForegroundStartNotAllowed(error: Throwable): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && Api31.isStartNotAllowed(error)

    @RequiresApi(Build.VERSION_CODES.S)
    private object Api31 {
        fun isStartNotAllowed(error: Throwable): Boolean =
            error is android.app.ForegroundServiceStartNotAllowedException
    }

    private const val POST_NOTIFICATIONS_PERMISSION = "android.permission.POST_NOTIFICATIONS"
}
