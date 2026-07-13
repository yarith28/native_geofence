package com.chunkytofustudios.native_geofence.api

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.ActiveGeofenceWire
import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceApi
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode
import com.chunkytofustudios.native_geofence.util.GeofenceEvents
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceBroadcastReceiver
import com.chunkytofustudios.native_geofence.util.ActiveGeofenceWires
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceFailureMapper
import com.chunkytofustudios.native_geofence.util.GeofenceWires
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices

class NativeGeofenceApiImpl(private val context: Context) : NativeGeofenceApi {
    companion object {
        @JvmStatic
        private val TAG = "NativeGeofenceApiImpl"
    }

    private val geofencingClient = LocationServices.getGeofencingClient(context)

    override fun initialize(callbackDispatcherHandle: Long) {
        persistCallbackDispatcherHandle(callbackDispatcherHandle) { handle ->
            context.getSharedPreferences(
                Constants.SHARED_PREFERENCES_KEY,
                Context.MODE_PRIVATE
            )
                .edit()
                .putLong(Constants.CALLBACK_DISPATCHER_HANDLE_KEY, handle)
                .commit()
        }
        NativeGeofenceLogger.d(context, TAG, "Initialized NativeGeofenceApi.")
    }

    override fun createGeofence(
        geofence: GeofenceWire,
        callback: (Result<Unit>) -> Unit
    ) {
        createGeofenceHelper(geofence, true, callback)
    }

    override fun reCreateAfterReboot() {
        val geofences = NativeGeofencePersistence.getAllGeofences(context)
        for (geofence in geofences) {
            createGeofenceHelper(geofence, false, null)
        }
        NativeGeofenceLogger.d(context, TAG, "${geofences.size} geofences re-created.")
    }

    override fun getGeofenceIds(): List<String> {
        return NativeGeofencePersistence.getAllGeofenceIds(context)
    }

    override fun getGeofences(): List<ActiveGeofenceWire> {
        val geofences = NativeGeofencePersistence.getAllGeofences(context)
        return geofences.map { ActiveGeofenceWires.fromGeofenceWire(it) }.toList()
    }

    override fun removeGeofenceById(id: String, callback: (Result<Unit>) -> Unit) {
        geofencingClient.removeGeofences(listOf(id)).run {
            addOnSuccessListener {
                if (!NativeGeofencePersistence.removeGeofence(context, id)) {
                    callback.invoke(
                        Result.failure(
                            FlutterError(
                                NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                                "The geofence was removed from Play services, but durable " +
                                    "plugin state could not be updated."
                            )
                        )
                    )
                    return@addOnSuccessListener
                }
                NativeGeofenceLogger.d(context, TAG, "Removed Geofence ID=$id.")
                callback.invoke(Result.success(Unit))
            }
            addOnFailureListener {
                val failure = AndroidGeofenceFailureMapper.from(it)
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Failure when removing Geofence ID=$id: $it",
                    it,
                )
                callback.invoke(
                    Result.failure(
                        FlutterError(
                            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                            failure.message,
                            failure.details
                        )
                    )
                )
            }
        }
    }

    override fun removeAllGeofences(callback: (Result<Unit>) -> Unit) {
        val rawIds = NativeGeofencePersistence.getAllRawGeofenceIds(context)
        if (rawIds.isEmpty()) {
            if (!NativeGeofencePersistence.removeAllGeofences(context)) {
                callback.invoke(
                    Result.failure(
                        FlutterError(
                            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                            "Failed to clear durable plugin geofence state."
                        )
                    )
                )
                return
            }
            callback.invoke(Result.success(Unit))
            return
        }

        geofencingClient.removeGeofences(rawIds).run {
            addOnSuccessListener {
                if (!NativeGeofencePersistence.removeAllGeofences(context)) {
                    callback.invoke(
                        Result.failure(
                            FlutterError(
                                NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                                "All geofences were removed from Play services, but durable " +
                                    "plugin state could not be updated."
                            )
                        )
                    )
                    return@addOnSuccessListener
                }
                NativeGeofenceLogger.d(context, TAG, "Removed all geofences (if any).")
                callback.invoke(Result.success(Unit))
            }
            addOnFailureListener {
                val failure = AndroidGeofenceFailureMapper.from(it)
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Failed to remove all geofences: $it",
                    it,
                )
                callback.invoke(
                    Result.failure(
                        FlutterError(
                            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                            failure.message,
                            failure.details
                        )
                    )
                )
            }
        }
    }

    private fun getGeofencePendingIndent(
        context: Context,
        callbackHandle: Long?
    ): PendingIntent {
        val intent = Intent(context, NativeGeofenceBroadcastReceiver::class.java)
        if (callbackHandle != null) {
            intent.putExtra(Constants.CALLBACK_HANDLE_KEY, callbackHandle)
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.getBroadcast(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )
        } else {
            PendingIntent.getBroadcast(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT
            )
        }
    }

    private fun geofenceBroadcastReceiverDeclaredAndEnabled(context: Context): Boolean {
        val component = ComponentName(context, NativeGeofenceBroadcastReceiver::class.java)
        val receiverInfo = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getReceiverInfo(
                    component,
                    PackageManager.ComponentInfoFlags.of(0L)
                )
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getReceiverInfo(component, 0)
            }
        } catch (_: PackageManager.NameNotFoundException) {
            return false
        }

        val enabledSetting = context.packageManager.getComponentEnabledSetting(component)
        val enabledBySetting = enabledSetting != PackageManager.COMPONENT_ENABLED_STATE_DISABLED &&
            enabledSetting != PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER &&
            enabledSetting != PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED
        return receiverInfo.enabled && enabledBySetting
    }

    @SuppressLint("MissingPermission")
    private fun createGeofenceHelper(
        geofence: GeofenceWire,
        cache: Boolean,
        callback: ((Result<Unit>) -> Unit)?
    ) {
        if (!geofenceBroadcastReceiverDeclaredAndEnabled(context)) {
            val message =
                "NativeGeofenceBroadcastReceiver is missing or disabled in the merged " +
                    "Android manifest. The receiver declared by native_geofence is " +
                    "required for geofence callback delivery."
            callback?.invoke(
                Result.failure(
                    FlutterError(
                        NativeGeofenceErrorCode.ANDROID_MANIFEST_COMPONENT_MISSING.raw.toString(),
                        message,
                        NativeGeofenceBroadcastReceiver::class.java.name
                    )
                )
            )
            return
        }

        // We try to create the Geofence without checking for permissions.
        // Only if creation fails we will alert the Flutter plugin of the permission issue.
        geofencingClient.addGeofences(
            GeofencingRequest.Builder().apply {
                setInitialTrigger(GeofenceEvents.createMask(geofence.androidSettings.initialTriggers))
                addGeofence(GeofenceWires.toGeofence(geofence))
            }.build(),
            getGeofencePendingIndent(context, geofence.callbackHandle)
        ).run {
            addOnSuccessListener {
                if (cache) {
                    if (!NativeGeofencePersistence.saveGeofence(context, geofence)) {
                        callback?.invoke(
                            Result.failure(
                                FlutterError(
                                    NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                                    "Play services registered the geofence, but its canonical " +
                                        "configuration could not be durably persisted."
                                )
                            )
                        )
                        return@addOnSuccessListener
                    }
                } else if (
                    !NativeGeofencePersistence.setLifecycleState(
                        context,
                        geofence.id,
                        recoveryEligible = true,
                        active = true
                    )
                ) {
                    callback?.invoke(
                        Result.failure(
                            FlutterError(
                                NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                                "The recovered geofence became active, but durable plugin " +
                                    "state could not be updated."
                            )
                        )
                    )
                    return@addOnSuccessListener
                }
                NativeGeofenceLogger.d(
                    context,
                    TAG,
                    "Successfully added Geofence ID=${geofence.id}.",
                )
                callback?.invoke(Result.success(Unit))
            }
            addOnFailureListener {
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Failed to add Geofence ID=${geofence.id}: $it",
                    it,
                )

                if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
                    != PackageManager.PERMISSION_GRANTED) {
                    NativeGeofenceLogger.e(
                        context,
                        TAG,
                        "Lacking permission: ACCESS_FINE_LOCATION",
                    )
                    callback?.invoke(
                        Result.failure(
                            FlutterError(
                                NativeGeofenceErrorCode.MISSING_LOCATION_PERMISSION.raw.toString(),
                                "The ACCESS_FINE_LOCATION needs to be granted in order to setup geofences."
                            )
                        )
                    )
                    return@addOnFailureListener
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    if (ContextCompat.checkSelfPermission(
                            context,
                            Manifest.permission.ACCESS_BACKGROUND_LOCATION
                        )
                        != PackageManager.PERMISSION_GRANTED
                    ) {
                        NativeGeofenceLogger.e(
                            context,
                            TAG,
                            "Running on API ${Build.VERSION.SDK_INT} and lacking permission: " +
                                "ACCESS_BACKGROUND_LOCATION",
                        )
                        callback?.invoke(
                            Result.failure(
                                FlutterError(
                                    NativeGeofenceErrorCode.MISSING_BACKGROUND_LOCATION_PERMISSION.raw.toString(),
                                    "The ACCESS_BACKGROUND_LOCATION needs to be granted in order to setup geofences.",
                                    "Running on Android API ${Build.VERSION.SDK_INT}."
                                )
                            )
                        )
                        return@addOnFailureListener
                    }
                }

                val failure = AndroidGeofenceFailureMapper.from(it)
                callback?.invoke(
                    Result.failure(
                        FlutterError(
                            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                            failure.message,
                            failure.details
                        )
                    )
                )
            }
        }
    }
}

internal fun persistCallbackDispatcherHandle(
    callbackDispatcherHandle: Long,
    persist: (Long) -> Boolean
) {
    if (!persist(callbackDispatcherHandle)) {
        throw FlutterError(
            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
            "Failed to durably persist the callback dispatcher handle."
        )
    }
}
