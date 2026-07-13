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
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceBroadcastReceiver
import com.chunkytofustudios.native_geofence.receivers.GeofenceRecoveryAggregateException
import com.chunkytofustudios.native_geofence.receivers.GeofenceRecoveryFailure
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceRecoveryFailures
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceRecoveryPolicy
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceRecoveryScheduler
import com.chunkytofustudios.native_geofence.receivers.RecoveryScheduleOutcome
import com.chunkytofustudios.native_geofence.util.ActiveGeofenceWires
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceAsyncOperation
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceFailureMapper
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRegistrationFailureStage
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRegistrationTransaction
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRegistrationTransactionException
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceTransactionStepOutcome
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRecoveryPlanner
import com.chunkytofustudios.native_geofence.util.GeofenceEvents
import com.chunkytofustudios.native_geofence.util.GeofenceMutationQueue
import com.chunkytofustudios.native_geofence.util.GeofenceMutationQueues
import com.chunkytofustudios.native_geofence.util.GeofenceMutationRunner
import com.chunkytofustudios.native_geofence.util.GeofenceWires
import com.chunkytofustudios.native_geofence.util.GeofencePersistenceSnapshot
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.LocationState
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import java.util.concurrent.atomic.AtomicBoolean

class NativeGeofenceApiImpl(private val context: Context) : NativeGeofenceApi {
    companion object {
        @JvmStatic
        private val TAG = "NativeGeofenceApiImpl"
    }

    private val geofencingClient = LocationServices.getGeofencingClient(context)
    private val mutationQueue: GeofenceMutationQueue = GeofenceMutationQueues.forContext(
        context
    ) { error ->
        NativeGeofenceLogger.e(
            context,
            TAG,
            "Unhandled geofence mutation failure.",
            error,
        )
    }
    private val mutationRunner = GeofenceMutationRunner(mutationQueue) { error ->
        NativeGeofenceLogger.e(
            context,
            TAG,
            "Geofence mutation callback threw an exception.",
            error,
        )
    }

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
        mutationRunner.run(callback) { complete ->
            createGeofenceHelper(geofence, true, complete)
        }
    }

    override fun reCreateAfterReboot(callback: (Result<Unit>) -> Unit) {
        startRecovery(
            "explicit_recreate_after_reboot",
            automatic = false,
            callback = callback
        )
    }

    internal fun startAutomaticRecovery(
        reason: String,
        callback: (Result<Unit>) -> Unit
    ) {
        startRecovery(reason, automatic = true, callback = callback)
    }

    private fun startRecovery(
        reason: String,
        automatic: Boolean,
        callback: (Result<Unit>) -> Unit
    ) {
        val completed = AtomicBoolean(false)
        fun finish(result: Result<Unit>) {
            if (completed.compareAndSet(false, true)) {
                callback(result)
            }
        }

        val generation = try {
            NativeGeofenceRecoveryScheduler.beginGeneration(context)
        } catch (error: Throwable) {
            finish(
                Result.failure(
                    FlutterError(
                        NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                        "Failed to start Android geofence recovery.",
                        error.toString()
                    )
                )
            )
            return
        }

        if (NativeGeofencePersistence.getAllRawGeofenceIds(context).isEmpty()) {
            NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
            finish(Result.success(Unit))
            return
        }

        if (!LocationState.hasFinePermission(context)) {
            NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
            finish(
                Result.failure(
                    FlutterError(
                        NativeGeofenceErrorCode.MISSING_LOCATION_PERMISSION.raw.toString(),
                        "The ACCESS_FINE_LOCATION permission is required to recover geofences."
                    )
                )
            )
            return
        }

        if (!LocationState.hasBackgroundPermission(context)) {
            NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
            finish(
                Result.failure(
                    FlutterError(
                        NativeGeofenceErrorCode.MISSING_BACKGROUND_LOCATION_PERMISSION.raw.toString(),
                        "The ACCESS_BACKGROUND_LOCATION permission is required to recover " +
                            "geofences on Android API ${Build.VERSION.SDK_INT}."
                    )
                )
            )
            return
        }

        if (automatic) {
            NativeGeofenceRecoveryScheduler.scheduleRetry(
                context = context,
                generation = generation,
                attempt = 1,
                reason = reason
            ) { outcome ->
                when (outcome) {
                    RecoveryScheduleOutcome.CONFIRMED -> {
                        if (!LocationState.isEnabled(context)) {
                            finish(Result.failure(locationDisabledRecoveryError()))
                        } else {
                            runImmediateRecovery(
                                generation,
                                reason,
                                automatic = true,
                                finish = ::finish
                            )
                        }
                    }
                    RecoveryScheduleOutcome.UNCONFIRMED -> {
                        finish(
                            Result.failure(
                                FlutterError(
                                    NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                                    "Android geofence recovery retry ownership could not be " +
                                        "confirmed; the durable retry ticket was retained."
                                )
                            )
                        )
                    }
                    RecoveryScheduleOutcome.REJECTED -> {
                        NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
                        finish(
                            Result.failure(
                                FlutterError(
                                    NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                                    "Failed to durably schedule Android geofence recovery."
                                )
                            )
                        )
                    }
                }
            }
            return
        }

        if (!LocationState.isEnabled(context)) {
            NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
            finish(Result.failure(locationDisabledRecoveryError()))
            return
        }

        runImmediateRecovery(
            generation,
            reason,
            automatic = false,
            finish = ::finish
        )
    }

    private fun runImmediateRecovery(
        generation: Long,
        reason: String,
        automatic: Boolean,
        finish: (Result<Unit>) -> Unit
    ) {
        recoverForGeneration(generation, reason) { result ->
            if (generation != NativeGeofenceRecoveryScheduler.currentGeneration(context)) {
                finish(publicRecoveryResult(result))
                return@recoverForGeneration
            }
            if (result.isSuccess) {
                NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
            } else {
                val error = result.exceptionOrNull()
                if (!automatic || error == null || !NativeGeofenceRecoveryPolicy.isRetryable(error)) {
                    NativeGeofenceRecoveryScheduler.completeGeneration(context, generation)
                }
            }
            finish(publicRecoveryResult(result))
        }
    }

    private fun publicRecoveryResult(result: Result<Unit>): Result<Unit> {
        val aggregate = result.exceptionOrNull() as? GeofenceRecoveryAggregateException
        return if (aggregate == null) result else Result.failure(aggregate.publicError)
    }

    private fun locationDisabledRecoveryError() = FlutterError(
        NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
        "Android location services are disabled; geofence recovery was deferred."
    )

    internal fun recoverForGeneration(
        generation: Long,
        reason: String,
        callback: (Result<Unit>) -> Unit
    ) {
        if (generation != NativeGeofenceRecoveryScheduler.currentGeneration(context)) {
            callback(Result.success(Unit))
            return
        }
        mutationRunner.run(callback) { complete ->
            if (generation == NativeGeofenceRecoveryScheduler.currentGeneration(context)) {
                recoverLocked(reason, complete)
            } else {
                complete(Result.success(Unit))
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

    override fun removeGeofenceById(id: String, callback: (Result<Unit>) -> Unit) {
        mutationRunner.run(callback) { complete ->
            removeGeofenceByIdLocked(id, complete)
        }
    }

    private fun removeGeofenceByIdLocked(id: String, callback: (Result<Unit>) -> Unit) {
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
        mutationRunner.run(callback) { complete ->
            removeAllGeofencesLocked(complete)
        }
    }

    private fun removeAllGeofencesLocked(callback: (Result<Unit>) -> Unit) {
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

    private fun recoverLocked(reason: String, callback: (Result<Unit>) -> Unit) {
        val recoveryInventory = NativeGeofencePersistence.getRecoveryInventory(context)
        val recoveryPlan = AndroidGeofenceRecoveryPlanner.plan(recoveryInventory)
        val recoverable = recoveryPlan.recoverable
        val orphanIds = recoveryPlan.cleanupIds
        val failures = mutableListOf<GeofenceRecoveryFailure>()
        for (id in recoveryPlan.unknownLifecycleIds) {
            failures.add(
                GeofenceRecoveryFailure(
                    id = id,
                    operation = "repair_lifecycle_metadata",
                    error = FlutterError(
                        NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                        "Geofence lifecycle metadata is not durably known; raw and " +
                            "canonical evidence was retained for a later repair.",
                    ),
                ),
            )
        }

        fun finish() {
            if (failures.isEmpty()) {
                NativeGeofenceLogger.d(
                    context,
                    TAG,
                    "Android geofence recovery completed: rearmed=${recoverable.size}, " +
                        "cleaned=${orphanIds.size}.",
                )
                callback(Result.success(Unit))
                return
            }

            callback(
                Result.failure(
                    NativeGeofenceRecoveryFailures.aggregate(reason, failures)
                )
            )
        }

        fun rearm(index: Int) {
            if (index >= recoverable.size) {
                finish()
                return
            }

            val geofence = recoverable[index]
            if (!NativeGeofencePersistence.setLifecycleState(
                    context,
                    geofence.id,
                    recoveryEligible = true,
                    active = false
                )
            ) {
                failures.add(
                    GeofenceRecoveryFailure(
                        id = geofence.id,
                        operation = "prepare_rearm",
                        error = FlutterError(
                            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                            "Failed to persist the inactive recovery state for a geofence."
                        )
                    )
                )
                rearm(index + 1)
                return
            }

            val completed = AtomicBoolean(false)
            fun advance(result: Result<Unit>) {
                if (completed.compareAndSet(false, true)) {
                    result.exceptionOrNull()?.let { error ->
                        failures.add(
                            GeofenceRecoveryFailure(
                                id = geofence.id,
                                operation = "rearm",
                                error = error
                            )
                        )
                    }
                    rearm(index + 1)
                }
            }
            try {
                // cache=false preserves the configured absolute deadline and
                // suppresses initial ENTER/DWELL triggers during rearm.
                createGeofenceHelper(geofence, cache = false, callback = ::advance)
            } catch (error: Throwable) {
                advance(Result.failure(error))
            }
        }

        fun cleanOrphan(index: Int) {
            if (index >= orphanIds.size) {
                rearm(0)
                return
            }

            val id = orphanIds[index]
            if (!NativeGeofencePersistence.markGeofenceForPlatformCleanup(context, id)) {
                failures.add(
                    GeofenceRecoveryFailure(
                        id = id,
                        operation = "clean_orphan",
                        error = FlutterError(
                            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                            "Failed to retain durable orphan cleanup evidence."
                        )
                    )
                )
                cleanOrphan(index + 1)
                return
            }
            val completed = AtomicBoolean(false)
            fun advance(result: Result<Unit>) {
                if (completed.compareAndSet(false, true)) {
                    result.exceptionOrNull()?.let { error ->
                        failures.add(
                            GeofenceRecoveryFailure(
                                id = id,
                                operation = "clean_orphan",
                                error = error
                            )
                        )
                    }
                    cleanOrphan(index + 1)
                }
            }
            try {
                geofencingClient.removeGeofences(listOf(id)).run {
                    addOnSuccessListener {
                        if (NativeGeofencePersistence.removeGeofence(context, id)) {
                            advance(Result.success(Unit))
                        } else {
                            advance(
                                Result.failure(
                                    FlutterError(
                                        NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                                        "Play services removed an orphan geofence, but its " +
                                            "durable cleanup marker could not be removed."
                                    )
                                )
                            )
                        }
                    }
                    addOnFailureListener { error ->
                        // Preserve the raw ID so a later recovery generation can
                        // retry platform cleanup.
                        val failure = AndroidGeofenceFailureMapper.from(error)
                        advance(
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
            } catch (error: Throwable) {
                advance(Result.failure(error))
            }
        }

        cleanOrphan(0)
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
