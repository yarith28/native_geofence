package com.chunkytofustudios.native_geofence.util

import android.Manifest
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceCallbackRefreshState
import com.chunkytofustudios.native_geofence.generated.NativeGeofencePlatform
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceStatusWire
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceBroadcastReceiver
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability

internal object AndroidCallbackRefreshPolicy {
    fun evaluate(
        currentFingerprint: String,
        dispatcherFingerprint: String?,
        registrationFingerprints: List<String?>,
        callbackRefreshRequired: Boolean
    ): NativeGeofenceCallbackRefreshState {
        if (registrationFingerprints.isEmpty()) {
            return NativeGeofenceCallbackRefreshState.NOT_APPLICABLE
        }
        if (callbackRefreshRequired) {
            return NativeGeofenceCallbackRefreshState.REFRESH_REQUIRED
        }
        if (
            (dispatcherFingerprint != null && dispatcherFingerprint != currentFingerprint) ||
            registrationFingerprints.any { fingerprint ->
                fingerprint != null && fingerprint != currentFingerprint
            }
        ) {
            return NativeGeofenceCallbackRefreshState.REFRESH_REQUIRED
        }
        return if (
            dispatcherFingerprint == null || registrationFingerprints.any { it == null }
        ) {
            NativeGeofenceCallbackRefreshState.UNKNOWN
        } else {
            NativeGeofenceCallbackRefreshState.CURRENT
        }
    }
}

internal class AndroidNativeGeofenceStatusProvider(private val context: Context) {
    fun status(): NativeGeofenceStatusWire {
        val appContext = context.applicationContext
        val registrationInventory = NativeGeofencePersistence.inspectStatusInventory(appContext)
        val ids = registrationInventory.map(GeofenceStatusInventoryEntry::id)
        val locationPermission = LocationState.hasFinePermission(appContext)
        val backgroundPermission = LocationState.hasBackgroundPermission(appContext)
        val locationServicesEnabled = LocationState.isEnabled(appContext)
        val playServicesAvailable =
            GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(appContext) ==
                ConnectionResult.SUCCESS
        val receiverAvailable = callbackReceiverAvailable(appContext)
        val pendingIntentAvailable = callbackPendingIntentAvailable(appContext)
        val dispatcherRegistered = callbackDispatcherRegistered(appContext)
        val refreshState = callbackRefreshState(appContext, registrationInventory)
        val health = NativeGeofenceStatusHealth.compute(
            NativeGeofenceHealthEvidence(
                persistedRegistrationCount = ids.size,
                locationPermissionGranted = locationPermission,
                backgroundLocationPermissionGranted = backgroundPermission,
                locationServicesEnabled = locationServicesEnabled,
                platformMonitoringAvailable = playServicesAvailable,
                callbackInfrastructureAvailable = receiverAvailable && pendingIntentAvailable,
                callbackDispatcherRegistered = dispatcherRegistered,
                callbackRefreshState = refreshState,
                androidLifecycleEvidence = AndroidGeofenceLifecycleEvidence.from(
                    registrationInventory
                )
            )
        )

        return NativeGeofenceStatusWire(
            platform = NativeGeofencePlatform.ANDROID,
            osVersion = "API ${Build.VERSION.SDK_INT} (${Build.VERSION.RELEASE})",
            persistedGeofenceCount = ids.size.toLong(),
            locationPermissionGranted = locationPermission,
            backgroundLocationPermissionGranted = backgroundPermission,
            notificationPermissionGranted = notificationPermissionGranted(appContext),
            locationServicesEnabled = locationServicesEnabled,
            monitoringAvailable = null,
            playServicesAvailable = playServicesAvailable,
            callbackPendingIntentAvailable = pendingIntentAvailable,
            callbackReceiverAvailable = receiverAvailable,
            canEnumerateLivePlatformRegistrations = false,
            pluginOwnedMonitoringCount = null,
            callbackDispatcherRegistered = dispatcherRegistered,
            callbackRefreshState = refreshState,
            registrationHealth = health,
            lastRegistrationFact = fact(appContext, NativeGeofenceDiagnosticStage.REGISTRATION),
            lastRemovalFact = fact(appContext, NativeGeofenceDiagnosticStage.REMOVAL),
            lastBroadcastFact = fact(appContext, NativeGeofenceDiagnosticStage.BROADCAST),
            lastEnqueueFact = fact(appContext, NativeGeofenceDiagnosticStage.ENQUEUE),
            lastWorkerFact = fact(appContext, NativeGeofenceDiagnosticStage.WORKER),
            lastRecoveryFact = fact(appContext, NativeGeofenceDiagnosticStage.RECOVERY),
            lastForegroundFact = fact(appContext, NativeGeofenceDiagnosticStage.FOREGROUND)
        )
    }

    private fun callbackDispatcherRegistered(context: Context): Boolean =
        preferences(context).getLong(Constants.CALLBACK_DISPATCHER_HANDLE_KEY, 0L) != 0L

    private fun callbackRefreshState(
        context: Context,
        inventory: List<GeofenceStatusInventoryEntry>
    ): NativeGeofenceCallbackRefreshState {
        val current = AndroidPackageFingerprint.current(context)
        val dispatcherFingerprint = preferences(context).getString(
            Constants.CALLBACK_DISPATCHER_PACKAGE_FINGERPRINT_KEY,
            null
        )
        return AndroidCallbackRefreshPolicy.evaluate(
            currentFingerprint = current,
            dispatcherFingerprint = dispatcherFingerprint,
            registrationFingerprints = inventory.map(
                GeofenceStatusInventoryEntry::callbackPackageFingerprint
            ),
            callbackRefreshRequired = NativeGeofencePersistence
                .isCallbackRefreshRequiredFor(context, inventory.map { it.id }.toSet())
        )
    }

    private fun callbackReceiverAvailable(context: Context): Boolean {
        val component = ComponentName(context, NativeGeofenceBroadcastReceiver::class.java)
        val info = try {
            AndroidPackageManagerCompat.getReceiverInfo(
                context.packageManager,
                component,
            )
        } catch (_: PackageManager.NameNotFoundException) {
            return false
        }
        val setting = context.packageManager.getComponentEnabledSetting(component)
        return info.enabled &&
            setting != PackageManager.COMPONENT_ENABLED_STATE_DISABLED &&
            setting != PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER &&
            setting != PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED
    }

    private fun callbackPendingIntentAvailable(context: Context): Boolean = try {
        val flags = PendingIntent.FLAG_NO_CREATE or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        PendingIntent.getBroadcast(
            context,
            0,
            Intent(context, NativeGeofenceBroadcastReceiver::class.java),
            flags
        ) != null
    } catch (_: RuntimeException) {
        false
    }

    private fun notificationPermissionGranted(context: Context): Boolean {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    private fun fact(context: Context, stage: NativeGeofenceDiagnosticStage) =
        NativeGeofenceDiagnostics.fact(context, stage)

    private fun preferences(context: Context) = context.getSharedPreferences(
        Constants.SHARED_PREFERENCES_KEY,
        Context.MODE_PRIVATE
    )
}
