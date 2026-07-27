package com.chunkytofustudios.native_geofence.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.chunkytofustudios.native_geofence.api.NativeGeofenceApiImpl
import com.chunkytofustudios.native_geofence.bridge.CallbackPayloadEnqueueRecovery
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger

class NativeGeofenceRebootBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action !in SUPPORTED_ACTIONS) {
            return
        }
        CallbackPayloadEnqueueRecovery.recover(context.applicationContext)
        val lease = RecoveryBroadcastLease(goAsync())
        try {
            NativeGeofenceApiImpl(context.applicationContext).startAutomaticRecovery(
                reason = action ?: "boot"
            ) { result ->
                try {
                    result.exceptionOrNull()?.let { error ->
                        NativeGeofenceLogger.e(
                            context,
                            TAG,
                            "Automatic geofence recovery failed after $action.",
                            error
                        )
                    }
                } finally {
                    lease.finish()
                }
            }
        } catch (error: Throwable) {
            NativeGeofenceLogger.e(
                context,
                TAG,
                "Failed to start geofence recovery after $action.",
                error
            )
            lease.finish()
        }
    }

    private companion object {
        const val TAG = "NativeGeofenceRebootReceiver"
        val SUPPORTED_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON"
        )
    }
}
