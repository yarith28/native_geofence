package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.NativeGeofenceBackgroundWorker
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.util.AndroidPackageFingerprint
import com.chunkytofustudios.native_geofence.util.CallbackEnqueueOperation
import com.chunkytofustudios.native_geofence.util.CallbackEnqueueOutcome
import com.chunkytofustudios.native_geofence.util.CallbackEnqueueUnconfirmedException
import com.chunkytofustudios.native_geofence.util.CallbackWorkEnqueueCoordinator
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackPayloadStore
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnosticStage
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceIo
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Authoritative enqueue outcome for a callback payload handed to native_geofence. */
enum class NativeGeofenceCallbackEnqueueResult {
    /** WorkManager durably accepted the request. */
    ACCEPTED,

    /** WorkManager definitively rejected the request and the payload was deleted. */
    REJECTED,

    /** Acceptance could not be observed; the durable payload was retained. */
    UNCONFIRMED,
}

internal fun CallbackEnqueueOutcome.toPublicEnqueueResult():
    NativeGeofenceCallbackEnqueueResult = when (this) {
    CallbackEnqueueOutcome.ACCEPTED -> NativeGeofenceCallbackEnqueueResult.ACCEPTED
    CallbackEnqueueOutcome.REJECTED -> NativeGeofenceCallbackEnqueueResult.REJECTED
    CallbackEnqueueOutcome.UNCONFIRMED -> NativeGeofenceCallbackEnqueueResult.UNCONFIRMED
}

internal class NativeGeofenceCallbackCompletion(
    private val completion: (NativeGeofenceCallbackEnqueueResult) -> Unit,
) {
    private val resolved = AtomicBoolean(false)

    fun complete(result: NativeGeofenceCallbackEnqueueResult) {
        if (resolved.compareAndSet(false, true)) completion(result)
    }
}

/**
 * Stable Android delivery boundary for higher-level geofence coordinators.
 *
 * The payload is persisted before WorkManager enqueueing. Callers must treat
 * [NativeGeofenceCallbackEnqueueResult.UNCONFIRMED] as ownership transferred:
 * retrying could duplicate work that WorkManager already accepted.
 */
object NativeGeofenceCallbackDelivery {
    @JvmStatic
    fun enqueue(
        context: Context,
        params: GeofenceCallbackParamsWire,
        completion: (NativeGeofenceCallbackEnqueueResult) -> Unit,
    ) {
        val guardedCompletion = NativeGeofenceCallbackCompletion(completion)
        val appContext = context.applicationContext
        val identified = if (params.eventId.isNullOrBlank()) {
            params.copy(eventId = UUID.randomUUID().toString())
        } else {
            params
        }
        try {
            NativeGeofenceIo.execute {
                try {
                    enqueuePersisted(appContext, identified, guardedCompletion::complete)
                } catch (error: Throwable) {
                    guardedCompletion.complete(NativeGeofenceCallbackEnqueueResult.REJECTED)
                    logError(appContext, "Callback enqueueing failed unexpectedly.", error)
                }
            }
        } catch (error: Throwable) {
            guardedCompletion.complete(NativeGeofenceCallbackEnqueueResult.REJECTED)
            logError(appContext, "Failed to dispatch callback enqueueing.", error)
        }
    }

    private fun enqueuePersisted(
        context: Context,
        params: GeofenceCallbackParamsWire,
        completion: (NativeGeofenceCallbackEnqueueResult) -> Unit,
    ) {
        val packageFingerprint: String
        val payloadStore: GeofenceCallbackPayloadStore
        try {
            packageFingerprint = AndroidPackageFingerprint.current(context)
            payloadStore = GeofenceCallbackPayloadStore.forContext(context)
        } catch (error: Throwable) {
            completion(NativeGeofenceCallbackEnqueueResult.REJECTED)
            logError(context, "Failed to prepare durable callback enqueueing.", error)
            return
        }

        val reference = try {
            payloadStore.store(params, packageFingerprint)
        } catch (error: Throwable) {
            logError(context, "Failed to persist a callback payload.", error)
            null
        }
        if (reference == null) {
            completion(NativeGeofenceCallbackEnqueueResult.REJECTED)
            runCatching {
                NativeGeofenceDiagnostics.record(
                    context,
                    NativeGeofenceDiagnosticStage.ENQUEUE,
                    succeeded = false,
                    outcome = "payload_persistence_failed",
                    geofenceCount = params.geofences.size,
                )
            }
            return
        }

        CallbackWorkEnqueueCoordinator(payloadStore::delete).enqueue(
            payloadReference = reference,
            start = {
                val workRequest = OneTimeWorkRequestBuilder<NativeGeofenceBackgroundWorker>()
                    .setInputData(
                        Data.Builder()
                            .putString(Constants.WORKER_PAYLOAD_REFERENCE_KEY, reference)
                            .build(),
                    )
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30L, TimeUnit.SECONDS)
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .build()
                val operation = WorkManager.getInstance(context).enqueueUniqueWork(
                    Constants.GEOFENCE_CALLBACK_WORK_GROUP,
                    ExistingWorkPolicy.APPEND_OR_REPLACE,
                    workRequest,
                )
                CallbackEnqueueOperation { observed ->
                    val future = operation.result
                    future.addListener(
                        {
                            try {
                                future.get()
                                observed(Result.success(Unit))
                            } catch (error: InterruptedException) {
                                Thread.currentThread().interrupt()
                                observed(
                                    Result.failure(CallbackEnqueueUnconfirmedException(error)),
                                )
                            } catch (error: Throwable) {
                                observed(Result.failure(error))
                            }
                        },
                        DIRECT_EXECUTOR,
                    )
                }
            },
        ) { outcome ->
            val result = outcome.toPublicEnqueueResult()
            completion(result)
            runCatching { recordOutcome(context, params, result) }
        }
    }

    private fun recordOutcome(
        context: Context,
        params: GeofenceCallbackParamsWire,
        result: NativeGeofenceCallbackEnqueueResult,
    ) {
        val succeeded = result == NativeGeofenceCallbackEnqueueResult.ACCEPTED
        val outcome = when (result) {
            NativeGeofenceCallbackEnqueueResult.ACCEPTED -> "work_enqueue_confirmed"
            NativeGeofenceCallbackEnqueueResult.REJECTED -> "work_enqueue_failed"
            NativeGeofenceCallbackEnqueueResult.UNCONFIRMED -> "work_enqueue_unconfirmed"
        }
        NativeGeofenceDiagnostics.record(
            context,
            NativeGeofenceDiagnosticStage.ENQUEUE,
            succeeded = succeeded,
            outcome = outcome,
            geofenceCount = params.geofences.size,
        )
        when (result) {
            NativeGeofenceCallbackEnqueueResult.ACCEPTED ->
                NativeGeofenceLogger.d(context, TAG, "Callback work enqueue was confirmed.")
            NativeGeofenceCallbackEnqueueResult.REJECTED ->
                NativeGeofenceLogger.e(context, TAG, "Callback work enqueue was rejected.")
            NativeGeofenceCallbackEnqueueResult.UNCONFIRMED -> NativeGeofenceLogger.w(
                context,
                TAG,
                "Callback work enqueue could not be confirmed; payload retained.",
            )
        }
    }

    private const val TAG = "NativeGeofenceCallbackDelivery"
    private val DIRECT_EXECUTOR = Executor { command -> command.run() }

    private fun logError(context: Context, message: String, error: Throwable) {
        runCatching { NativeGeofenceLogger.e(context, TAG, message, error) }
    }
}
