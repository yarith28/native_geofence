package com.chunkytofustudios.native_geofence.util

import java.util.concurrent.atomic.AtomicBoolean

/**
 * Keeps durable removal intent authoritative while a Play services removal is
 * in flight. Confirmed failures restore the prior snapshot; timeouts and
 * listener-attachment failures retain cleanup evidence for reconciliation.
 */
internal class AndroidGeofenceRemovalTransaction<Snapshot>(
    private val snapshot: Snapshot,
    private val markRemovalPending: () -> Boolean,
    private val restoreSnapshot: (Snapshot) -> Boolean,
    private val beginRemoval: () -> AndroidGeofenceAsyncOperation,
    private val clearDurableState: () -> Boolean,
    private val scheduleReconciliation: () -> Unit,
    private val completion: (Result<Unit>) -> Unit,
) {
    private val completed = AtomicBoolean(false)

    fun start() {
        if (!markRemovalPending()) {
            finish(
                Result.failure(
                    IllegalStateException("Failed to persist pending geofence removal state.")
                )
            )
            return
        }

        val operation = try {
            beginRemoval()
        } catch (error: Throwable) {
            finishConfirmedFailure(error)
            return
        }

        try {
            operation.attach(
                onSuccess = ::finishSuccess,
                onFailure = { error ->
                    if (error is AndroidGeofenceMutationTimeoutException) {
                        finishUncertain(error)
                    } else {
                        finishConfirmedFailure(error)
                    }
                },
            )
        } catch (error: Throwable) {
            // Play services may already own the request when listener wiring
            // fails, so retain the pending-removal marker.
            finishUncertain(error)
        }
    }

    private fun finishSuccess() {
        if (!completed.compareAndSet(false, true)) return
        if (clearDurableState()) {
            completion(Result.success(Unit))
            return
        }
        completion(
            Result.failure(
                IllegalStateException(
                    "Play services removed the geofence, but durable pending " +
                        "removal state could not be cleared."
                )
            )
        )
        scheduleReconciliation()
    }

    private fun finishConfirmedFailure(error: Throwable) {
        if (!completed.compareAndSet(false, true)) return
        if (restoreSnapshot(snapshot)) {
            completion(Result.failure(error))
            return
        }
        completion(
            Result.failure(
                IllegalStateException(
                    "Geofence removal failed and its prior durable state could not be restored.",
                    error,
                )
            )
        )
        scheduleReconciliation()
    }

    private fun finishUncertain(error: Throwable) {
        if (!completed.compareAndSet(false, true)) return
        completion(Result.failure(error))
        scheduleReconciliation()
    }

    private fun finish(result: Result<Unit>) {
        if (completed.compareAndSet(false, true)) completion(result)
    }
}
