package com.chunkytofustudios.native_geofence.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.chunkytofustudios.native_geofence.api.NativeGeofenceApiImpl
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger

class NativeGeofenceRebootBroadcastReceiver : BroadcastReceiver() {
    companion object {
        const val TAG = "NativeGeofenceRebootBroadcastReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        // Android clears geofences on reboot, and some devices use quick-boot actions.
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON" &&
            intent.action != "com.htc.intent.action.QUICKBOOT_POWERON"
        ) {
            NativeGeofenceLogger.w(context, TAG, "Ignoring unsupported broadcast action=${intent.action}.")
            return
        }

        NativeGeofenceLogger.i(context, TAG, "${intent.action} broadcast received. Re-creating geofences!")
        // Re-registration is asynchronous; without goAsync Android may finish
        // the receiver before Play services accepts all geofences.
        val pendingResult = goAsync()
        try {
            NativeGeofenceApiImpl(context.applicationContext).reCreateAfterReboot(
                reason = intent.action
            ) {
                pendingResult.finish()
            }
        } catch (e: Exception) {
            NativeGeofenceLogger.e(context, TAG, "Failed to re-create geofences after ${intent.action}: $e", e)
            pendingResult.finish()
        }
    }
}
