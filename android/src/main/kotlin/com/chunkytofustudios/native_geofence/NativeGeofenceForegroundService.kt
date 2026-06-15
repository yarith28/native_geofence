package com.chunkytofustudios.native_geofence

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.ServiceCompat
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.Notifications
import kotlin.time.Duration.Companion.minutes

// TODO: Allow customizing notification details.
class NativeGeofenceForegroundService : Service() {
    companion object {
        @JvmStatic
        private val TAG = "NativeGeofenceForegroundService"

        // TODO: Consider using random ID.
        private const val NOTIFICATION_ID = 938130

        private val WAKE_LOCK_TIMEOUT = 5.minutes
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(p0: Intent): IBinder? {
        return null
    }

    override fun onCreate() {
        super.onCreate()
        val notification = Notifications.createForegroundServiceNotification(this)

        // Retain the exact wake lock instance so demotion can release it early.
        acquireWakeLock()
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                else
                    0
            )
            NativeGeofenceLogger.d(applicationContext, TAG, "Foreground service started with notification ID=$NOTIFICATION_ID.")
        } catch (e: Exception) {
            NativeGeofenceLogger.e(
                applicationContext,
                TAG,
                "Failed to start foreground service. Declare foregroundServiceType=\"location\" " +
                    "and the foreground service location permissions when using promoteToForeground().",
                e
            )
            releaseWakeLock()
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == Constants.ACTION_SHUTDOWN) {
            releaseWakeLock()
            stopForegroundCompat()
            stopSelf()
            NativeGeofenceLogger.d(applicationContext, TAG, "Foreground service stopped.")
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        // The service can be killed without an explicit demote request.
        releaseWakeLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) {
            return
        }
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, Constants.ISOLATE_HOLDER_WAKE_LOCK_TAG)
            .apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_TIMEOUT.inWholeMilliseconds)
            }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        wakeLock = null
    }

    private fun stopForegroundCompat() {
        // STOP_FOREGROUND_REMOVE was added in API 24; the plugin supports API 23.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
