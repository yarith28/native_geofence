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
import com.chunkytofustudios.native_geofence.receivers.RecoveryRetryTicket
import com.chunkytofustudios.native_geofence.receivers.RecoveryWorkerTerminalOutcome
import com.chunkytofustudios.native_geofence.util.LocationState
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnosticStage
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnostics
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
        val workerTicket = RecoveryRetryTicket(generation, attempt)
        val completed = AtomicBoolean(false)
        fun finish(result: Result, terminalOutcome: RecoveryWorkerTerminalOutcome? = null) {
            if (!completed.compareAndSet(false, true) || stopped.get()) {
                return
            }
            if (terminalOutcome != null) {
                NativeGeofenceRecoveryScheduler.completeWorkerTicket(
                    context,
                    workerTicket,
                    recoverySatisfied = terminalOutcome.recoverySatisfied,
                ) {
                    NativeGeofenceDiagnostics.record(
                        context,
                        NativeGeofenceDiagnosticStage.RECOVERY,
                        succeeded = terminalOutcome.succeeded,
                        outcome = terminalOutcome.storageName,
                        geofenceCount = NativeGeofencePersistence
                            .getAllRawGeofenceIds(context)
                            .size
                    )
                }
            }
            completer.set(result)
        }

        if (!NativeGeofenceRecoveryScheduler.isCurrentTicket(context, generation, attempt)) {
            finish(Result.success(), RecoveryWorkerTerminalOutcome.STALE_GENERATION)
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
                finish(Result.success(), RecoveryWorkerTerminalOutcome.COMPLETED)
            }
            RecoveryRetryStep.GIVE_UP -> {
                finish(Result.failure(), RecoveryWorkerTerminalOutcome.GAVE_UP)
            }
            RecoveryRetryStep.WAIT_FOR_PERMISSION -> {
                finish(Result.success(), RecoveryWorkerTerminalOutcome.PERMISSION_WAIT)
            }
            RecoveryRetryStep.WAIT_FOR_LOCATION -> {
                scheduleNext(generation, attempt, reason, ::finish)
            }
            RecoveryRetryStep.RECOVER -> {
                NativeGeofenceApiImpl(context).recoverForGeneration(
                    generation = generation,
                    reason = "$reason:attempt=$attempt",
                    maxOperations = NativeGeofenceRecoveryPolicy
                        .MAX_OPERATIONS_PER_WORKER_BATCH,
                    shouldContinue = { !stopped.get() },
                ) { recoveryResult ->
                    if (generation != NativeGeofenceRecoveryScheduler.currentGeneration(context)) {
                        finish(Result.success(), RecoveryWorkerTerminalOutcome.STALE_GENERATION)
                    } else if (recoveryResult.isSuccess) {
                        finish(Result.success(), RecoveryWorkerTerminalOutcome.COMPLETED)
                    } else {
                        val error = recoveryResult.exceptionOrNull()
                        if (error != null && NativeGeofenceRecoveryPolicy.isRetryable(error)) {
                            scheduleNext(generation, attempt, reason, ::finish)
                        } else {
                            finish(
                                Result.failure(),
                                RecoveryWorkerTerminalOutcome.NON_RETRYABLE_FAILURE
                            )
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
        finish: (Result, RecoveryWorkerTerminalOutcome?) -> Unit
    ) {
        val nextAttempt = attempt + 1
        if (nextAttempt > NativeGeofenceRecoveryPolicy.MAX_ATTEMPTS) {
            finish(Result.failure(), RecoveryWorkerTerminalOutcome.GAVE_UP)
            return
        }
        NativeGeofenceRecoveryScheduler.scheduleRetry(
            context,
            generation,
            nextAttempt,
            reason
        ) { outcome ->
            when (outcome) {
                RecoveryScheduleOutcome.CONFIRMED -> finish(Result.success(), null)
                RecoveryScheduleOutcome.UNCONFIRMED -> {
                    // The next request may already belong to WorkManager. The
                    // exact persisted ticket prevents any unrelated worker.
                    finish(Result.success(), null)
                }
                RecoveryScheduleOutcome.REJECTED -> {
                    finish(
                        Result.failure(),
                        RecoveryWorkerTerminalOutcome.RETRY_SCHEDULE_FAILED
                    )
                }
            }
        }
    }

    private companion object {
        const val TAG = "NativeGeofenceRecoveryWorker"
    }
}
