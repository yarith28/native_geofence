package com.chunkytofustudios.native_geofence.util

import java.util.concurrent.atomic.AtomicBoolean

internal enum class CallbackEnqueueOutcome {
    ACCEPTED,
    REJECTED,
    UNCONFIRMED
}

internal fun interface CallbackEnqueueOperation {
    fun observe(completion: (Result<Unit>) -> Unit)
}

internal class CallbackEnqueueUnconfirmedException(cause: Throwable) :
    RuntimeException("Callback enqueue acceptance is ambiguous.", cause)

/**
 * Separates definitive enqueue rejection from ambiguous observation failures so
 * a payload is never deleted while WorkManager may already own its request.
 */
internal class CallbackWorkEnqueueCoordinator(
    private val deletePayload: (String) -> Boolean
) {
    fun enqueue(
        payloadReference: String,
        start: () -> CallbackEnqueueOperation,
        completion: (CallbackEnqueueOutcome) -> Unit
    ) {
        val completed = AtomicBoolean(false)
        fun finish(outcome: CallbackEnqueueOutcome) {
            if (completed.compareAndSet(false, true)) {
                completion(outcome)
            }
        }
        fun reject() {
            if (completed.compareAndSet(false, true)) {
                try {
                    deletePayload(payloadReference)
                } finally {
                    completion(CallbackEnqueueOutcome.REJECTED)
                }
            }
        }

        val operation = try {
            start()
        } catch (_: Throwable) {
            reject()
            return
        }

        try {
            operation.observe { result ->
                if (result.isSuccess) {
                    finish(CallbackEnqueueOutcome.ACCEPTED)
                } else if (result.exceptionOrNull() is CallbackEnqueueUnconfirmedException) {
                    finish(CallbackEnqueueOutcome.UNCONFIRMED)
                } else {
                    reject()
                }
            }
        } catch (_: Throwable) {
            // Enqueue may already have succeeded. Retain the durable payload so
            // a possibly-owned WorkRequest can still deliver it.
            finish(CallbackEnqueueOutcome.UNCONFIRMED)
        }
    }
}
