package com.chunkytofustudios.native_geofence

import android.content.Context
import com.chunkytofustudios.native_geofence.api.NativeGeofenceApiImpl
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceApi
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

class NativeGeofencePlugin : FlutterPlugin {
    private var context: Context? = null
    private var logFileChannel: MethodChannel? = null

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
                        NativeGeofenceLogger.configure(
                            appContext,
                            call.argument<Boolean>("enabled") ?: false,
                            call.argument<Int>("maxBytes")
                                ?: Constants.DEFAULT_LOG_FILE_MAX_BYTES,
                        )
                        result.success(null)
                    }
                    "readLogFile" -> result.success(NativeGeofenceLogger.read(appContext))
                    "clearLogFile" -> {
                        NativeGeofenceLogger.clear(appContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        NativeGeofenceLogger.d(TAG, "NativeGeofenceApi setup complete.")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        logFileChannel?.setMethodCallHandler(null)
        logFileChannel = null
        context = null
    }
}
