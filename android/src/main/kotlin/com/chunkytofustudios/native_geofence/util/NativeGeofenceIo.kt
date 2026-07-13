package com.chunkytofustudios.native_geofence.util

import android.util.Log
import java.util.concurrent.Executors

/** Serializes plugin-owned disk IO away from platform and broadcast threads. */
internal object NativeGeofenceIo {
    private const val TAG = "NativeGeofenceIo"

    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "native-geofence-io")
    }

    fun execute(task: () -> Unit) {
        executor.execute {
            try {
                task()
            } catch (e: Throwable) {
                Log.e(TAG, "Unhandled native_geofence IO task failure.", e)
            }
        }
    }
}
