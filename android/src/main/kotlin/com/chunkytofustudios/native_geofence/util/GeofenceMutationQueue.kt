package com.chunkytofustudios.native_geofence.util

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.ArrayDeque
import java.util.WeakHashMap
import java.util.concurrent.atomic.AtomicBoolean

internal class GeofenceMutationQueue(
    private val dispatch: (() -> Unit) -> Unit,
    private val onUnhandledError: (Throwable) -> Unit = {}
) {
    private val lock = Object()
    private val operations = ArrayDeque<((() -> Unit) -> Unit)>()
    private var running = false

    fun enqueue(operation: (() -> Unit) -> Unit) {
        val shouldStart = synchronized(lock) {
            operations.addLast(operation)
            if (running) {
                false
            } else {
                running = true
                true
            }
        }
        if (shouldStart) {
            dispatchNext()
        }
    }

    private fun dispatchNext() {
        try {
            dispatch(::runNext)
        } catch (error: Throwable) {
            onUnhandledError(error)
            // A broken dispatcher must not strand the queue. Continue on the
            // current thread; production dispatch normally targets main.
            runNext()
        }
    }

    private fun runNext() {
        val operation = synchronized(lock) {
            val next = operations.pollFirst()
            if (next == null) {
                running = false
            }
            next
        } ?: return

        val completed = AtomicBoolean(false)
        val complete = {
            if (completed.compareAndSet(false, true)) {
                dispatchNext()
            }
        }

        try {
            operation(complete)
        } catch (error: Throwable) {
            onUnhandledError(error)
            complete()
        }
    }
}

internal class GeofenceMutationRunner(
    private val queue: GeofenceMutationQueue,
    private val onCallbackError: (Throwable) -> Unit = {}
) {
    fun <T> run(
        callback: (Result<T>) -> Unit,
        start: ((Result<T>) -> Unit) -> Unit
    ) {
        queue.enqueue { queueComplete ->
            val completed = AtomicBoolean(false)
            val complete: (Result<T>) -> Unit = { result ->
                if (completed.compareAndSet(false, true)) {
                    try {
                        callback(result)
                    } catch (error: Throwable) {
                        onCallbackError(error)
                    } finally {
                        queueComplete()
                    }
                }
            }

            try {
                start(complete)
            } catch (error: Throwable) {
                complete(Result.failure(error))
            }
        }
    }
}

internal object GeofenceMutationQueues {
    private val lock = Object()
    private val queues = WeakHashMap<Context, GeofenceMutationQueue>()

    fun forContext(
        context: Context,
        onUnhandledError: (Throwable) -> Unit = {}
    ): GeofenceMutationQueue {
        val applicationContext = context.applicationContext
        return synchronized(lock) {
            queues.getOrPut(applicationContext) {
                GeofenceMutationQueue(
                    dispatch = { operation ->
                        Handler(Looper.getMainLooper()).post(operation)
                    },
                    onUnhandledError = onUnhandledError
                )
            }
        }
    }
}
