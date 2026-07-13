package com.chunkytofustudios.native_geofence

import android.content.Context
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.chunkytofustudios.native_geofence.api.NativeGeofenceApiImpl
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceRecoveryPolicy
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceRecoveryScheduler
import com.chunkytofustudios.native_geofence.receivers.RecoveryScheduleOutcome
import com.chunkytofustudios.native_geofence.receivers.RecoveryRetryStep
import com.chunkytofustudios.native_geofence.util.LocationState
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.atomic.AtomicBoolean

class NativeGeofenceRecoveryWorker(
    private val context: Context,
    private val workerParameters: WorkerParameters
) : ListenableWorker(context, workerParameters) {
    private val stopped = AtomicBoolean(false)

    override fun startWork(): ListenableFuture<Result> = CallbackToFutureAdapter.getFuture { completer ->
        val completed = AtomicBoolean(false)
        fun finish(result: Result) {
            if (completed.compareAndSet(false, true) && !stopped.get()) {
                completer.set(result)
            }
        }

        val generation = workerParameters.inputData.getLong(
            Constants.RECOVERY_RETRY_GENERATION_INPUT_KEY,
            0L
        )
        val attempt = workerParameters.inputData.getInt(
            Constants.RECOVERY_RETRY_ATTEMPT_INPUT_KEY,
            0
        )
        val reason = workerParameters.inputData.getString(
            Constants.RECOVERY_RETRY_REASON_INPUT_KEY
        ) ?: "recovery_retry"

        if (!NativeGeofenceRecoveryScheduler.isCurrentTicket(context, generation, attempt)) {
            finish(Result.success())
            return@getFuture TAG
        }

        val hasPluginOwnedIds = NativeGeofencePersistence.getAllRawGeofenceIds(context).isNotEmpty()
        val step = NativeGeofenceRecoveryPolicy.retryStep(
            attempt = attempt,
            hasPluginOwnedIds = hasPluginOwnedIds,
            locationEnabled = LocationState.isEnabled(context),
            requiredPermissionsGranted = LocationState.hasRequiredPermissions(context)
        )
        NativeGeofenceLogger.d(
            context,
            TAG,
            "Recovery retry generation=$generation attempt=$attempt step=$step."
        )

        when (step) {
            RecoveryRetryStep.DONE -> {
                NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
                finish(Result.success())
            }
            RecoveryRetryStep.GIVE_UP -> {
                NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
                finish(Result.failure())
            }
            RecoveryRetryStep.WAIT_FOR_PERMISSION -> {
                NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
                finish(Result.success())
            }
            RecoveryRetryStep.WAIT_FOR_LOCATION -> {
                scheduleNext(generation, attempt, reason, ::finish)
            }
            RecoveryRetryStep.RECOVER -> {
                NativeGeofenceApiImpl(context).recoverForGeneration(
                    generation = generation,
                    reason = "$reason:attempt=$attempt"
                ) { recoveryResult ->
                    if (generation != NativeGeofenceRecoveryScheduler.currentGeneration(context)) {
                        finish(Result.success())
                    } else if (recoveryResult.isSuccess) {
                        NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
                        finish(Result.success())
                    } else {
                        val error = recoveryResult.exceptionOrNull()
                        if (error != null && NativeGeofenceRecoveryPolicy.isRetryable(error)) {
                            scheduleNext(generation, attempt, reason, ::finish)
                        } else {
                            NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
                            finish(Result.failure())
                        }
                    }
                }
            }
        }
        TAG
    }

    override fun onStopped() {
        stopped.set(true)
    }

    private fun scheduleNext(
        generation: Long,
        attempt: Int,
        reason: String,
        finish: (Result) -> Unit
    ) {
        val nextAttempt = attempt + 1
        if (nextAttempt > NativeGeofenceRecoveryPolicy.MAX_ATTEMPTS) {
            NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
            finish(Result.failure())
            return
        }
        NativeGeofenceRecoveryScheduler.scheduleRetry(
            context,
            generation,
            nextAttempt,
            reason
        ) { outcome ->
            when (outcome) {
                RecoveryScheduleOutcome.CONFIRMED -> finish(Result.success())
                RecoveryScheduleOutcome.UNCONFIRMED -> {
                    // The next request may already belong to WorkManager. The
                    // exact persisted ticket prevents any unrelated worker.
                    finish(Result.success())
                }
                RecoveryScheduleOutcome.REJECTED -> {
                    NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
                    finish(Result.failure())
                }
            }
        }
    }

    private companion object {
        const val TAG = "NativeGeofenceRecoveryWorker"
    }
}
