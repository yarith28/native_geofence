package com.chunkytofustudios.native_geofence.receivers

import android.content.BroadcastReceiver
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean

/** Releases a goAsync lease exactly once, including if Play services never responds. */
internal class RecoveryBroadcastLease(
    private val pendingResult: BroadcastReceiver.PendingResult,
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val onFinish: () -> Unit = {},
) {
    private val completed = AtomicBoolean(false)
    private val timeout = Runnable(::finish)

    init {
        handler.postDelayed(timeout, TIMEOUT_MILLIS)
    }

    fun finish() {
        if (completed.compareAndSet(false, true)) {
            handler.removeCallbacks(timeout)
            try {
                pendingResult.finish()
            } finally {
                onFinish()
            }
        }
    }

    private companion object {
        const val TIMEOUT_MILLIS = 9_000L
    }
}
