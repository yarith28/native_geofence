package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.NativeGeofenceBackgroundWorker
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal enum class DeferredGeofenceCallbackTransferScheduleOutcome {
    ACCEPTED,
    REJECTED,
    UNCONFIRMED,
}

/**
 * Moves callback-refresh persistence retries out of the ordered callback chain.
 *
 * The original payload remains the single durable body. The transfer worker
 * retries that same reference until the deferred queue accepts ownership, while
 * unrelated callbacks can continue through their normal unique-work chain.
 */
internal object DeferredGeofenceCallbackTransferScheduler {
    fun schedule(
        context: Context,
        payloadReference: String,
        deliverySpec: NativeGeofenceCallbackDeliverySpec,
        completion: (DeferredGeofenceCallbackTransferScheduleOutcome) -> Unit,
    ) {
        val completed = AtomicBoolean(false)
        fun finish(outcome: DeferredGeofenceCallbackTransferScheduleOutcome) {
            if (completed.compareAndSet(false, true)) completion(outcome)
        }
        val operation = try {
            val request = OneTimeWorkRequestBuilder<NativeGeofenceBackgroundWorker>()
                .setInputData(
                    callbackWorkerInputData(
                        payloadReference = payloadReference,
                        deliverySpec = deliverySpec,
                        callbackRefreshTransfer = true,
                    )
                )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30L, TimeUnit.SECONDS)
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                Constants.CALLBACK_REFRESH_TRANSFER_WORK_PREFIX + payloadReference,
                ExistingWorkPolicy.KEEP,
                request,
            )
        } catch (_: Throwable) {
            finish(DeferredGeofenceCallbackTransferScheduleOutcome.REJECTED)
            return
        }
        try {
            val future = operation.result
            future.addListener(
                {
                    try {
                        future.get()
                        finish(DeferredGeofenceCallbackTransferScheduleOutcome.ACCEPTED)
                    } catch (error: InterruptedException) {
                        Thread.currentThread().interrupt()
                        finish(DeferredGeofenceCallbackTransferScheduleOutcome.UNCONFIRMED)
                    } catch (_: Throwable) {
                        finish(DeferredGeofenceCallbackTransferScheduleOutcome.REJECTED)
                    }
                },
                DIRECT_EXECUTOR,
            )
        } catch (_: Throwable) {
            finish(DeferredGeofenceCallbackTransferScheduleOutcome.UNCONFIRMED)
        }
    }

    private val DIRECT_EXECUTOR = Executor { command -> command.run() }
}
