package com.chunkytofustudios.native_geofence.api

import android.content.Context
import android.content.Intent
import android.os.Build
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.NativeGeofenceForegroundService
import com.chunkytofustudios.native_geofence.NativeGeofenceBackgroundWorker
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceBackgroundApi
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger

class NativeGeofenceBackgroundApiImpl(
    private val context: Context,
    private val worker: NativeGeofenceBackgroundWorker
) : NativeGeofenceBackgroundApi {
    companion object {
        @JvmStatic
        private val TAG = "NativeGeofenceBackgroundApiImpl"
    }

    override fun triggerApiInitialized() {
        worker.triggerApiReady()
    }

    override fun promoteToForeground() {
        startForegroundServiceCompat(Intent(context, NativeGeofenceForegroundService::class.java))
        NativeGeofenceLogger.d(context, TAG, "Promoted background service to foreground service.")
    }

    override fun demoteToBackground() {
        val intent = Intent(context, NativeGeofenceForegroundService::class.java)
        intent.setAction(Constants.ACTION_SHUTDOWN)
        startForegroundServiceCompat(intent)
        NativeGeofenceLogger.d(context, TAG, "Demoted foreground service back to background service.")
    }

    private fun startForegroundServiceCompat(intent: Intent) {
        // startForegroundService exists only on API 26+, while this plugin supports API 23.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: Exception) {
            NativeGeofenceLogger.e(context, TAG, "Failed to start NativeGeofenceForegroundService.", e)
            throw e
        }
    }
}
