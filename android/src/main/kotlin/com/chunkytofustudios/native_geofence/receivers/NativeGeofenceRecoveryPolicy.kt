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

internal object NativeGeofenceRecoveryPolicy {
    const val MAX_ATTEMPTS = 14

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
}
