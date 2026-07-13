package com.chunkytofustudios.native_geofence

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.chunkytofustudios.native_geofence.api.NativeGeofenceApiImpl
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceApi
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

class NativeGeofencePlugin : FlutterPlugin {
    private var context: Context? = null
    private var logFileChannel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        @JvmStatic
        private val TAG = "NativeGeofencePlugin"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        NativeGeofenceLogger.initialize(binding.applicationContext)
        NativeGeofenceApi.setUp(
            binding.binaryMessenger,
            NativeGeofenceApiImpl(binding.applicationContext)
        )
        logFileChannel = MethodChannel(
            binding.binaryMessenger,
            Constants.LOG_FILE_CHANNEL_NAME
        ).apply {
            setMethodCallHandler { call, result ->
                val appContext = binding.applicationContext
                when (call.method) {
                    "configureLogFile" -> {
                        val maxBytes = call.argument<Number>("maxBytes")
                            ?.toLong()
                            ?.coerceIn(
                                Constants.MIN_LOG_FILE_MAX_BYTES.toLong(),
                                Constants.MAX_LOG_FILE_MAX_BYTES.toLong(),
                            )
                            ?.toInt()
                            ?: Constants.DEFAULT_LOG_FILE_MAX_BYTES
                        NativeGeofenceLogger.configure(
                            appContext,
                            call.argument<Boolean>("enabled") ?: false,
                            maxBytes,
                        )
                        result.success(null)
                    }
                    "readLogFile" -> {
                        NativeGeofenceLogger.readAsync(appContext) { outcome ->
                            reply(result, outcome)
                        }
                    }
                    "clearLogFile" -> {
                        NativeGeofenceLogger.clearAsync(appContext) { outcome ->
                            replyEmpty(result, outcome)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        NativeGeofenceLogger.d(
            binding.applicationContext,
            TAG,
            "NativeGeofenceApi setup complete.",
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        logFileChannel?.setMethodCallHandler(null)
        logFileChannel = null
        context = null
    }

    private fun <T> reply(result: MethodChannel.Result, outcome: Result<T>) {
        mainHandler.post {
            outcome.fold(
                onSuccess = { result.success(it) },
                onFailure = { replyLogFileError(result, it) }
            )
        }
    }

    private fun replyEmpty(result: MethodChannel.Result, outcome: Result<Unit>) {
        mainHandler.post {
            outcome.fold(
                onSuccess = { result.success(null) },
                onFailure = { replyLogFileError(result, it) }
            )
        }
    }

    private fun replyLogFileError(result: MethodChannel.Result, throwable: Throwable) {
        result.error(
            "native_geofence_log_file_io_failed",
            throwable.message,
            Log.getStackTraceString(throwable)
        )
    }
}
