package com.chunkytofustudios.native_geofence.receivers

import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode
import java.util.concurrent.TimeUnit

internal enum class RecoveryRetryStep {
    DONE,
    GIVE_UP,
    WAIT_FOR_LOCATION,
    WAIT_FOR_PERMISSION,
    RECOVER
}

internal data class RecoveryRetryTicket(
    val generation: Long,
    val attempt: Int
)

internal class GeofenceRecoveryBatchIncompleteException :
    RuntimeException("Android geofence recovery has more work in the next bounded batch.")

internal class GeofenceRecoveryCancelledException :
    RuntimeException("Android geofence recovery was cancelled.")

internal enum class RecoveryOperationAdmission {
    START,
    BATCH_EXHAUSTED,
    CANCELLED,
}

/**
 * Owns the cooperative cancellation check and the per-worker platform-operation
 * budget. An admission is consumed before any durable preparation for that
 * platform operation, so a stopped worker cannot begin another mutation.
 */
internal class NativeGeofenceRecoveryOperationBudget(
    private val maxOperations: Int,
    private val shouldContinue: () -> Boolean,
) {
    init {
        require(maxOperations > 0) { "Recovery operation budget must be positive." }
    }

    var startedOperations: Int = 0
        private set

    fun admitNext(): RecoveryOperationAdmission = when {
        !shouldContinue() -> RecoveryOperationAdmission.CANCELLED
        startedOperations >= maxOperations -> RecoveryOperationAdmission.BATCH_EXHAUSTED
        else -> {
            startedOperations += 1
            RecoveryOperationAdmission.START
        }
    }

    fun isCancelled(): Boolean = !shouldContinue()
}

internal object NativeGeofenceRecoveryProgressPolicy {
    fun shouldProcess(id: String, completedIds: Set<String>): Boolean = id !in completedIds
}

internal enum class RecoveryWorkerTerminalOutcome(
    val succeeded: Boolean,
    val storageName: String
) {
    COMPLETED(true, "completed"),
    NON_RETRYABLE_FAILURE(false, "non_retryable_failure"),
    PERMISSION_WAIT(false, "permission_wait"),
    GAVE_UP(false, "gave_up"),
    RETRY_SCHEDULE_FAILED(false, "retry_schedule_failed"),
    STALE_GENERATION(false, "stale_generation")
}

internal object NativeGeofenceRecoveryPolicy {
    const val MAX_ATTEMPTS = 14
    const val MAX_OPERATIONS_PER_WORKER_BATCH = 10

    fun retryDelayMillis(attempt: Int): Long {
        val delayMinutes = when (attempt) {
            1 -> 4L
            2 -> 8L
            3 -> 16L
            4 -> 32L
            else -> 60L
        }
        return TimeUnit.MINUTES.toMillis(delayMinutes)
    }

    fun retryStep(
        attempt: Int,
        hasPluginOwnedIds: Boolean,
        locationEnabled: Boolean,
        requiredPermissionsGranted: Boolean
    ): RecoveryRetryStep = when {
        !hasPluginOwnedIds -> RecoveryRetryStep.DONE
        attempt > MAX_ATTEMPTS -> RecoveryRetryStep.GIVE_UP
        !requiredPermissionsGranted -> RecoveryRetryStep.WAIT_FOR_PERMISSION
        !locationEnabled -> RecoveryRetryStep.WAIT_FOR_LOCATION
        else -> RecoveryRetryStep.RECOVER
    }

    fun isRetryable(error: Throwable): Boolean {
        if (error is GeofenceRecoveryAggregateException) {
            return error.retryable
        }
        val flutterError = error as? FlutterError ?: return true
        val terminalCodes = setOf(
            NativeGeofenceErrorCode.INVALID_ARGUMENTS.raw.toString(),
            NativeGeofenceErrorCode.ANDROID_MANIFEST_COMPONENT_MISSING.raw.toString(),
            NativeGeofenceErrorCode.MISSING_LOCATION_PERMISSION.raw.toString(),
            NativeGeofenceErrorCode.MISSING_BACKGROUND_LOCATION_PERMISSION.raw.toString()
        )
        return flutterError.code !in terminalCodes
    }
}

internal object NativeGeofenceRecoverySchedulePolicy {
    fun shouldSchedule(
        currentGeneration: Long,
        scheduled: RecoveryRetryTicket?,
        requested: RecoveryRetryTicket
    ): Boolean {
        if (
            requested.generation != currentGeneration ||
            requested.attempt !in 1..NativeGeofenceRecoveryPolicy.MAX_ATTEMPTS
        ) {
            return false
        }
        return if (scheduled == null) {
            requested.attempt == 1
        } else {
            scheduled.generation == requested.generation &&
                requested.attempt == scheduled.attempt + 1
        }
    }

    fun shouldRunWorker(
        scheduled: RecoveryRetryTicket?,
        worker: RecoveryRetryTicket
    ): Boolean = scheduled == worker

    fun mayPublishTerminal(
        currentGeneration: Long,
        scheduled: RecoveryRetryTicket?,
        worker: RecoveryRetryTicket
    ): Boolean = currentGeneration == worker.generation && scheduled == worker
}
