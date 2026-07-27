package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import androidx.work.ExistingWorkPolicy
import androidx.work.WorkManager
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackPayloadStore
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnosticStage
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceIo
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.RecoverableCallbackPayload
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

internal data class CallbackPayloadRecoverySpec(
    val reference: String,
    val workRequestId: UUID,
    val deliverySpec: NativeGeofenceCallbackDeliverySpec,
)

internal object CallbackPayloadRecoveryPlanner {
    fun makeSpec(payload: RecoverableCallbackPayload): CallbackPayloadRecoverySpec? {
        val persistedWorkRequestId = payload.envelope.workRequestId ?: return null
        val workRequestId = runCatching {
            UUID.fromString(persistedWorkRequestId)
        }.getOrNull() ?: return null
        if (workRequestId.toString() != payload.reference) return null
        val route = NativeGeofenceCallbackRoute.entries.firstOrNull {
            it.storageValue == payload.envelope.deliveryRoute
        } ?: return null
        return CallbackPayloadRecoverySpec(
            reference = payload.reference,
            workRequestId = workRequestId,
            deliverySpec = NativeGeofenceCallbackDeliverySpec(
                route = route,
                source = payload.envelope.deliverySource,
            ),
        )
    }
}

/**
 * Reconciles durable payloads whose WorkManager enqueue acceptance was never
 * observed. Stable WorkRequest IDs make the lookup exact: existing work keeps
 * ownership, while an absent request is appended to the ordered callback chain.
 */
internal object CallbackPayloadEnqueueRecovery {
    private class RecoveryPass {
        val finished = AtomicBoolean(false)
    }

    private val running = AtomicBoolean(false)
    private val requested = AtomicBoolean(false)
    private val directExecutor = Executor { command -> command.run() }

    fun recover(context: Context) {
        val appContext = context.applicationContext
        requested.set(true)
        if (!running.compareAndSet(false, true)) return
        startPass(appContext, RecoveryPass())
    }

    private fun startPass(context: Context, pass: RecoveryPass) {
        requested.set(false)
        try {
            NativeGeofenceIo.execute {
                if (pass.finished.get()) return@execute
                val payloads = GeofenceCallbackPayloadStore.forContext(context)
                    .recoverablePayloads()
                    .getOrElse { error ->
                        failPass(
                            context,
                            pass,
                            "Failed to enumerate durable callback payloads.",
                            error,
                        )
                        return@execute
                    }
                recoverAt(
                    context = context,
                    pass = pass,
                    payloads = payloads.mapNotNull(
                        CallbackPayloadRecoveryPlanner::makeSpec,
                    ),
                    index = 0,
                )
            }
        } catch (error: Throwable) {
            failPass(context, pass, "Failed to dispatch callback recovery.", error)
        }
    }

    private fun recoverAt(
        context: Context,
        pass: RecoveryPass,
        payloads: List<CallbackPayloadRecoverySpec>,
        index: Int,
    ) {
        if (pass.finished.get()) return
        if (index >= payloads.size) {
            finishPass(context, pass)
            return
        }
        val payload = payloads[index]
        val workManager = try {
            WorkManager.getInstance(context)
        } catch (error: Throwable) {
            failPass(
                context,
                pass,
                "Failed to access WorkManager during callback recovery.",
                error,
            )
            return
        }
        val lookup = try {
            workManager.getWorkInfoById(payload.workRequestId)
        } catch (error: Throwable) {
            failPass(context, pass, "Failed to inspect callback work ownership.", error)
            return
        }
        try {
            lookup.addListener(
                {
                    val existing = try {
                        lookup.get()
                    } catch (error: Throwable) {
                        failPass(
                            context,
                            pass,
                            "Callback work ownership lookup failed.",
                            error,
                        )
                        return@addListener
                    }
                    if (pass.finished.get()) return@addListener
                    if (existing != null) {
                        recordRecovery(
                            context,
                            outcome = "callback_enqueue_recovery_already_owned",
                            succeeded = true,
                        )
                        recoverAt(context, pass, payloads, index + 1)
                        return@addListener
                    }
                    enqueueMissing(
                        context,
                        pass,
                        workManager,
                        payload,
                        payloads,
                        index,
                    )
                },
                directExecutor,
            )
        } catch (error: Throwable) {
            failPass(
                context,
                pass,
                "Callback work ownership observation failed.",
                error,
            )
        }
    }

    private fun enqueueMissing(
        context: Context,
        pass: RecoveryPass,
        workManager: WorkManager,
        payload: CallbackPayloadRecoverySpec,
        payloads: List<CallbackPayloadRecoverySpec>,
        index: Int,
    ) {
        val operation = try {
            workManager.enqueueUniqueWork(
                Constants.GEOFENCE_CALLBACK_WORK_GROUP,
                ExistingWorkPolicy.APPEND_OR_REPLACE,
                callbackWorkRequest(payload.reference, payload.deliverySpec),
            )
        } catch (error: Throwable) {
            failPass(context, pass, "Failed to recover unowned callback work.", error)
            return
        }
        val result = try {
            operation.result
        } catch (error: Throwable) {
            // The request may have committed. Keep the payload and let the next
            // lifecycle or Core Location wake reconcile the stable ID again.
            failPass(
                context,
                pass,
                "Callback recovery enqueue ownership is ambiguous.",
                error,
            )
            return
        }
        try {
            result.addListener(
                {
                    try {
                        result.get()
                        if (pass.finished.get()) return@addListener
                        recordRecovery(
                            context,
                            outcome = "callback_enqueue_recovered",
                            succeeded = true,
                        )
                        recoverAt(context, pass, payloads, index + 1)
                    } catch (error: Throwable) {
                        failPass(
                            context,
                            pass,
                            "Callback recovery enqueue failed.",
                            error,
                        )
                    }
                },
                directExecutor,
            )
        } catch (error: Throwable) {
            failPass(
                context,
                pass,
                "Callback recovery enqueue observation is ambiguous.",
                error,
            )
        }
    }

    private fun failPass(
        context: Context,
        pass: RecoveryPass,
        message: String,
        error: Throwable,
    ) {
        if (!pass.finished.compareAndSet(false, true)) return
        runCatching { NativeGeofenceLogger.w(context, TAG, message, error) }
        recordRecovery(
            context,
            outcome = "callback_enqueue_recovery_deferred",
            succeeded = false,
        )
        finishPassAfterClaim(context)
    }

    private fun recordRecovery(
        context: Context,
        outcome: String,
        succeeded: Boolean,
    ) {
        runCatching {
            NativeGeofenceDiagnostics.record(
                context,
                NativeGeofenceDiagnosticStage.ENQUEUE,
                succeeded = succeeded,
                outcome = outcome,
            )
        }
    }

    private fun finishPass(context: Context, pass: RecoveryPass) {
        if (!pass.finished.compareAndSet(false, true)) return
        finishPassAfterClaim(context)
    }

    private fun finishPassAfterClaim(context: Context) {
        running.set(false)
        if (requested.get()) recover(context)
    }

    private const val TAG = "CallbackPayloadRecovery"
}
