package com.chunkytofustudios.native_geofence.receivers

import java.util.concurrent.atomic.AtomicBoolean

internal class LocationModeRecoveryAdmissionGate(
    private val duplicateWindowMillis: Long = DEFAULT_DUPLICATE_WINDOW_MILLIS,
) {
    internal data class Token(val value: Long)

    private val lock = Object()
    private var nextToken = 1L
    private var activeToken: Token? = null
    private var lastAcceptedAtMillis: Long? = null

    fun tryAcquire(nowMillis: Long): Token? = synchronized(lock) {
        if (activeToken != null) return@synchronized null
        val previousAcceptedAt = lastAcceptedAtMillis
        if (
            previousAcceptedAt != null &&
            nowMillis >= previousAcceptedAt &&
            nowMillis - previousAcceptedAt < duplicateWindowMillis
        ) {
            return@synchronized null
        }

        val token = Token(nextToken)
        nextToken = if (nextToken == Long.MAX_VALUE) 1L else nextToken + 1L
        activeToken = token
        lastAcceptedAtMillis = nowMillis
        token
    }

    fun release(token: Token) = synchronized(lock) {
        if (activeToken == token) {
            activeToken = null
        }
    }

    private companion object {
        const val DEFAULT_DUPLICATE_WINDOW_MILLIS = 5_000L
    }
}

internal class LocationModeRecoveryAdmission(
    private val release: () -> Unit,
) {
    private val released = AtomicBoolean(false)

    fun finish() {
        if (released.compareAndSet(false, true)) {
            release()
        }
    }
}
