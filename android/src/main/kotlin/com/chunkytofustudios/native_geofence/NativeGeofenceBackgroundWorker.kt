package com.chunkytofustudios.native_geofence

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.work.ForegroundInfo
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.chunkytofustudios.native_geofence.api.NativeGeofenceBackgroundApiImpl
import com.chunkytofustudios.native_geofence.bridge.NativeGeofenceBridgeDispatcher
import com.chunkytofustudios.native_geofence.bridge.NativeGeofenceBridgeOutcome
import com.chunkytofustudios.native_geofence.bridge.NativeGeofenceCallbackRoute
import com.chunkytofustudios.native_geofence.bridge.NativeGeofenceCallbackWorkerRouter
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceBackgroundApi
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceTriggerApi
import com.chunkytofustudios.native_geofence.util.AndroidPackageFingerprint
import com.chunkytofustudios.native_geofence.util.CallbackDeliveryCoordinator
import com.chunkytofustudios.native_geofence.util.CallbackDeliveryDecision
import com.chunkytofustudios.native_geofence.util.CallbackDeliveryFailure
import com.chunkytofustudios.native_geofence.util.CallbackDeliveryPolicy
import com.chunkytofustudios.native_geofence.util.CallbackDeliveryStage
import com.chunkytofustudios.native_geofence.util.CallbackPayloadInput
import com.chunkytofustudios.native_geofence.util.CallbackPayloadLease
import com.chunkytofustudios.native_geofence.util.CallbackPayloadMigration
import com.chunkytofustudios.native_geofence.util.CallbackPayloadReadResult
import com.chunkytofustudios.native_geofence.util.CallbackPayloadSettlement
import com.chunkytofustudios.native_geofence.util.CallbackWorkerResult
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackPayloadStore
import com.chunkytofustudios.native_geofence.util.ForegroundPromotionRegistry
import com.chunkytofustudios.native_geofence.util.ForegroundServiceCompatibility
import com.chunkytofustudios.native_geofence.util.LegacyCallbackPayloadReadResult
import com.chunkytofustudios.native_geofence.util.LegacyGeofenceCallbackPayloadStore
import com.chunkytofustudios.native_geofence.util.NativeGeofenceIo
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnosticStage
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDeliveryDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.chunkytofustudios.native_geofence.util.NativeGeofencePreferences
import com.chunkytofustudios.native_geofence.util.Notifications
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartCallback
import io.flutter.view.FlutterCallbackInformation
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

class NativeGeofenceBackgroundWorker(
    private val context: Context,
    private val workerParams: WorkerParameters
) : ListenableWorker(context, workerParams) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val completed = AtomicBoolean(false)
    private val stopped = AtomicBoolean(false)
    private val destroyRequested = AtomicBoolean(false)
    private val foregroundLock = Object()
    private val deliveryRouter = NativeGeofenceCallbackWorkerRouter.fromInputData(
        workerParams.inputData
    )
    private val deliveryRoute = deliveryRouter.route
    private val deliverySource = workerParams.inputData
        .getString(Constants.WORKER_DELIVERY_SOURCE_KEY)
        ?.takeIf(String::isNotBlank)

    @Volatile
    private var flutterEngine: FlutterEngine? = null

    @Volatile
    private var backgroundApiImpl: NativeGeofenceBackgroundApiImpl? = null

    @Volatile
    private var callbackParams: GeofenceCallbackParamsWire? = null

    @Volatile
    private var deliveryParams: GeofenceCallbackParamsWire? = null

    @Volatile
    private var payloadEnqueuedAtMillis: Long? = null

    @Volatile
    private var payloadLease: CallbackPayloadLease? = null

    @Volatile
    private var completer: CallbackToFutureAdapter.Completer<Result>? = null

    @Volatile
    private var coordinator: CallbackDeliveryCoordinator? = null

    @Volatile
    private var foregroundPromotionToken: String? = null

    @Volatile
    private var workerDiagnosticFailure: CallbackDeliveryFailure? = null

    private var startTimeElapsed: Long = 0L

    override fun getForegroundInfoAsync(): ListenableFuture<ForegroundInfo> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return super.getForegroundInfoAsync()
        }
        val notification = Notifications.createBackgroundWorkerNotification(context)
        return Futures.immediateFuture(ForegroundInfo(NOTIFICATION_ID, notification))
    }

    override fun startWork(): ListenableFuture<Result> {
        startTimeElapsed = SystemClock.elapsedRealtime()
        coordinator = CallbackDeliveryCoordinator(
            timeoutMillis = ::timeoutFor,
            schedule = { delayMillis, action ->
                val runnable = Runnable(action)
                mainHandler.postDelayed(runnable, delayMillis)
                val cancel: () -> Unit = { mainHandler.removeCallbacks(runnable) }
                cancel
            },
            onTimeout = { stage ->
                finishFailure(
                    when (stage) {
                        CallbackDeliveryStage.STARTUP ->
                            CallbackDeliveryFailure.STARTUP_TIMEOUT
                        CallbackDeliveryStage.API_READY ->
                            CallbackDeliveryFailure.API_READY_TIMEOUT
                        CallbackDeliveryStage.CALLBACK ->
                            CallbackDeliveryFailure.CALLBACK_TIMEOUT
                    }
                )
            }
        )

        return CallbackToFutureAdapter.getFuture { futureCompleter ->
            completer = futureCompleter
            NativeGeofenceIo.execute(::loadPayload)
            "$TAG:${workerParams.id}"
        }
    }

    override fun onStopped() {
        recordDelivery(
            stage = "worker_stopped",
            outcome = "cancelled",
            reasonCode = workerDiagnosticFailure?.name?.lowercase() ?: "system_stop",
        )
        stopped.set(true)
        completed.set(true)
        coordinator?.cancel()
        destroyEngine()
    }

    fun triggerApiReady() {
        val params = callbackParams
        val engine = flutterEngine
        if (params == null || engine == null) {
            finishFailure(CallbackDeliveryFailure.INFRASTRUCTURE)
            return
        }
        if (
            coordinator?.advance(
                CallbackDeliveryStage.API_READY,
                CallbackDeliveryStage.CALLBACK
            ) != true
        ) {
            return
        }

        val triggerApi = NativeGeofenceTriggerApi(engine.dartExecutor.binaryMessenger)
        NativeGeofenceLogger.d(context, TAG, "Dart callback API is ready.")
        recordDelivery(
            stage = "dart_callback",
            outcome = "invoking",
            owner = "dart",
        )
        try {
            triggerApi.geofenceTriggered(params) { result ->
                if (coordinator?.complete(CallbackDeliveryStage.CALLBACK) != true) {
                    recordDelivery(
                        stage = "dart_callback",
                        outcome = "late_completion_ignored",
                        owner = "dart",
                    )
                    return@geofenceTriggered
                }
                val error = result.exceptionOrNull()
                if (error == null) {
                    recordDelivery(
                        stage = "dart_callback",
                        outcome = "completed",
                        owner = "dart",
                    )
                    finish(CallbackDeliveryPolicy.success())
                } else {
                    recordDelivery(
                        stage = "dart_callback",
                        outcome = "failed",
                        owner = "dart",
                        errorType = error.javaClass.name,
                    )
                    finishFailure(CallbackDeliveryPolicy.classifyDartError(error))
                }
            }
        } catch (error: Throwable) {
            if (coordinator?.complete(CallbackDeliveryStage.CALLBACK) == true) {
                NativeGeofenceLogger.e(context, TAG, "Failed to invoke the Dart callback.", error)
                recordDelivery(
                    stage = "dart_callback",
                    outcome = "invoke_threw",
                    owner = "dart",
                    errorType = error.javaClass.name,
                )
                finishFailure(CallbackDeliveryFailure.DART_DELIVERY)
            }
        }
    }

    fun requestForegroundPromotion(callback: (kotlin.Result<Unit>) -> Unit) {
        if (completed.get() || stopped.get()) {
            recordForegroundFact(false, "worker_inactive")
            callback(
                kotlin.Result.failure(
                    FlutterError(
                        NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                        "The callback worker is no longer active."
                    )
                )
            )
            return
        }
        if (foregroundPromotionToken != null) {
            recordForegroundFact(false, "already_active")
            callback(
                kotlin.Result.failure(
                    FlutterError(
                        NativeGeofenceErrorCode.INVALID_ARGUMENTS.raw.toString(),
                        "Foreground promotion is already active or pending."
                    )
                )
            )
            return
        }

        val prerequisiteError = ForegroundServiceCompatibility.validatePrerequisites(context)
        if (prerequisiteError != null) {
            recordForegroundFact(false, "prerequisite_failed")
            callback(kotlin.Result.failure(prerequisiteError))
            return
        }

        val token = UUID.randomUUID().toString()
        val registered = synchronized(foregroundLock) {
            if (completed.get() || stopped.get() || foregroundPromotionToken != null) {
                false
            } else {
                foregroundPromotionToken = token
                ForegroundPromotionRegistry.request(token) { result ->
                    val current = synchronized(foregroundLock) {
                        if (foregroundPromotionToken != token) {
                            false
                        } else {
                            if (result.isFailure) {
                                foregroundPromotionToken = null
                            }
                            true
                        }
                    }
                    if (!current) {
                        return@request
                    }
                    if (result.isFailure) {
                        ForegroundServiceCompatibility.stop(context)
                    }
                    recordForegroundFact(
                        result.isSuccess,
                        if (result.isSuccess) "promotion_confirmed" else "promotion_failed"
                    )
                    callback(result)
                }
            }
        }
        if (!registered) {
            synchronized(foregroundLock) {
                if (foregroundPromotionToken == token) {
                    foregroundPromotionToken = null
                }
            }
            recordForegroundFact(false, "token_reservation_failed")
            callback(
                kotlin.Result.failure(
                    FlutterError(
                        NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                        "Failed to reserve a foreground-promotion token."
                    )
                )
            )
            return
        }

        val intent = android.content.Intent(
            context,
            NativeGeofenceForegroundService::class.java
        ).apply {
            action = Constants.ACTION_PROMOTE_FOREGROUND
            putExtra(Constants.FOREGROUND_PROMOTION_TOKEN_KEY, token)
        }
        val startResult = ForegroundServiceCompatibility.start(context, intent)
        startResult.exceptionOrNull()?.let { error ->
            ForegroundPromotionRegistry.complete(token, kotlin.Result.failure(error))
        }
    }

    fun demoteForegroundService() {
        val token = synchronized(foregroundLock) {
            val current = foregroundPromotionToken
            foregroundPromotionToken = null
            current
        }
        if (token != null) {
            ForegroundPromotionRegistry.abandon(token)
            recordForegroundFact(true, "stopped")
        }
        ForegroundServiceCompatibility.stop(context)
    }

    private fun recordForegroundFact(succeeded: Boolean, outcome: String) {
        NativeGeofenceDiagnostics.record(
            context,
            NativeGeofenceDiagnosticStage.FOREGROUND,
            succeeded = succeeded,
            outcome = outcome,
            geofenceCount = callbackParams?.geofences?.size
        )
    }

    private fun loadPayload() {
        if (completed.get() || stopped.get()) return

        val input = CallbackPayloadMigration.selectInput(
            currentReference = workerParams.inputData.getString(
                Constants.WORKER_PAYLOAD_REFERENCE_KEY
            ),
            legacyInline = workerParams.inputData.getString(Constants.WORKER_PAYLOAD_KEY),
            legacyReference = workerParams.inputData.getString(
                Constants.LEGACY_WORKER_PAYLOAD_FILE_KEY
            )
        )
        when (input) {
            is CallbackPayloadInput.CurrentReference -> loadCurrentPayload(input.reference)
            is CallbackPayloadInput.LegacyInline -> loadLegacyInlinePayload(input.encoded)
            is CallbackPayloadInput.LegacyReference -> loadLegacyFilePayload(input.reference)
            CallbackPayloadInput.Missing ->
                finishFailure(CallbackDeliveryFailure.PAYLOAD_MISSING)
        }
    }

    private fun loadCurrentPayload(reference: String) {
        val store = GeofenceCallbackPayloadStore.forContext(context)
        payloadLease = CallbackPayloadLease { store.delete(reference) }
        when (val loaded = store.read(reference)) {
            CallbackPayloadReadResult.Missing ->
                finishFailure(CallbackDeliveryFailure.PAYLOAD_MISSING)
            CallbackPayloadReadResult.Corrupt ->
                finishFailure(CallbackDeliveryFailure.PAYLOAD_CORRUPT)
            is CallbackPayloadReadResult.Found -> {
                payloadEnqueuedAtMillis = loaded.envelope.enqueuedAtMillis
                val currentFingerprint = AndroidPackageFingerprint.current(context)
                if (loaded.envelope.packageFingerprint != currentFingerprint) {
                    finishFailure(CallbackDeliveryFailure.PACKAGE_STALE)
                    return
                }
                val params = loaded.envelope.toWire()
                if (params.eventId.isNullOrBlank()) {
                    finishFailure(CallbackDeliveryFailure.EVENT_ID_MISSING)
                    return
                }
                mainHandler.post { processDelivery(params) }
            }
        }
    }

    private fun loadLegacyInlinePayload(encoded: String) {
        val params = when (val loaded = CallbackPayloadMigration.decodeLegacyInline(encoded)) {
            is LegacyCallbackPayloadReadResult.Found -> loaded.params
            LegacyCallbackPayloadReadResult.Missing -> {
                finishFailure(CallbackDeliveryFailure.PAYLOAD_MISSING)
                return
            }
            LegacyCallbackPayloadReadResult.Corrupt -> {
                finishFailure(CallbackDeliveryFailure.PAYLOAD_CORRUPT)
                return
            }
        }
        processLegacyPayload(params)
    }

    private fun loadLegacyFilePayload(reference: String) {
        val store = LegacyGeofenceCallbackPayloadStore.forContext(context)
        payloadLease = CallbackPayloadLease { store.delete(reference) }
        val params = when (val loaded = store.read(reference)) {
            is LegacyCallbackPayloadReadResult.Found -> loaded.params
            LegacyCallbackPayloadReadResult.Missing -> {
                finishFailure(CallbackDeliveryFailure.PAYLOAD_MISSING)
                return
            }
            LegacyCallbackPayloadReadResult.Corrupt -> {
                finishFailure(CallbackDeliveryFailure.PAYLOAD_CORRUPT)
                return
            }
        }
        processLegacyPayload(params)
    }

    private fun processLegacyPayload(params: GeofenceCallbackParamsWire) {
        // A pre-upgrade WorkRequest has no delivery ID. Its WorkRequest ID is
        // stable across retries and is never used as the unique-work key.
        val deliveryParams = CallbackPayloadMigration.withStableEventId(
            params,
            workerParams.id.toString()
        )
        mainHandler.post { processDelivery(deliveryParams) }
    }

    private fun processDelivery(params: GeofenceCallbackParamsWire) {
        if (completed.get() || stopped.get()) return
        deliveryParams = params
        recordDelivery(
            stage = "worker_started",
            outcome = "processing",
            owner = if (deliveryRoute.requiresNativeBridge) "native_geofence" else "dart",
            reasonCode = deliveryRoute.storageValue,
        )
        deliveryRouter.dispatch(
            processNativeBridge = { processNativeBridge(params) },
            processFinalCallback = { processFinalCallback(params) },
        )
    }

    private fun processNativeBridge(params: GeofenceCallbackParamsWire) {
        NativeGeofenceBridgeDispatcher.process(context, params) { outcome ->
            mainHandler.post {
                if (completed.get() || stopped.get()) return@post
                when (outcome) {
                    NativeGeofenceBridgeOutcome.Accepted ->
                        finish(CallbackDeliveryPolicy.success())
                    is NativeGeofenceBridgeOutcome.Continue -> {
                        callbackParams = outcome.params
                        recordDelivery(
                            stage = "dart_runtime",
                            outcome = "startup_requested",
                            owner = "dart",
                        )
                        startFlutterEngine()
                    }
                }
            }
        }
    }

    private fun processFinalCallback(params: GeofenceCallbackParamsWire) {
        if (completed.get() || stopped.get()) return
        callbackParams = params
        recordDelivery(
            stage = "dart_runtime",
            outcome = "startup_requested",
            owner = "dart",
            reasonCode = NativeGeofenceCallbackRoute.FINAL_DART_CALLBACK.storageValue,
        )
        startFlutterEngine()
    }

    private fun startFlutterEngine() {
        if (completed.get() || stopped.get()) return

        val preferences = NativeGeofencePreferences.get(context)
        val callbackHandle = preferences.getLong(
            Constants.CALLBACK_DISPATCHER_HANDLE_KEY,
            0L
        )
        if (callbackHandle == 0L) {
            finishFailure(CallbackDeliveryFailure.DISPATCHER_MISSING)
            return
        }

        val recordedFingerprint = preferences.getString(
            Constants.CALLBACK_DISPATCHER_PACKAGE_FINGERPRINT_KEY,
            null
        )
        if (recordedFingerprint != AndroidPackageFingerprint.current(context)) {
            finishFailure(CallbackDeliveryFailure.DISPATCHER_STALE)
            return
        }

        val callbackInfo = FlutterCallbackInformation.lookupCallbackInformation(callbackHandle)
        if (callbackInfo == null) {
            finishFailure(CallbackDeliveryFailure.DISPATCHER_NOT_FOUND)
            return
        }

        try {
            if (!flutterLoader.initialized()) {
                flutterLoader.startInitialization(applicationContext)
            }
            flutterLoader.ensureInitializationCompleteAsync(
                applicationContext,
                null,
                mainHandler
            ) {
                if (completed.get() || stopped.get()) return@ensureInitializationCompleteAsync
                try {
                    val engine = FlutterEngine(applicationContext)
                    flutterEngine = engine
                    val backgroundApi = NativeGeofenceBackgroundApiImpl(this)
                    backgroundApiImpl = backgroundApi
                    NativeGeofenceBackgroundApi.setUp(
                        engine.dartExecutor.binaryMessenger,
                        backgroundApi
                    )
                    if (
                        coordinator?.advance(
                            CallbackDeliveryStage.STARTUP,
                            CallbackDeliveryStage.API_READY
                        ) != true
                    ) {
                        destroyEngine()
                        return@ensureInitializationCompleteAsync
                    }
                    engine.dartExecutor.executeDartCallback(
                        DartCallback(
                            context.assets,
                            flutterLoader.findAppBundlePath(),
                            callbackInfo
                        )
                    )
                    recordDelivery(
                        stage = "dart_runtime",
                        outcome = "started",
                        owner = "dart",
                    )
                } catch (error: Throwable) {
                    NativeGeofenceLogger.e(
                        context,
                        TAG,
                        "Failed to start the callback runtime.",
                        error
                    )
                    recordDelivery(
                        stage = "dart_runtime",
                        outcome = "startup_failed",
                        owner = "dart",
                        errorType = error.javaClass.name,
                    )
                    finishFailure(CallbackDeliveryFailure.INFRASTRUCTURE)
                }
            }
        } catch (error: Throwable) {
            NativeGeofenceLogger.e(context, TAG, "Flutter startup failed.", error)
            recordDelivery(
                stage = "dart_runtime",
                outcome = "startup_failed",
                owner = "dart",
                errorType = error.javaClass.name,
            )
            finishFailure(CallbackDeliveryFailure.INFRASTRUCTURE)
        }
    }

    private fun finishFailure(failure: CallbackDeliveryFailure) {
        workerDiagnosticFailure = failure
        if (
            CallbackDeliveryPolicy.requiresCallbackRefresh(failure) &&
            !NativeGeofencePersistence.markCallbackRefreshRequired(
                context,
                callbackParams?.geofences?.map { it.id }?.toSet().orEmpty()
            )
        ) {
            NativeGeofenceLogger.e(
                context,
                TAG,
                "Failed to persist callback-refresh evidence."
            )
        }
        val decision = CallbackDeliveryPolicy.failure(failure, runAttemptCount)
        NativeGeofenceLogger.w(
            context,
            TAG,
            "Callback delivery outcome=$failure attempt=${runAttemptCount + 1} " +
                "workerResult=${decision.workerResult}."
        )
        finish(decision)
    }

    private fun finish(decision: CallbackDeliveryDecision) {
        if (!completed.compareAndSet(false, true)) return
        coordinator?.cancel()
        NativeGeofenceDiagnostics.record(
            context,
            NativeGeofenceDiagnosticStage.WORKER,
            succeeded = workerDiagnosticFailure == null,
            outcome = workerDiagnosticFailure?.name?.lowercase()
                ?: when (decision.workerResult) {
                    CallbackWorkerResult.SUCCESS -> "completed"
                    CallbackWorkerResult.RETRY -> "retry_scheduled"
                },
            geofenceCount = callbackParams?.geofences?.size
        )
        val terminalOutcome = workerDiagnosticFailure?.name?.lowercase()
            ?: when (decision.workerResult) {
                CallbackWorkerResult.SUCCESS -> "completed"
                CallbackWorkerResult.RETRY -> "retry_scheduled"
            }
        recordDelivery(
            stage = "worker_finished",
            outcome = terminalOutcome,
            owner = if (callbackParams == null) "native" else "dart",
            reasonCode = decision.workerResult.name.lowercase(),
        )

        val workResult = when (decision.workerResult) {
            CallbackWorkerResult.SUCCESS -> Result.success()
            CallbackWorkerResult.RETRY -> Result.retry()
        }
        val resolve = {
            if (!stopped.get()) {
                completer?.set(workResult)
            }
            val duration = SystemClock.elapsedRealtime() - startTimeElapsed
            NativeGeofenceLogger.d(context, TAG, "Callback work completed in ${duration}ms.")
        }

        destroyEngine {
            val lease = payloadLease
            if (lease != null) {
                lease.settle(decision, NativeGeofenceIo::execute) { settlement ->
                    if (settlement == CallbackPayloadSettlement.DELETE_FAILED) {
                        NativeGeofenceLogger.e(
                            context,
                            TAG,
                            "Failed to clean a callback payload."
                        )
                    }
                    resolve()
                }
            } else {
                resolve()
            }
        }
    }

    private fun destroyEngine(afterDestroy: () -> Unit = {}) {
        demoteForegroundService()
        if (!destroyRequested.compareAndSet(false, true)) {
            mainHandler.post(afterDestroy)
            return
        }
        mainHandler.post {
            val engine = flutterEngine
            if (engine != null) {
                NativeGeofenceBackgroundApi.setUp(engine.dartExecutor.binaryMessenger, null)
                engine.destroy()
            }
            flutterEngine = null
            backgroundApiImpl = null
            afterDestroy()
        }
    }

    private fun timeoutFor(stage: CallbackDeliveryStage): Long = when (stage) {
        CallbackDeliveryStage.STARTUP -> STARTUP_TIMEOUT_MILLIS
        CallbackDeliveryStage.API_READY -> API_READY_TIMEOUT_MILLIS
        CallbackDeliveryStage.CALLBACK -> CALLBACK_TIMEOUT_MILLIS
    }

    private fun recordDelivery(
        stage: String,
        outcome: String,
        owner: String? = null,
        reasonCode: String? = null,
        errorType: String? = null,
    ) {
        val params = deliveryParams ?: callbackParams
        val location = params?.location
        runCatching {
            NativeGeofenceDeliveryDiagnostics.record(
                context = context,
                traceId = params?.traceId ?: params?.eventId,
                stage = stage,
                outcome = outcome,
                event = params?.event?.name?.lowercase(),
                geofenceCount = params?.geofences?.size,
                attempt = runAttemptCount + 1,
                owner = owner,
                reasonCode = reasonCode,
                durationMillis = if (startTimeElapsed == 0L) {
                    null
                } else {
                    SystemClock.elapsedRealtime() - startTimeElapsed
                },
                queueAgeMillis = payloadEnqueuedAtMillis?.let {
                    (System.currentTimeMillis() - it).coerceAtLeast(0L)
                },
                hasLocation = params?.let { location != null },
                locationAgeMillis = location?.elapsedRealtimeNanos?.let {
                    ((SystemClock.elapsedRealtimeNanos() - it) / 1_000_000L)
                        .coerceAtLeast(0L)
                },
                accuracyMeters = location?.accuracyMeters,
                processorSource = deliverySource,
                errorType = errorType,
            )
        }
    }

    companion object {
        const val TAG = "NativeGeofenceBackgroundWorker"
        private const val NOTIFICATION_ID = 493620
        private const val STARTUP_TIMEOUT_MILLIS = 20_000L
        private const val API_READY_TIMEOUT_MILLIS = 15_000L
        private const val CALLBACK_TIMEOUT_MILLIS = 60_000L
        private val flutterLoader = FlutterInjector.instance().flutterLoader()
    }
}
