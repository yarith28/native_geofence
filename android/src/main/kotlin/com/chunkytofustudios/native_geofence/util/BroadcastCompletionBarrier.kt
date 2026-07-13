package com.chunkytofustudios.native_geofence.util

import java.util.concurrent.atomic.AtomicBoolean

/** Fixed-size, exact-once completion barrier for one BroadcastReceiver lease. */
internal class BroadcastCompletionBarrier(
    private val taskCount: Int,
    private val onComplete: () -> Unit
) {
    private val lock = Object()
    private var issued = 0
    private var remaining = taskCount
    private val completed = AtomicBoolean(false)

    init {
        require(taskCount >= 0)
        if (taskCount == 0) {
            completeBarrier()
        }
    }

    fun ticket(): () -> Unit {
        synchronized(lock) {
            check(issued < taskCount) { "All broadcast completion tickets were already issued." }
            issued += 1
        }
        val ticketCompleted = AtomicBoolean(false)
        return {
            if (ticketCompleted.compareAndSet(false, true)) {
                val finish = synchronized(lock) {
                    remaining -= 1
                    remaining == 0
                }
                if (finish) {
                    completeBarrier()
                }
            }
        }
    }

    private fun completeBarrier() {
        if (completed.compareAndSet(false, true)) {
            onComplete()
        }
    }
}
