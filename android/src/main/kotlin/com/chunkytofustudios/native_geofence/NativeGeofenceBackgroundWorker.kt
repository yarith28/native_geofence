package com.chunkytofustudios.native_geofence

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.work.ForegroundInfo
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.chunkytofustudios.native_geofence.api.NativeGeofenceBackgroundApiImpl
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceBackgroundApi
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
import com.chunkytofustudios.native_geofence.util.LegacyCallbackPayloadReadResult
import com.chunkytofustudios.native_geofence.util.LegacyGeofenceCallbackPayloadStore
import com.chunkytofustudios.native_geofence.util.NativeGeofenceIo
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.chunkytofustudios.native_geofence.util.Notifications
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartCallback
import io.flutter.view.FlutterCallbackInformation
import java.util.concurrent.atomic.AtomicBoolean

class NativeGeofenceBackgroundWorker(
    private val context: Context,
    private val workerParams: WorkerParameters
) : ListenableWorker(context, workerParams) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val completed = AtomicBoolean(false)
    private val stopped = AtomicBoolean(false)
    private val destroyRequested = AtomicBoolean(false)

    @Volatile
    private var flutterEngine: FlutterEngine? = null

    @Volatile
    private var backgroundApiImpl: NativeGeofenceBackgroundApiImpl? = null

    @Volatile
    private var callbackParams: GeofenceCallbackParamsWire? = null

    @Volatile
    private var payloadLease: CallbackPayloadLease? = null

    @Volatile
    private var completer: CallbackToFutureAdapter.Completer<Result>? = null

    @Volatile
    private var coordinator: CallbackDeliveryCoordinator? = null

    private var startTime: Long = 0L

    override fun getForegroundInfoAsync(): ListenableFuture<ForegroundInfo> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return super.getForegroundInfoAsync()
        }
        val notification = Notifications.createBackgroundWorkerNotification(context)
        return Futures.immediateFuture(ForegroundInfo(NOTIFICATION_ID, notification))
    }

    override fun startWork(): ListenableFuture<Result> {
        startTime = System.currentTimeMillis()
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
        try {
            triggerApi.geofenceTriggered(params) { result ->
                if (coordinator?.complete(CallbackDeliveryStage.CALLBACK) != true) {
                    return@geofenceTriggered
                }
                val error = result.exceptionOrNull()
                if (error == null) {
                    finish(CallbackDeliveryPolicy.success())
                } else {
                    finishFailure(CallbackDeliveryPolicy.classifyDartError(error))
                }
            }
        } catch (error: Throwable) {
            if (coordinator?.complete(CallbackDeliveryStage.CALLBACK) == true) {
                NativeGeofenceLogger.e(context, TAG, "Failed to invoke the Dart callback.", error)
                finishFailure(CallbackDeliveryFailure.DART_DELIVERY)
            }
        }
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
                callbackParams = params
                mainHandler.post(::startFlutterEngine)
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
        callbackParams = CallbackPayloadMigration.withStableEventId(
            params,
            workerParams.id.toString()
        )
        mainHandler.post(::startFlutterEngine)
    }

    private fun startFlutterEngine() {
        if (completed.get() || stopped.get()) return

        val preferences = context.getSharedPreferences(
            Constants.SHARED_PREFERENCES_KEY,
            Context.MODE_PRIVATE
        )
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
                    val backgroundApi = NativeGeofenceBackgroundApiImpl(context, this)
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
                } catch (error: Throwable) {
                    NativeGeofenceLogger.e(
                        context,
                        TAG,
                        "Failed to start the callback runtime.",
                        error
                    )
                    finishFailure(CallbackDeliveryFailure.INFRASTRUCTURE)
                }
            }
        } catch (error: Throwable) {
            NativeGeofenceLogger.e(context, TAG, "Flutter startup failed.", error)
            finishFailure(CallbackDeliveryFailure.INFRASTRUCTURE)
        }
    }

    private fun finishFailure(failure: CallbackDeliveryFailure) {
        if (
            CallbackDeliveryPolicy.requiresCallbackRefresh(failure) &&
            !NativeGeofencePersistence.markCallbackRefreshRequired(context)
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

        val workResult = when (decision.workerResult) {
            CallbackWorkerResult.SUCCESS -> Result.success()
            CallbackWorkerResult.RETRY -> Result.retry()
        }
        val resolve = {
            if (!stopped.get()) {
                completer?.set(workResult)
            }
            val duration = System.currentTimeMillis() - startTime
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

    companion object {
        const val TAG = "NativeGeofenceBackgroundWorker"
        private const val NOTIFICATION_ID = 493620
        private const val STARTUP_TIMEOUT_MILLIS = 20_000L
        private const val API_READY_TIMEOUT_MILLIS = 15_000L
        private const val CALLBACK_TIMEOUT_MILLIS = 60_000L
        private val flutterLoader = FlutterInjector.instance().flutterLoader()
    }
}
