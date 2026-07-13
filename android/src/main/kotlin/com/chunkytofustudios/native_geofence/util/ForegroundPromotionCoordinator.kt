package com.chunkytofustudios.native_geofence.util

import android.os.Handler
import android.os.Looper
import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode

internal class ForegroundPromotionCoordinator(
    private val timeoutMillis: Long,
    private val schedule: (Long, () -> Unit) -> (() -> Unit),
    private val timeoutError: () -> Throwable,
    private val onCallbackError: (Throwable) -> Unit = {}
) {
    private val lock = Object()
    private val pending = mutableMapOf<String, PendingPromotion>()

    fun request(token: String, callback: (Result<Unit>) -> Unit): Boolean = synchronized(lock) {
        if (token.isBlank() || pending.containsKey(token)) {
            return false
        }
        val cancel = schedule(timeoutMillis) {
            complete(token, Result.failure(timeoutError()))
        }
        pending[token] = PendingPromotion(cancel, callback)
        true
    }

    fun complete(token: String, result: Result<Unit>): Boolean {
        val promotion = synchronized(lock) { pending.remove(token) } ?: return false
        promotion.cancelTimeout()
        try {
            promotion.callback(result)
        } catch (error: Throwable) {
            onCallbackError(error)
        }
        return true
    }

    fun abandon(token: String): Boolean {
        val promotion = synchronized(lock) { pending.remove(token) } ?: return false
        promotion.cancelTimeout()
        return true
    }

    private data class PendingPromotion(
        val cancelTimeout: () -> Unit,
        val callback: (Result<Unit>) -> Unit
    )
}

internal object ForegroundPromotionRegistry {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val coordinator = ForegroundPromotionCoordinator(
        timeoutMillis = PROMOTION_TIMEOUT_MILLIS,
        schedule = { delayMillis, action ->
            val runnable = Runnable(action)
            mainHandler.postDelayed(runnable, delayMillis)
            val cancel: () -> Unit = { mainHandler.removeCallbacks(runnable) }
            cancel
        },
        timeoutError = {
            FlutterError(
                NativeGeofenceErrorCode.ANDROID_FOREGROUND_SERVICE_PROMOTION_TIMEOUT.raw.toString(),
                "Android did not confirm foreground-service promotion before timeout."
            )
        },
        onCallbackError = { error ->
            NativeGeofenceLogger.e(
                "ForegroundPromotionRegistry",
                "Foreground promotion callback threw an exception.",
                error
            )
        }
    )

    fun request(token: String, callback: (Result<Unit>) -> Unit): Boolean =
        coordinator.request(token, callback)

    fun complete(token: String, result: Result<Unit>): Boolean =
        coordinator.complete(token, result)

    fun abandon(token: String): Boolean = coordinator.abandon(token)

    private const val PROMOTION_TIMEOUT_MILLIS = 10_000L
}
