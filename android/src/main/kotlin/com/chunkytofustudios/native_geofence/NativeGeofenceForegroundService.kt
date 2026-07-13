package com.chunkytofustudios.native_geofence

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.ServiceCompat
import com.chunkytofustudios.native_geofence.util.ForegroundPromotionRegistry
import com.chunkytofustudios.native_geofence.util.ForegroundServiceCompatibility
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.Notifications
import kotlin.time.Duration.Companion.minutes

class NativeGeofenceForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val token = intent?.getStringExtra(Constants.FOREGROUND_PROMOTION_TOKEN_KEY)
        if (intent?.action != Constants.ACTION_PROMOTE_FOREGROUND || token.isNullOrBlank()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }

        try {
            acquireWakeLock()
            val notification = Notifications.createForegroundServiceNotification(this)
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ForegroundServiceCompatibility.RUNTIME_FOREGROUND_SERVICE_TYPE
            )
            val accepted = ForegroundPromotionRegistry.complete(token, Result.success(Unit))
            if (!accepted) {
                releaseWakeLock()
                ForegroundServiceCompatibility.stopForeground(this)
                stopSelf(startId)
                return START_NOT_STICKY
            }
            NativeGeofenceLogger.d(
                this,
                TAG,
                "Foreground promotion confirmed for the active callback worker."
            )
        } catch (error: Throwable) {
            ForegroundPromotionRegistry.complete(
                token,
                Result.failure(ForegroundServiceCompatibility.mapStartError(error))
            )
            releaseWakeLock()
            ForegroundServiceCompatibility.stopForeground(this)
            stopSelf(startId)
            NativeGeofenceLogger.e(this, TAG, "Foreground promotion failed.", error)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        ForegroundServiceCompatibility.stopForeground(this)
        NativeGeofenceLogger.d(this, TAG, "Foreground service stopped.")
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        val existing = wakeLock
        if (existing?.isHeld == true) return

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            Constants.ISOLATE_HOLDER_WAKE_LOCK_TAG
        ).apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_TIMEOUT.inWholeMilliseconds)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { lock ->
            if (lock.isHeld) {
                lock.release()
            }
        }
        wakeLock = null
    }

    private companion object {
        const val TAG = "NativeGeofenceForegroundService"
        const val NOTIFICATION_ID = 938130
        val WAKE_LOCK_TIMEOUT = 5.minutes
    }
}
