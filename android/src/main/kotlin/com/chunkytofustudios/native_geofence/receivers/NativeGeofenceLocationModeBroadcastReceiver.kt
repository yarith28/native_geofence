package com.chunkytofustudios.native_geofence.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import com.chunkytofustudios.native_geofence.api.NativeGeofenceApiImpl
import com.chunkytofustudios.native_geofence.util.LocationState
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger

class NativeGeofenceLocationModeBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != LocationManager.MODE_CHANGED_ACTION) {
            return
        }
        val appContext = context.applicationContext
        if (!LocationState.isEnabled(appContext)) {
            return
        }

        val admission = NativeGeofenceRecoveryRuntime.acquireLocationModeRecoveryAdmission()
            ?: return
        val lease = try {
            RecoveryBroadcastLease(
                pendingResult = goAsync(),
                onFinish = admission::finish,
            )
        } catch (error: Throwable) {
            admission.finish()
            NativeGeofenceLogger.e(
                appContext,
                TAG,
                "Failed to acquire the location-services recovery broadcast lease.",
                error,
            )
            return
        }
        try {
            NativeGeofenceApiImpl(appContext).startAutomaticRecovery(
                reason = REASON
            ) { result ->
                try {
                    result.exceptionOrNull()?.let { error ->
                        NativeGeofenceLogger.e(
                            appContext,
                            TAG,
                            "Geofence recovery failed after location services became available.",
                            error
                        )
                    }
                } finally {
                    lease.finish()
                }
            }
        } catch (error: Throwable) {
            NativeGeofenceLogger.e(
                appContext,
                TAG,
                "Failed to start location-services geofence recovery.",
                error
            )
            lease.finish()
        }
    }

    private companion object {
        const val TAG = "NativeGeofenceLocationModeReceiver"
        const val REASON = "location_services_available"
    }
}
