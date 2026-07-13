package com.chunkytofustudios.native_geofence.api

import com.chunkytofustudios.native_geofence.NativeGeofenceBackgroundWorker
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceBackgroundApi
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger

class NativeGeofenceBackgroundApiImpl(
    private val worker: NativeGeofenceBackgroundWorker
) : NativeGeofenceBackgroundApi {
    companion object {
        @JvmStatic
        private val TAG = "NativeGeofenceBackgroundApiImpl"
    }

    override fun triggerApiInitialized() {
        worker.triggerApiReady()
    }

    override fun promoteToForeground(callback: (kotlin.Result<Unit>) -> Unit) {
        worker.requestForegroundPromotion { result ->
            if (result.isSuccess) {
                NativeGeofenceLogger.d(
                    worker.applicationContext,
                    TAG,
                    "Promoted callback worker to a foreground service."
                )
            }
            callback(result)
        }
    }

    override fun demoteToBackground() {
        worker.demoteForegroundService()
        NativeGeofenceLogger.d(
            worker.applicationContext,
            TAG,
            "Demoted foreground service back to background service."
        )
    }
}
