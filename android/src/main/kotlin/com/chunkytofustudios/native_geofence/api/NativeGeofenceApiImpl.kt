package com.chunkytofustudios.native_geofence.api

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
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
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceStatusWire
import com.chunkytofustudios.native_geofence.util.GeofenceEvents
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceBroadcastReceiver
import com.chunkytofustudios.native_geofence.util.ActiveGeofenceWires
import com.chunkytofustudios.native_geofence.util.GeofenceWires
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices

class NativeGeofenceApiImpl(private val context: Context) : NativeGeofenceApi {
    companion object {
        @JvmStatic
        private val TAG = "NativeGeofenceApiImpl"
    }

    private val geofencingClient = LocationServices.getGeofencingClient(context)

    override fun initialize(callbackDispatcherHandle: Long) {
        context.getSharedPreferences(Constants.SHARED_PREFERENCES_KEY, Context.MODE_PRIVATE)
            .edit()
            .putLong(Constants.CALLBACK_DISPATCHER_HANDLE_KEY, callbackDispatcherHandle)
            .apply()
        NativeGeofenceLogger.d(context, TAG, "Initialized NativeGeofenceApi.")
    }

    override fun createGeofence(
        geofence: GeofenceWire,
        callback: (Result<Unit>) -> Unit
    ) {
        createGeofenceHelper(geofence, true, callback)
    }

    override fun reCreateAfterReboot() {
        reCreateAfterReboot(reason = "api_recreate_after_reboot", onComplete = null)
    }

    fun reCreateAfterReboot(onComplete: (() -> Unit)?) {
        reCreateAfterReboot(reason = null, onComplete = onComplete)
    }

    fun reCreateAfterReboot(reason: String?, onComplete: (() -> Unit)?) {
        val geofences = NativeGeofencePersistence.getAllGeofences(context)
        NativeGeofenceDiagnostics.recordRecreateAttempt(context, geofences.size, reason)
        if (geofences.isEmpty()) {
            NativeGeofenceDiagnostics.recordRecreateSuccess(context, 0, reason)
            NativeGeofenceLogger.d(context, TAG, "No geofences to re-create.")
            onComplete?.invoke()
            return
        }
        val lock = Object()
        var remaining = geofences.size
        val failures = mutableListOf<String>()

        fun finishOne(geofenceId: String, result: Result<Unit>) {
            synchronized(lock) {
                result.exceptionOrNull()?.let { failures.add("$geofenceId: $it") }
                remaining -= 1
                if (remaining == 0) {
                    if (failures.isEmpty()) {
                        NativeGeofenceDiagnostics.recordRecreateSuccess(
                            context,
                            geofences.size,
                            reason
                        )
                        NativeGeofenceLogger.d(context, TAG, "${geofences.size} geofences re-created.")
                    } else {
                        val failureMessage = failures.joinToString("; ").take(1000)
                        NativeGeofenceDiagnostics.recordRecreateFailure(
                            context,
                            geofences.size,
                            reason,
                            failureMessage
                        )
                        NativeGeofenceLogger.e(context, TAG, "Failed to re-create some geofences: $failureMessage")
                    }
                    onComplete?.invoke()
                }
            }
        }

        NativeGeofenceLogger.d(context, TAG, "Re-creating ${geofences.size} geofences. reason=$reason")
        for (geofence in geofences) {
            // Broadcast receivers use goAsync(); invoke the completion only after
            // every async addGeofences call has finished.
            try {
                createGeofenceHelper(geofence, false) { result ->
                    finishOne(geofence.id, result)
                }
            } catch (e: Exception) {
                finishOne(geofence.id, Result.failure(e))
            }
        }
    }

    override fun getGeofenceIds(): List<String> {
        return NativeGeofencePersistence.getAllGeofenceIds(context)
    }

    override fun getGeofences(): List<ActiveGeofenceWire> {
        val geofences = NativeGeofencePersistence.getAllGeofences(context)
        return geofences.map { ActiveGeofenceWires.fromGeofenceWire(it) }.toList()
    }

    override fun getDiagnosticStatus(): NativeGeofenceStatusWire {
        val status = NativeGeofenceDiagnostics.getStatus(
            context,
            geofencePendingIntentExists = geofencePendingIntentExists(context)
        )
        NativeGeofenceLogger.i(context, TAG, "NativeGeofence diagnostic status: $status")
        return status
    }

    override fun removeGeofenceById(id: String, callback: (Result<Unit>) -> Unit) {
        NativeGeofenceDiagnostics.recordRemoveAttempt(context, listOf(id))
        geofencingClient.removeGeofences(listOf(id)).run {
            addOnSuccessListener {
                NativeGeofencePersistence.removeGeofence(context, id)
                NativeGeofenceDiagnostics.recordRemoveSuccess(context, listOf(id))
                NativeGeofenceLogger.d(context, TAG, "Removed Geofence ID=$id.")
                callback.invoke(Result.success(Unit))
            }
            addOnFailureListener {
                NativeGeofenceDiagnostics.recordRemoveFailure(context, listOf(id), it.toString())
                val existingIds = NativeGeofencePersistence.getAllGeofenceIds(context)
                val errorCode =
                    if (existingIds.contains(id)) NativeGeofenceErrorCode.PLUGIN_INTERNAL else NativeGeofenceErrorCode.GEOFENCE_NOT_FOUND
                NativeGeofenceLogger.e(context, TAG, "Failure when removing Geofence ID=$id: $it")
                callback.invoke(
                    Result.failure(
                        FlutterError(
                            errorCode.raw.toString(),
                            it.toString()
                        )
                    )
                )
            }
        }
    }

    override fun removeAllGeofences(callback: (Result<Unit>) -> Unit) {
        // Remove by request IDs so this works regardless of PendingIntent identity.
        val ids = NativeGeofencePersistence.getAllGeofenceIds(context)
        NativeGeofenceDiagnostics.recordRemoveAttempt(context, ids)
        if (ids.isEmpty()) {
            NativeGeofencePersistence.removeAllGeofences(context)
            NativeGeofenceDiagnostics.recordRemoveSuccess(context, ids)
            NativeGeofenceLogger.d(context, TAG, "Removed all geofences (if any).")
            callback.invoke(Result.success(Unit))
            return
        }

        geofencingClient.removeGeofences(ids).run {
            addOnSuccessListener {
                NativeGeofencePersistence.removeAllGeofences(context)
                NativeGeofenceDiagnostics.recordRemoveSuccess(context, ids)
                NativeGeofenceLogger.d(context, TAG, "Removed all geofences (if any).")
                callback.invoke(Result.success(Unit))
            }
            addOnFailureListener {
                NativeGeofenceDiagnostics.recordRemoveFailure(context, ids, it.toString())
                NativeGeofenceLogger.e(context, TAG, "Failed to remove all geofences: $it")
                callback.invoke(
                    Result.failure(
                        FlutterError(
                            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                            it.toString()
                        )
                    )
                )
            }
        }
    }

    private fun createGeofenceIntent(context: Context): Intent {
        val intent = Intent(context, NativeGeofenceBroadcastReceiver::class.java)
        // Keep one shared PendingIntent for all geofences. Android caps an app at
        // five geofence PendingIntents, and the receiver resolves per-geofence
        // callback handles from persisted triggered IDs.
        intent.action = "${context.packageName}.native_geofence.GEOFENCE_EVENT"
        return intent
    }

    private fun getGeofencePendingIntent(context: Context): PendingIntent {
        val intent = createGeofenceIntent(context)
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

    private fun geofencePendingIntentExists(context: Context): Boolean {
        val intent = createGeofenceIntent(context)
        val pendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.getBroadcast(
                context,
                0,
                intent,
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_MUTABLE
            )
        } else {
            PendingIntent.getBroadcast(
                context,
                0,
                intent,
                PendingIntent.FLAG_NO_CREATE
            )
        }
        return pendingIntent != null
    }

    @SuppressLint("MissingPermission")
    private fun createGeofenceHelper(
        geofence: GeofenceWire,
        cache: Boolean,
        callback: ((Result<Unit>) -> Unit)?
    ) {
        // Build errors are argument errors, not permission failures from Play services.
        val geofencingRequest = try {
            GeofencingRequest.Builder().apply {
                // Only fresh registrations should replay initial triggers. Reboot
                // and recovery paths would otherwise duplicate enter/exit events.
                setInitialTrigger(
                    if (cache)
                        GeofenceEvents.createMask(geofence.androidSettings.initialTriggers)
                    else
                        0
                )
                addGeofence(GeofenceWires.toGeofence(geofence))
            }.build()
        } catch (e: Exception) {
            NativeGeofenceLogger.e(context, TAG, "Failed to build Geofence ID=${geofence.id}: $e", e)
            callback?.invoke(
                Result.failure(
                    FlutterError(
                        NativeGeofenceErrorCode.INVALID_ARGUMENTS.raw.toString(),
                        e.toString()
                    )
                )
            )
            return
        }

        NativeGeofenceDiagnostics.recordRegisterAttempt(context, geofence.id)

        val previousGeofence =
            if (
                cache &&
                NativeGeofencePersistence.getAllGeofenceIds(context).contains(geofence.id)
            )
                NativeGeofencePersistence.getGeofence(context, geofence.id)
            else
                null
        if (cache) {
            NativeGeofencePersistence.saveGeofence(context, geofence)
        }

        fun restoreCachedGeofence() {
            if (!cache) {
                return
            }
            if (previousGeofence == null) {
                NativeGeofencePersistence.removeGeofence(context, geofence.id)
            } else {
                NativeGeofencePersistence.saveGeofence(context, previousGeofence)
            }
        }

        // We try to create the Geofence without checking for permissions.
        // Only if creation fails we will alert the Flutter plugin of the permission issue.
        geofencingClient.addGeofences(
            geofencingRequest,
            getGeofencePendingIntent(context)
        ).run {
            addOnSuccessListener {
                NativeGeofenceDiagnostics.recordRegisterSuccess(context, geofence.id)
                NativeGeofenceLogger.d(context, TAG, "Successfully added Geofence ID=${geofence.id}.")
                callback?.invoke(Result.success(Unit))
            }
            addOnFailureListener {
                restoreCachedGeofence()
                NativeGeofenceLogger.e(context, TAG, "Failed to add Geofence ID=${geofence.id}: $it")
                val statusCode = (it as? ApiException)?.statusCode
                NativeGeofenceDiagnostics.recordRegisterFailure(
                    context,
                    geofence.id,
                    statusCode?.let { code -> "GeofenceStatusCodes=$code" }
                        ?: it.javaClass.simpleName,
                    it.toString()
                )

                if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
                    != PackageManager.PERMISSION_GRANTED) {
                    NativeGeofenceLogger.e(context, TAG, "Lacking permission: ACCESS_FINE_LOCATION")
                    NativeGeofenceDiagnostics.recordRegisterFailure(
                        context,
                        geofence.id,
                        "MISSING_ACCESS_FINE_LOCATION",
                        "The ACCESS_FINE_LOCATION permission is not granted."
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
                        NativeGeofenceLogger.e(context, TAG, "Running on API ${Build.VERSION.SDK_INT} and lacking permission: ACCESS_BACKGROUND_LOCATION")
                        NativeGeofenceDiagnostics.recordRegisterFailure(
                            context,
                            geofence.id,
                            "MISSING_ACCESS_BACKGROUND_LOCATION",
                            "The ACCESS_BACKGROUND_LOCATION permission is not granted."
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

                // Surface Play services geofence limit/availability errors with an
                // actionable message instead of an opaque internal error. There is
                // no dedicated NativeGeofenceErrorCode for these yet, so the numeric
                // GeofenceStatusCodes value is included in details for diagnosis.
                val message = when (statusCode) {
                    GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE ->
                        "Geofence service is not available. Location may be turned off, " +
                            "or the device may be in battery-saver/airplane mode."
                    GeofenceStatusCodes.GEOFENCE_TOO_MANY_GEOFENCES ->
                        "Too many geofences: an app may register at most 100 geofences."
                    GeofenceStatusCodes.GEOFENCE_TOO_MANY_PENDING_INTENTS ->
                        "Too many geofence PendingIntents: an app may register geofences " +
                            "with at most 5 distinct PendingIntents."
                    else -> it.toString()
                }
                callback?.invoke(
                    Result.failure(
                        FlutterError(
                            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                            message,
                            statusCode?.let { code -> "GeofenceStatusCodes=$code" }
                        )
                    )
                )
            }
        }
    }
}
