package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode

internal enum class CallbackDeliveryFailure {
    PAYLOAD_MISSING,
    PAYLOAD_CORRUPT,
    EVENT_ID_MISSING,
    PACKAGE_STALE,
    DISPATCHER_MISSING,
    DISPATCHER_STALE,
    DISPATCHER_NOT_FOUND,
    DART_CALLBACK_NOT_FOUND,
    DART_CALLBACK_INVALID,
    INFRASTRUCTURE,
    DART_DELIVERY,
    STARTUP_TIMEOUT,
    API_READY_TIMEOUT,
    CALLBACK_TIMEOUT
}

internal enum class CallbackWorkerResult {
    SUCCESS,
    RETRY
}

internal data class CallbackDeliveryDecision(
    val workerResult: CallbackWorkerResult,
    val cleanupPayload: Boolean
)

internal object CallbackDeliveryPolicy {
    const val MAX_DELIVERY_ATTEMPTS = 4

    fun success(): CallbackDeliveryDecision =
        CallbackDeliveryDecision(CallbackWorkerResult.SUCCESS, cleanupPayload = true)

    /** The callback is durably owned by the callback-refresh queue. */
    fun deferredForCallbackRefresh(): CallbackDeliveryDecision =
        CallbackDeliveryDecision(CallbackWorkerResult.SUCCESS, cleanupPayload = true)

    /**
     * The callback-refresh queue rejected ownership. Keep the original payload
     * and retry without a terminal attempt cap so queue pressure cannot convert
     * an app-update callback into a drop.
     */
    fun callbackRefreshDeferralFailure(): CallbackDeliveryDecision =
        CallbackDeliveryDecision(CallbackWorkerResult.RETRY, cleanupPayload = false)

    /** A separate transfer worker now owns retrying the durable payload. */
    fun transferredForCallbackRefreshRetry(
        cleanupOriginalPayload: Boolean = false,
    ): CallbackDeliveryDecision = CallbackDeliveryDecision(
        CallbackWorkerResult.SUCCESS,
        cleanupPayload = cleanupOriginalPayload,
    )

    fun failure(
        failure: CallbackDeliveryFailure,
        runAttemptCount: Int
    ): CallbackDeliveryDecision {
        val retryable = failure in RETRYABLE_FAILURES
        val attemptsRemain = runAttemptCount + 1 < MAX_DELIVERY_ATTEMPTS
        return if (retryable && attemptsRemain) {
            CallbackDeliveryDecision(CallbackWorkerResult.RETRY, cleanupPayload = false)
        } else {
            // Terminal drops deliberately complete their unique-work node so a
            // bad event cannot poison every later callback in the chain.
            CallbackDeliveryDecision(CallbackWorkerResult.SUCCESS, cleanupPayload = true)
        }
    }

    fun classifyDartError(error: Throwable): CallbackDeliveryFailure {
        val code = (error as? FlutterError)?.code
        return when (code) {
            NativeGeofenceErrorCode.CALLBACK_NOT_FOUND.raw.toString() ->
                CallbackDeliveryFailure.DART_CALLBACK_NOT_FOUND
            NativeGeofenceErrorCode.CALLBACK_INVALID.raw.toString() ->
                CallbackDeliveryFailure.DART_CALLBACK_INVALID
            else -> CallbackDeliveryFailure.DART_DELIVERY
        }
    }

    fun requiresCallbackRefresh(failure: CallbackDeliveryFailure): Boolean =
        failure in CALLBACK_REFRESH_FAILURES

    fun shouldDeferForCallbackRefresh(failure: CallbackDeliveryFailure): Boolean =
        failure in CALLBACK_REFRESH_FAILURES

    private val RETRYABLE_FAILURES = setOf(
        CallbackDeliveryFailure.INFRASTRUCTURE,
        CallbackDeliveryFailure.DART_DELIVERY,
        CallbackDeliveryFailure.STARTUP_TIMEOUT,
        CallbackDeliveryFailure.API_READY_TIMEOUT,
        CallbackDeliveryFailure.CALLBACK_TIMEOUT
    )

    private val CALLBACK_REFRESH_FAILURES = setOf(
        CallbackDeliveryFailure.PACKAGE_STALE,
        CallbackDeliveryFailure.DISPATCHER_MISSING,
        CallbackDeliveryFailure.DISPATCHER_STALE,
        CallbackDeliveryFailure.DISPATCHER_NOT_FOUND,
        CallbackDeliveryFailure.DART_CALLBACK_NOT_FOUND,
        CallbackDeliveryFailure.DART_CALLBACK_INVALID,
    )
}
