package com.chunkytofustudios.native_geofence.receivers

import android.content.Context
import android.content.IntentFilter
import android.location.LocationManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import java.util.WeakHashMap

/** Process-scoped ownership for recovery resources shared by multiple Flutter engines. */
internal object NativeGeofenceRecoveryRuntime {
    private val lock = Object()
    private val locationReceivers = WeakHashMap<Context, ReceiverReference>()
    private val initializedContexts = WeakHashMap<Context, Boolean>()
    private val locationModeRecoveryAdmissionGate = LocationModeRecoveryAdmissionGate()

    fun shouldRunInitializationRepair(context: Context): Boolean = synchronized(lock) {
        val applicationContext = context.applicationContext
        if (initializedContexts.containsKey(applicationContext)) {
            false
        } else {
            initializedContexts[applicationContext] = true
            true
        }
    }

    fun acquireLocationModeRecoveryAdmission(): LocationModeRecoveryAdmission? {
        val token = locationModeRecoveryAdmissionGate.tryAcquire(SystemClock.elapsedRealtime())
            ?: return null
        return LocationModeRecoveryAdmission {
            locationModeRecoveryAdmissionGate.release(token)
        }
    }

    fun acquireLocationModeReceiver(context: Context): Boolean = synchronized(lock) {
        val applicationContext = context.applicationContext
        val existing = locationReceivers[applicationContext]
        if (existing != null) {
            existing.references += 1
            return true
        }

        val receiver = NativeGeofenceLocationModeBroadcastReceiver()
        ContextCompat.registerReceiver(
            applicationContext,
            receiver,
            IntentFilter(LocationManager.MODE_CHANGED_ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        locationReceivers[applicationContext] = ReceiverReference(receiver, references = 1)
        true
    }

    fun releaseLocationModeReceiver(context: Context) = synchronized(lock) {
        val applicationContext = context.applicationContext
        val existing = locationReceivers[applicationContext] ?: return
        existing.references -= 1
        if (existing.references == 0) {
            try {
                applicationContext.unregisterReceiver(existing.receiver)
            } finally {
                locationReceivers.remove(applicationContext)
            }
        }
    }

    private data class ReceiverReference(
        val receiver: NativeGeofenceLocationModeBroadcastReceiver,
        var references: Int
    )
}
