package com.chunkytofustudios.native_geofence.util

import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Task

internal const val PLAY_SERVICES_GEOFENCE_MUTATION_TIMEOUT_MILLIS = 30_000L

internal enum class AndroidGeofenceMutationKind(val label: String) {
    REGISTRATION("registration"),
    REMOVAL("removal")
}

internal class AndroidGeofenceMutationTimeoutException(
    val kind: AndroidGeofenceMutationKind
) : RuntimeException(
    "Google Play services did not confirm the geofence ${kind.label} within " +
        "${PLAY_SERVICES_GEOFENCE_MUTATION_TIMEOUT_MILLIS / 1_000} seconds."
)

/** One-shot listener authority shared by success, failure, and timeout routes. */
internal class PlayServicesGeofenceMutationDeadline(
    private val timeoutMillis: Long,
    private val schedule: (Long, () -> Unit) -> (() -> Unit),
    private val timeoutError: (AndroidGeofenceMutationKind) -> Throwable =
        ::AndroidGeofenceMutationTimeoutException
) {
    fun attach(
        kind: AndroidGeofenceMutationKind,
        onSuccess: () -> Unit,
        onFailure: (Throwable) -> Unit,
        attachListeners: (() -> Unit, (Throwable) -> Unit) -> Unit
    ) {
        val gate = DeadlineGate(
            timeoutMillis = timeoutMillis,
            schedule = schedule,
            onTimeout = { onFailure(timeoutError(kind)) }
        )
        try {
            attachListeners(
                { gate.resolve(onSuccess) },
                { error -> gate.resolve { onFailure(error) } }
            )
        } catch (error: Throwable) {
            gate.abandon()
            throw error
        }
    }

    private class DeadlineGate(
        timeoutMillis: Long,
        schedule: (Long, () -> Unit) -> (() -> Unit),
        onTimeout: () -> Unit
    ) {
        private val lock = Object()
        private var open = true
        private var cancelTimeout: () -> Unit = {}

        init {
            val cancel = schedule(timeoutMillis) { resolve(onTimeout) }
            val cancelImmediately = synchronized(lock) {
                if (open) {
                    cancelTimeout = cancel
                    false
                } else {
                    true
                }
            }
            if (cancelImmediately) cancel()
        }

        fun resolve(action: () -> Unit): Boolean = close(action)

        fun abandon(): Boolean = close(null)

        private fun close(action: (() -> Unit)?): Boolean {
            val cancel = synchronized(lock) {
                if (!open) return false
                open = false
                cancelTimeout.also { cancelTimeout = {} }
            }
            cancel()
            action?.invoke()
            return true
        }
    }
}

private object PlayServicesGeofenceMutationDeadlines {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val deadline = PlayServicesGeofenceMutationDeadline(
        timeoutMillis = PLAY_SERVICES_GEOFENCE_MUTATION_TIMEOUT_MILLIS,
        schedule = { delayMillis, action ->
            val runnable = Runnable(action)
            mainHandler.postDelayed(runnable, delayMillis)
            val cancel: () -> Unit = { mainHandler.removeCallbacks(runnable) }
            cancel
        }
    )

    fun attach(
        kind: AndroidGeofenceMutationKind,
        onSuccess: () -> Unit,
        onFailure: (Throwable) -> Unit,
        attachListeners: (() -> Unit, (Throwable) -> Unit) -> Unit
    ) {
        deadline.attach(kind, onSuccess, onFailure, attachListeners)
    }
}

internal fun Task<Void>.attachWithGeofenceMutationDeadline(
    kind: AndroidGeofenceMutationKind,
    onSuccess: () -> Unit,
    onFailure: (Throwable) -> Unit
) {
    PlayServicesGeofenceMutationDeadlines.attach(
        kind = kind,
        onSuccess = onSuccess,
        onFailure = onFailure,
        attachListeners = { success, failure ->
            addOnSuccessListener { success() }
            addOnFailureListener(failure)
        }
    )
}
