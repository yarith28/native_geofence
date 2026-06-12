package com.chunkytofustudios.native_geofence

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.work.ForegroundInfo
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.chunkytofustudios.native_geofence.api.NativeGeofenceBackgroundApiImpl
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceBackgroundApi
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceTriggerApi
import com.chunkytofustudios.native_geofence.model.GeofenceCallbackParamsStorage
import com.chunkytofustudios.native_geofence.util.Notifications
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartCallback
import io.flutter.view.FlutterCallbackInformation
import kotlin.time.Duration.Companion.minutes
import kotlinx.serialization.json.Json

class NativeGeofenceBackgroundWorker(
    private val context: Context,
    private val workerParams: WorkerParameters
) :
    ListenableWorker(context, workerParams) {
    companion object {
        const val TAG = "NativeGeofenceBackgroundWorker"
        // TODO: Consider using random ID.
        private const val NOTIFICATION_ID = 493620
        private const val MAX_CALLBACK_RUN_ATTEMPTS = 3
        private val flutterLoader = FlutterInjector.instance().flutterLoader()

        // Keep a stuck callback from blocking the unique WorkManager chain for
        // WorkManager's full timeout window.
        private val WATCHDOG_TIMEOUT = 5.minutes
    }

    private var flutterEngine: FlutterEngine? = null

    private var startTime: Long = 0

    private var completer: CallbackToFutureAdapter.Completer<Result>? = null

    private var resolvableFuture =
        CallbackToFutureAdapter.getFuture { completer ->
            this.completer = completer
            null
        }

    private var backgroundApiImpl: NativeGeofenceBackgroundApiImpl? = null

    private val watchdogHandler = Handler(Looper.getMainLooper())

    private val watchdogRunnable = Runnable {
        Log.e(
            TAG,
            "Geofence callback exceeded ${WATCHDOG_TIMEOUT.inWholeMilliseconds}ms; aborting."
        )
        stopEngine(Result.failure())
    }

    override fun getForegroundInfoAsync(): ListenableFuture<ForegroundInfo> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // This method does not need to be implemented for Android 31 (S) and above.
            return super.getForegroundInfoAsync()
        }
        val notification = Notifications.createBackgroundWorkerNotification(context)
        return Futures.immediateFuture(ForegroundInfo(NOTIFICATION_ID, notification))
    }

    override fun startWork(): ListenableFuture<Result> {
        startTime = System.currentTimeMillis()
        watchdogHandler.postDelayed(watchdogRunnable, WATCHDOG_TIMEOUT.inWholeMilliseconds)

        flutterEngine = FlutterEngine(applicationContext)

        if (!flutterLoader.initialized()) {
            flutterLoader.startInitialization(applicationContext)
        }

        flutterLoader.ensureInitializationCompleteAsync(
            applicationContext,
            null,
            Handler(Looper.getMainLooper()),
        ) {
            val callbackHandle = context.getSharedPreferences(
                Constants.SHARED_PREFERENCES_KEY,
                Context.MODE_PRIVATE
            )
                .getLong(Constants.CALLBACK_DISPATCHER_HANDLE_KEY, 0)
            if (callbackHandle == 0L) {
                Log.e(TAG, "No callback dispatcher registered.")
                stopEngine(Result.failure())
                return@ensureInitializationCompleteAsync
            }

            flutterEngine?.let { engine ->
                val callbackInfo =
                    FlutterCallbackInformation.lookupCallbackInformation(callbackHandle)
                if (callbackInfo == null) {
                    Log.e(TAG, "Failed to find callback dispatcher.")
                    stopEngine(Result.failure())
                    return@ensureInitializationCompleteAsync
                }

                backgroundApiImpl = NativeGeofenceBackgroundApiImpl(context, this)
                NativeGeofenceBackgroundApi.setUp(
                    engine.dartExecutor.binaryMessenger,
                    // Keep the same API instance so Dart's ready signal reaches this worker.
                    backgroundApiImpl
                )

                engine.dartExecutor.executeDartCallback(
                    DartCallback(
                        context.assets,
                        flutterLoader.findAppBundlePath(),
                        callbackInfo
                    )
                )
            }
        }

        return resolvableFuture
    }

    override fun onStopped() {
        stopEngine(null)
    }

    fun triggerApiReady() {
        val lEngine = flutterEngine
        if (lEngine == null) {
            Log.e(TAG, "FlutterEngine was null.")
            stopEngine(Result.failure())
            return
        }

        val nativeGeofenceTriggerApi =
            NativeGeofenceTriggerApi(lEngine.dartExecutor.binaryMessenger)
        Log.d(TAG, "NativeGeofenceTriggerApi setup complete.")

        val params = getGeofenceCallbackParams()
        if (params == null) {
            stopEngine(Result.failure())
            return
        }

        nativeGeofenceTriggerApi.geofenceTriggered(params) { result ->
            if (result.isSuccess) {
                stopEngine(Result.success())
            } else {
                Log.e(TAG, "Geofence callback failed: ${result.exceptionOrNull()}")
                stopEngine(callbackFailureResult())
            }
        }
    }

    private fun callbackFailureResult(): Result {
        val currentAttempt = workerParams.runAttemptCount + 1
        if (currentAttempt < MAX_CALLBACK_RUN_ATTEMPTS) {
            Log.w(
                TAG,
                "Retrying geofence callback after failure. " +
                    "attempt=$currentAttempt/$MAX_CALLBACK_RUN_ATTEMPTS"
            )
            return Result.retry()
        }
        Log.e(TAG, "Geofence callback failed after $currentAttempt attempts.")
        return Result.failure()
    }

    private fun stopEngine(result: Result?) {
        watchdogHandler.removeCallbacks(watchdogRunnable)
        val fetchDuration = System.currentTimeMillis() - startTime

        // No result indicates we were signalled to stop by WorkManager. The result is already
        // STOPPED, so no need to resolve another one.
        if (result != null) {
            this.completer?.set(result)
        }

        // If stopEngine is called from `onStopped`, it may not be from the main thread.
        Handler(Looper.getMainLooper()).post {
            flutterEngine?.destroy()
            flutterEngine = null
        }

        Log.d(TAG, "Work took ${fetchDuration}ms.")
    }

    private fun getGeofenceCallbackParams(): GeofenceCallbackParamsWire? {
        val jsonData = workerParams.inputData.getString(Constants.WORKER_PAYLOAD_KEY)
        if (jsonData == null) {
            Log.e(TAG, "Worker payload was missing.")
            return null
        }

        try {
            return Json.decodeFromString<GeofenceCallbackParamsStorage>(jsonData).toWire()
        } catch (e: Exception) {
            Log.e(
                TAG,
                "Failed to parse worker payload. Data=${jsonData}"
            )
            return null
        }
    }
}
