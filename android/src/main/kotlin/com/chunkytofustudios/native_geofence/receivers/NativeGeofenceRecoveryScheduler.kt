package com.chunkytofustudios.native_geofence.receivers

import android.content.Context
import android.content.SharedPreferences
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.NativeGeofenceRecoveryWorker
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal enum class RecoveryScheduleOutcome {
    CONFIRMED,
    REJECTED,
    UNCONFIRMED
}

internal object NativeGeofenceRecoveryScheduler {
    private val lock = Object()
    private val directExecutor = Executor { command -> command.run() }

    fun beginGeneration(context: Context): Long = synchronized(lock) {
        val preferences = preferences(context)
        val current = preferences.getLong(Constants.RECOVERY_GENERATION_KEY, 0L)
        val next = if (current == Long.MAX_VALUE) 1L else current + 1L
        check(
            preferences.edit()
                .putLong(Constants.RECOVERY_GENERATION_KEY, next)
                .remove(Constants.RECOVERY_SCHEDULED_GENERATION_KEY)
                .remove(Constants.RECOVERY_SCHEDULED_ATTEMPT_KEY)
                .commit()
        ) { "Failed to persist a geofence recovery generation." }
        WorkManager.getInstance(context.applicationContext)
            .cancelUniqueWork(Constants.RECOVERY_RETRY_WORK_NAME)
        next
    }

    fun currentGeneration(context: Context): Long =
        preferences(context).getLong(Constants.RECOVERY_GENERATION_KEY, 0L)

    fun isCurrentTicket(context: Context, generation: Long, attempt: Int): Boolean =
        synchronized(lock) {
            NativeGeofenceRecoverySchedulePolicy.shouldRunWorker(
                scheduled = scheduledTicket(preferences(context)),
                worker = RecoveryRetryTicket(generation, attempt)
            )
        }

    fun scheduleRetry(
        context: Context,
        generation: Long,
        attempt: Int,
        reason: String,
        callback: (RecoveryScheduleOutcome) -> Unit
    ) {
        val callbackCompleted = AtomicBoolean(false)
        fun finish(outcome: RecoveryScheduleOutcome) {
            if (callbackCompleted.compareAndSet(false, true)) {
                callback(outcome)
            }
        }

        synchronized(lock) {
            val preferences = preferences(context)
            val current = preferences.getLong(Constants.RECOVERY_GENERATION_KEY, 0L)
            val previous = scheduledTicket(preferences)
            val requested = RecoveryRetryTicket(generation, attempt)
            if (!NativeGeofenceRecoverySchedulePolicy.shouldSchedule(current, previous, requested)) {
                finish(RecoveryScheduleOutcome.REJECTED)
                return
            }

            val recorded = preferences.edit()
                .putLong(Constants.RECOVERY_SCHEDULED_GENERATION_KEY, generation)
                .putInt(Constants.RECOVERY_SCHEDULED_ATTEMPT_KEY, attempt)
                .commit()
            if (!recorded) {
                finish(RecoveryScheduleOutcome.REJECTED)
                return
            }

            val operation = try {
                val request = OneTimeWorkRequestBuilder<NativeGeofenceRecoveryWorker>()
                    .setInputData(
                        Data.Builder()
                            .putLong(Constants.RECOVERY_RETRY_GENERATION_INPUT_KEY, generation)
                            .putInt(Constants.RECOVERY_RETRY_ATTEMPT_INPUT_KEY, attempt)
                            .putString(
                                Constants.RECOVERY_RETRY_REASON_INPUT_KEY,
                                reason.take(MAX_REASON_LENGTH)
                            )
                            .build()
                    )
                    .setInitialDelay(
                        NativeGeofenceRecoveryPolicy.retryDelayMillis(attempt),
                        TimeUnit.MILLISECONDS
                    )
                    .build()
                WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                    Constants.RECOVERY_RETRY_WORK_NAME,
                    if (attempt == 1) {
                        ExistingWorkPolicy.REPLACE
                    } else {
                        ExistingWorkPolicy.APPEND_OR_REPLACE
                    },
                    request
                )
            } catch (_: RuntimeException) {
                restorePreviousTicketIfCurrent(preferences, requested, previous)
                finish(RecoveryScheduleOutcome.REJECTED)
                return
            }

            val future = try {
                operation.result
            } catch (_: RuntimeException) {
                // WorkManager may already own the request. Retain the exact
                // persisted ticket so a matching worker can still be admitted.
                finish(RecoveryScheduleOutcome.UNCONFIRMED)
                return
            }
            try {
                future.addListener(
                    {
                        try {
                            future.get()
                            finish(RecoveryScheduleOutcome.CONFIRMED)
                        } catch (_: Throwable) {
                            synchronized(lock) {
                                restorePreviousTicketIfCurrent(
                                    preferences(context),
                                    requested,
                                    previous
                                )
                            }
                            finish(RecoveryScheduleOutcome.REJECTED)
                        }
                    },
                    directExecutor
                )
            } catch (_: RuntimeException) {
                // Listener registration is ambiguous: retain the ticket and do
                // not run immediate recovery without confirmed retry ownership.
                finish(RecoveryScheduleOutcome.UNCONFIRMED)
            }
        }
    }

    fun completeGeneration(context: Context, generation: Long): Boolean {
        val cleared = synchronized(lock) {
            val preferences = preferences(context)
            if (preferences.getLong(Constants.RECOVERY_GENERATION_KEY, 0L) != generation) {
                return false
            }
            preferences.edit()
                .remove(Constants.RECOVERY_SCHEDULED_GENERATION_KEY)
                .remove(Constants.RECOVERY_SCHEDULED_ATTEMPT_KEY)
                .commit()
        }
        if (cleared) {
            WorkManager.getInstance(context.applicationContext)
                .cancelUniqueWork(Constants.RECOVERY_RETRY_WORK_NAME)
        }
        return cleared
    }

    /**
     * Publishes and completes a worker terminal outcome while the exact durable
     * generation/attempt ticket still owns the recovery lifecycle.
     */
    fun completeWorkerTicket(
        context: Context,
        worker: RecoveryRetryTicket,
        recordTerminal: () -> Unit
    ): Boolean {
        val cleared = synchronized(lock) {
            val preferences = preferences(context)
            val currentGeneration = preferences.getLong(
                Constants.RECOVERY_GENERATION_KEY,
                0L
            )
            if (
                !NativeGeofenceRecoverySchedulePolicy.mayPublishTerminal(
                    currentGeneration = currentGeneration,
                    scheduled = scheduledTicket(preferences),
                    worker = worker
                )
            ) {
                return false
            }
            recordTerminal()
            preferences.edit()
                .remove(Constants.RECOVERY_SCHEDULED_GENERATION_KEY)
                .remove(Constants.RECOVERY_SCHEDULED_ATTEMPT_KEY)
                .commit()
        }
        if (cleared) {
            WorkManager.getInstance(context.applicationContext)
                .cancelUniqueWork(Constants.RECOVERY_RETRY_WORK_NAME)
        }
        return cleared
    }

    private fun scheduledTicket(preferences: SharedPreferences): RecoveryRetryTicket? {
        if (
            !preferences.contains(Constants.RECOVERY_SCHEDULED_GENERATION_KEY) ||
            !preferences.contains(Constants.RECOVERY_SCHEDULED_ATTEMPT_KEY)
        ) {
            return null
        }
        return RecoveryRetryTicket(
            preferences.getLong(Constants.RECOVERY_SCHEDULED_GENERATION_KEY, 0L),
            preferences.getInt(Constants.RECOVERY_SCHEDULED_ATTEMPT_KEY, 0)
        )
    }

    private fun restorePreviousTicketIfCurrent(
        preferences: SharedPreferences,
        requested: RecoveryRetryTicket,
        previous: RecoveryRetryTicket?
    ) {
        if (scheduledTicket(preferences) != requested) {
            return
        }
        val editor = preferences.edit()
        if (previous == null) {
            editor.remove(Constants.RECOVERY_SCHEDULED_GENERATION_KEY)
            editor.remove(Constants.RECOVERY_SCHEDULED_ATTEMPT_KEY)
        } else {
            editor.putLong(Constants.RECOVERY_SCHEDULED_GENERATION_KEY, previous.generation)
            editor.putInt(Constants.RECOVERY_SCHEDULED_ATTEMPT_KEY, previous.attempt)
        }
        editor.commit()
    }

    private fun preferences(context: Context) = context.applicationContext.getSharedPreferences(
        Constants.SHARED_PREFERENCES_KEY,
        Context.MODE_PRIVATE
    )

    private const val MAX_REASON_LENGTH = 160
}
