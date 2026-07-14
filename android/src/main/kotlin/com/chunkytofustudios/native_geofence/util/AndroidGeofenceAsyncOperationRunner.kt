package com.chunkytofustudios.native_geofence.util

import java.util.concurrent.atomic.AtomicBoolean

/** Starts and attaches an asynchronous Play services operation exactly once. */
internal fun runAndroidGeofenceAsyncOperation(
    begin: () -> AndroidGeofenceAsyncOperation,
    onSuccess: () -> Unit,
    onFailure: (Throwable) -> Unit,
) {
    val completed = AtomicBoolean(false)
    fun succeed() {
        if (completed.compareAndSet(false, true)) onSuccess()
    }
    fun fail(error: Throwable) {
        if (completed.compareAndSet(false, true)) onFailure(error)
    }

    val operation = try {
        begin()
    } catch (error: Throwable) {
        fail(error)
        return
    }
    try {
        operation.attach(::succeed, ::fail)
    } catch (error: Throwable) {
        fail(error)
    }
}
