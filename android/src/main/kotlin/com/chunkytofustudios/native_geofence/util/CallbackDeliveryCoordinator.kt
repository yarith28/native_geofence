package com.chunkytofustudios.native_geofence.util

internal enum class CallbackDeliveryStage {
    STARTUP,
    API_READY,
    CALLBACK
}

/** Exact-once stage watchdog that ignores callbacks from superseded stages. */
internal class CallbackDeliveryCoordinator(
    private val timeoutMillis: (CallbackDeliveryStage) -> Long,
    private val schedule: (Long, () -> Unit) -> (() -> Unit),
    private val onTimeout: (CallbackDeliveryStage) -> Unit
) {
    private val lock = Object()
    private var stage: CallbackDeliveryStage? = CallbackDeliveryStage.STARTUP
    private var generation = 0L
    private var cancelWatchdog: (() -> Unit)? = null

    init {
        synchronized(lock) {
            scheduleLocked(CallbackDeliveryStage.STARTUP)
        }
    }

    fun advance(
        expected: CallbackDeliveryStage,
        next: CallbackDeliveryStage
    ): Boolean = synchronized(lock) {
        if (stage != expected) {
            return false
        }
        cancelWatchdog?.invoke()
        stage = next
        scheduleLocked(next)
        true
    }

    fun complete(expected: CallbackDeliveryStage): Boolean = synchronized(lock) {
        if (stage != expected) {
            return false
        }
        cancelWatchdog?.invoke()
        cancelWatchdog = null
        stage = null
        generation += 1L
        true
    }

    fun cancel(): Boolean = synchronized(lock) {
        if (stage == null) {
            return false
        }
        cancelWatchdog?.invoke()
        cancelWatchdog = null
        stage = null
        generation += 1L
        true
    }

    private fun scheduleLocked(newStage: CallbackDeliveryStage) {
        generation += 1L
        val scheduledGeneration = generation
        cancelWatchdog = schedule(timeoutMillis(newStage)) {
            val shouldFire = synchronized(lock) {
                if (stage == newStage && generation == scheduledGeneration) {
                    cancelWatchdog = null
                    stage = null
                    generation += 1L
                    true
                } else {
                    false
                }
            }
            if (shouldFire) {
                onTimeout(newStage)
            }
        }
    }
}
