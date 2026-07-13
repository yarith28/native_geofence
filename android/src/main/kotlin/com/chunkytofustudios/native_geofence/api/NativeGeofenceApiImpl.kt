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
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceAsyncOperation
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceFailureMapper
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRegistrationFailureStage
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRegistrationTransaction
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRegistrationTransactionException
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceTransactionStepOutcome
import com.chunkytofustudios.native_geofence.util.GeofenceWires
import com.chunkytofustudios.native_geofence.util.GeofencePersistenceSnapshot
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

    private fun getGeofencePendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, NativeGeofenceBroadcastReceiver::class.java)
        // Keep the historical action-less identity. Extras are deliberately
        // absent because every callback is resolved by triggered request ID
        // through durable registration storage.
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
        val geofencingRequest = try {
            buildGeofencingRequest(geofence, includeInitialTriggers = cache)
        } catch (e: Exception) {
            callback?.invoke(
                Result.failure(
                    FlutterError(
                        NativeGeofenceErrorCode.INVALID_ARGUMENTS.raw.toString(),
                        "Failed to build the Android geofencing request.",
                        e.toString()
                    )
                )
            )
            return
        }

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

        // Resolve and, if necessary, migrate the previous record before taking
        // its exact snapshot. Expired registrations become positive cleanup
        // evidence and are never granted a fresh lifetime by rollback.
        val previousRecoverable =
            NativeGeofencePersistence.getRecoverableGeofence(context, geofence.id)
        val previousStored = NativeGeofencePersistence.getStoredGeofence(context, geofence.id)
        val previousSnapshot = NativeGeofencePersistence.snapshot(context, geofence.id)
        val previousRegistrationExists = previousSnapshot.containsEvidenceFor(geofence.id)
        val previousPlatformGeofence = previousRecoverable?.takeIf {
            previousStored?.active == true && previousStored.lifecycleMetadataDurable
        }

        AndroidGeofenceRegistrationTransaction(
            previousRegistrationExists = previousRegistrationExists,
            previousPlatformRestorationRequired = previousPlatformGeofence != null,
            saveProvisional = {
                !cache || NativeGeofencePersistence.saveGeofence(
                    context,
                    geofence,
                    recoveryEligible = true,
                    active = false,
                )
            },
            markActive = {
                NativeGeofencePersistence.setLifecycleState(
                    context,
                    geofence.id,
                    recoveryEligible = true,
                    active = true,
                )
            },
            restoreDurableSnapshot = {
                NativeGeofencePersistence.restore(context, previousSnapshot)
            },
            preserveInactiveEvidence = {
                NativeGeofencePersistence.setLifecycleState(
                    context,
                    geofence.id,
                    recoveryEligible = previousStored?.recoveryEligible ?: true,
                    active = false,
                )
            },
            beginCurrentRegistration = {
                beginGeofenceAdd(geofencingRequest)
            },
            beginCompensation = {
                beginGeofenceRemoval(geofence.id)
            },
            beginPreviousPlatformRestoration = {
                beginGeofenceAdd(
                    buildGeofencingRequest(
                        requireNotNull(previousPlatformGeofence),
                        includeInitialTriggers = false,
                    ),
                )
            },
            completion = { result ->
                result.fold(
                    onSuccess = {
                        NativeGeofenceLogger.d(
                            context,
                            TAG,
                            "Successfully added Geofence ID=${geofence.id}.",
                        )
                        callback?.invoke(Result.success(Unit))
                    },
                    onFailure = { error ->
                        val failure = error as AndroidGeofenceRegistrationTransactionException
                        NativeGeofenceLogger.e(
                            context,
                            TAG,
                            "Failed to add Geofence ID=${geofence.id}: ${failure.message}",
                            failure.primaryCause ?: failure,
                        )
                        callback?.invoke(
                            Result.failure(mapRegistrationTransactionFailure(failure)),
                        )
                    },
                )
            },
        ).start()
    }

    private fun buildGeofencingRequest(
        geofence: GeofenceWire,
        includeInitialTriggers: Boolean,
    ): GeofencingRequest = GeofencingRequest.Builder().apply {
        setInitialTrigger(
            if (includeInitialTriggers) {
                GeofenceEvents.createMask(geofence.androidSettings.initialTriggers)
            } else {
                0
            },
        )
        addGeofence(GeofenceWires.toGeofence(geofence))
    }.build()

    @SuppressLint("MissingPermission")
    private fun beginGeofenceAdd(
        request: GeofencingRequest,
    ): AndroidGeofenceAsyncOperation {
        val task = geofencingClient.addGeofences(request, getGeofencePendingIntent(context))
        return AndroidGeofenceAsyncOperation { onSuccess, onFailure ->
            task.addOnSuccessListener { onSuccess() }
            task.addOnFailureListener(onFailure)
        }
    }

    private fun beginGeofenceRemoval(id: String): AndroidGeofenceAsyncOperation {
        val task = geofencingClient.removeGeofences(listOf(id))
        return AndroidGeofenceAsyncOperation { onSuccess, onFailure ->
            task.addOnSuccessListener { onSuccess() }
            task.addOnFailureListener(onFailure)
        }
    }

    private fun mapRegistrationTransactionFailure(
        failure: AndroidGeofenceRegistrationTransactionException,
    ): FlutterError {
        val platformFailureCleanlyRolledBack =
            failure.stage == AndroidGeofenceRegistrationFailureStage.PLATFORM_REGISTRATION &&
                failure.compensation == AndroidGeofenceTransactionStepOutcome.NOT_ATTEMPTED &&
                failure.durableRestoration == AndroidGeofenceTransactionStepOutcome.SUCCEEDED
        if (platformFailureCleanlyRolledBack) {
            if (
                ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Lacking permission: ACCESS_FINE_LOCATION",
                )
                return FlutterError(
                    NativeGeofenceErrorCode.MISSING_LOCATION_PERMISSION.raw.toString(),
                    "The ACCESS_FINE_LOCATION needs to be granted in order to setup geofences.",
                )
            }

            if (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_BACKGROUND_LOCATION,
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Running on API ${Build.VERSION.SDK_INT} and lacking permission: " +
                        "ACCESS_BACKGROUND_LOCATION",
                )
                return FlutterError(
                    NativeGeofenceErrorCode.MISSING_BACKGROUND_LOCATION_PERMISSION.raw.toString(),
                    "The ACCESS_BACKGROUND_LOCATION needs to be granted in order to setup geofences.",
                    "Running on Android API ${Build.VERSION.SDK_INT}.",
                )
            }

            failure.primaryCause?.let { cause ->
                val mapped = AndroidGeofenceFailureMapper.from(cause)
                return FlutterError(
                    NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                    mapped.message,
                    mapped.details,
                )
            }
        }

        return FlutterError(
            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
            failure.message,
            failure.privacySafeDetails(),
        )
    }

    private fun GeofencePersistenceSnapshot.containsEvidenceFor(id: String): Boolean =
        recordJson.present ||
            expirationDeadlineMillis.present ||
            recoveryEligible.present ||
            active.present ||
            rawIds.value.orEmpty().contains(id) ||
            configuredIds.value.orEmpty().contains(id)
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
