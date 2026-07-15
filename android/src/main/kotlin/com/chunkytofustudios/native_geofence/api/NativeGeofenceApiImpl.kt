package com.chunkytofustudios.native_geofence.api

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.ActiveGeofenceWire
import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceApi
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceCallbackRefreshState
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode
import com.chunkytofustudios.native_geofence.generated.NativeGeofencePlatform
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceStatusWire
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceSynchronizationReasonWire
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceSynchronizationResultWire
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceSynchronizationStateWire
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceBroadcastReceiver
import com.chunkytofustudios.native_geofence.receivers.GeofenceRecoveryAggregateException
import com.chunkytofustudios.native_geofence.receivers.GeofenceRecoveryFailure
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceRecoveryFailures
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceRecoveryPolicy
import com.chunkytofustudios.native_geofence.receivers.NativeGeofenceRecoveryScheduler
import com.chunkytofustudios.native_geofence.receivers.RecoveryScheduleOutcome
import com.chunkytofustudios.native_geofence.util.ActiveGeofenceWires
import com.chunkytofustudios.native_geofence.util.AndroidCallbackRefreshPolicy
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceAsyncOperation
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceFailureMapper
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceMutationKind
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRecoveryPlanner
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRegistrationFailureStage
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRegistrationPersistence
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRegistrationPersistenceMode
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRegistrationTransaction
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRegistrationTransactionException
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceRollbackRestorationOutcome
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceSynchronizationPlanner
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceSynchronizationReason
import com.chunkytofustudios.native_geofence.util.AndroidGeofenceTransactionStepOutcome
import com.chunkytofustudios.native_geofence.util.AndroidNativeGeofenceStatusProvider
import com.chunkytofustudios.native_geofence.util.AndroidPackageFingerprint
import com.chunkytofustudios.native_geofence.util.AndroidPackageManagerCompat
import com.chunkytofustudios.native_geofence.util.CallbackRefreshScopeSnapshot
import com.chunkytofustudios.native_geofence.util.GeofenceEvents
import com.chunkytofustudios.native_geofence.util.GeofenceMutationQueue
import com.chunkytofustudios.native_geofence.util.GeofenceMutationQueues
import com.chunkytofustudios.native_geofence.util.GeofenceMutationRunner
import com.chunkytofustudios.native_geofence.util.GeofencePersistenceSnapshot
import com.chunkytofustudios.native_geofence.util.GeofenceRegistrationStore
import com.chunkytofustudios.native_geofence.util.GeofenceWires
import com.chunkytofustudios.native_geofence.util.PersistedValue
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.LocationState
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.chunkytofustudios.native_geofence.util.NativeGeofenceIo
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnosticStage
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnostics
import com.chunkytofustudios.native_geofence.util.StoredGeofenceRegistration
import com.chunkytofustudios.native_geofence.util.attachWithGeofenceMutationDeadline
import com.chunkytofustudios.native_geofence.util.runAndroidGeofenceAsyncOperation
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
    private val dispatcherRecoveryAdmission = CallbackDispatcherRecoveryAdmission()

    override fun initialize(callbackDispatcherHandle: Long) {
        val packageFingerprint = AndroidPackageFingerprint.current(context)
        initializeCallbackDispatcher(
            callbackDispatcherHandle = callbackDispatcherHandle,
            persist = { handle ->
                context.getSharedPreferences(
                    Constants.SHARED_PREFERENCES_KEY,
                    Context.MODE_PRIVATE
                )
                    .edit()
                    .putLong(Constants.CALLBACK_DISPATCHER_HANDLE_KEY, handle)
                    .putString(
                        Constants.CALLBACK_DISPATCHER_PACKAGE_FINGERPRINT_KEY,
                        packageFingerprint
                    )
                    .commit()
            },
            afterPersisted = ::retryRecoveryAfterDispatcherInitialization,
        )
        NativeGeofenceLogger.d(context, TAG, "Initialized NativeGeofenceApi.")
    }

    private fun retryRecoveryAfterDispatcherInitialization() {
        val hasRecoveryEvidence = try {
            NativeGeofencePersistence.getAllRawGeofenceIds(context).isNotEmpty()
        } catch (error: Throwable) {
            NativeGeofenceLogger.w(
                context,
                TAG,
                "Could not inspect geofence recovery evidence after dispatcher initialization.",
                error,
            )
            return
        }
        if (!dispatcherRecoveryAdmission.tryAcquire(hasRecoveryEvidence)) return

        try {
            startAutomaticRecovery("callback_dispatcher_initialization") { result ->
                result.exceptionOrNull()?.let { error ->
                    NativeGeofenceLogger.w(
                        context,
                        TAG,
                        "Dispatcher-initialization geofence recovery did not complete.",
                        error,
                    )
                }
            }
        } catch (error: Throwable) {
            dispatcherRecoveryAdmission.releaseAfterStartFailure()
            NativeGeofenceLogger.w(
                context,
                TAG,
                "Dispatcher-initialization geofence recovery could not start.",
                error,
            )
        }
    }

    override fun createGeofence(
        geofence: GeofenceWire,
        callback: (Result<Unit>) -> Unit
    ) {
        mutationRunner.run({ result ->
            NativeGeofenceDiagnostics.record(
                context,
                NativeGeofenceDiagnosticStage.REGISTRATION,
                succeeded = result.isSuccess,
                outcome = if (result.isSuccess) "registered" else "registration_failed",
                geofenceCount = 1
            )
            callback(result)
        }) { complete ->
            createGeofenceHelper(geofence, true, complete)
        }
    }

    override fun restoreGeofence(
        geofence: GeofenceWire,
        expirationDeadlineMillis: Long?,
        callback: (Result<Unit>) -> Unit,
    ) {
        mutationRunner.run(callback) { complete ->
            if (!AndroidGeofenceSynchronizationPlanner.hasConsistentRollbackDeadline(
                    configuredGeofence = geofence,
                    expirationDeadlineMillis = expirationDeadlineMillis,
                )
            ) {
                complete(
                    Result.failure(
                        FlutterError(
                            NativeGeofenceErrorCode.INVALID_ARGUMENTS.raw.toString(),
                            "An Android rollback restore requires an absolute expiration " +
                                "deadline exactly when the configured geofence is finite.",
                        ),
                    ),
                )
                return@run
            }
            val nowMillis = System.currentTimeMillis()
            val platformGeofence = AndroidGeofenceSynchronizationPlanner
                .platformRegistrationForRollback(
                    configuredGeofence = geofence,
                    expirationDeadlineMillis = expirationDeadlineMillis,
                    nowMillis = nowMillis,
                )
            if (platformGeofence == null) {
                removeGeofenceByIdLocked(geofence.id, complete)
                return@run
            }
            createGeofenceHelper(
                geofence = platformGeofence,
                cache = true,
                callback = complete,
                configuredGeofence = geofence,
                expirationDeadlineMillisOverride = expirationDeadlineMillis,
                includeInitialTriggers = false,
            )
        }
    }

    override fun reCreateAfterReboot(callback: (Result<Unit>) -> Unit) {
        startRecovery(
            "explicit_recreate_after_reboot",
            automatic = false,
            callback = callback
        )
    }

    override fun getStatus(callback: (Result<NativeGeofenceStatusWire>) -> Unit) {
        NativeGeofenceIo.execute {
            val result = runCatching { AndroidNativeGeofenceStatusProvider(context).status() }
            Handler(Looper.getMainLooper()).post { callback(result) }
        }
    }

    override fun getSynchronizationState(
        desiredRegistrations: List<GeofenceWire>,
        callback: (Result<NativeGeofenceSynchronizationStateWire>) -> Unit
    ) {
        mutationQueue.enqueue { queueComplete ->
            NativeGeofenceIo.execute {
                val result = runCatching {
                    inspectSynchronizationState(desiredRegistrations).state
                }
                Handler(Looper.getMainLooper()).post {
                    try {
                        callback(result)
                    } catch (error: Throwable) {
                        NativeGeofenceLogger.e(
                            context,
                            TAG,
                            "Synchronization inspection callback threw.",
                            error,
                        )
                    } finally {
                        queueComplete()
                    }
                }
            }
        }
    }

    override fun synchronizeGeofences(
        desiredRegistrations: List<GeofenceWire>,
        removeUnlisted: Boolean,
        callback: (Result<NativeGeofenceSynchronizationResultWire>) -> Unit
    ) {
        mutationRunner.run(callback) { complete ->
            synchronizeGeofencesLocked(
                desiredRegistrations,
                removeUnlisted,
                complete
            )
        }
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
                NativeGeofenceDiagnostics.record(
                    context,
                    NativeGeofenceDiagnosticStage.RECOVERY,
                    succeeded = result.isSuccess,
                    outcome = if (result.isSuccess) "completed" else "failed",
                    geofenceCount = NativeGeofencePersistence
                        .getAllRawGeofenceIds(context)
                        .size
                )
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
        return NativeGeofencePersistence.getAllRegisteredGeofenceSnapshots(context).map {
            ActiveGeofenceWires.fromGeofenceWire(
                it.configuredGeofence,
                it.expirationDeadlineMillis,
            )
        }
    }

    override fun removeGeofenceById(id: String, callback: (Result<Unit>) -> Unit) {
        mutationRunner.run({ result ->
            NativeGeofenceDiagnostics.record(
                context,
                NativeGeofenceDiagnosticStage.REMOVAL,
                succeeded = result.isSuccess,
                outcome = if (result.isSuccess) "removed_by_id" else "removal_failed",
                geofenceCount = 1
            )
            callback(result)
        }) { complete ->
            removeGeofenceByIdLocked(id, complete)
        }
    }

    private fun removeGeofenceByIdLocked(id: String, callback: (Result<Unit>) -> Unit) {
        val completed = AtomicBoolean(false)
        fun fail(error: Throwable) {
            if (!completed.compareAndSet(false, true)) return
            val failure = AndroidGeofenceFailureMapper.from(error)
            NativeGeofenceLogger.e(
                context,
                TAG,
                "Failure when removing Geofence ID=$id: $error",
                error,
            )
            callback(
                Result.failure(
                    FlutterError(
                        NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                        failure.message,
                        failure.details
                    )
                )
            )
        }

        val task = try {
            geofencingClient.removeGeofences(listOf(id))
        } catch (error: Throwable) {
            fail(error)
            return
        }
        try {
            task.attachWithGeofenceMutationDeadline(
                kind = AndroidGeofenceMutationKind.REMOVAL,
                onSuccess = onSuccess@{
                    if (!completed.compareAndSet(false, true)) return@onSuccess
                    if (!NativeGeofencePersistence.removeGeofence(context, id)) {
                        callback(
                            Result.failure(
                                FlutterError(
                                    NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                                    "The geofence was removed from Play services, but durable " +
                                        "plugin state could not be updated."
                                )
                            )
                        )
                        return@onSuccess
                    }
                    NativeGeofenceLogger.d(context, TAG, "Removed Geofence ID=$id.")
                    callback(Result.success(Unit))
                },
                onFailure = ::fail
            )
        } catch (error: Throwable) {
            fail(error)
        }
    }

    override fun removeAllGeofences(callback: (Result<Unit>) -> Unit) {
        val requestedCount = NativeGeofencePersistence.getAllRawGeofenceIds(context).size
        mutationRunner.run({ result ->
            NativeGeofenceDiagnostics.record(
                context,
                NativeGeofenceDiagnosticStage.REMOVAL,
                succeeded = result.isSuccess,
                outcome = if (result.isSuccess) "removed_all" else "remove_all_failed",
                geofenceCount = requestedCount
            )
            callback(result)
        }) { complete ->
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

        fun fail(error: Throwable) {
            val failure = AndroidGeofenceFailureMapper.from(error)
            NativeGeofenceLogger.e(
                context,
                TAG,
                "Failed to remove all geofences: $error",
                error,
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

        runAndroidGeofenceAsyncOperation(
            begin = { beginGeofenceRemoval(rawIds) },
            onSuccess = onSuccess@{
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
                    return@onSuccess
                }
                NativeGeofenceLogger.d(context, TAG, "Removed all geofences (if any).")
                callback.invoke(Result.success(Unit))
            },
            onFailure = ::fail,
        )
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
                geofencingClient.removeGeofences(listOf(id))
                    .attachWithGeofenceMutationDeadline(
                        kind = AndroidGeofenceMutationKind.REMOVAL,
                        onSuccess = {
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
                        },
                        onFailure = { error ->
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
                    )
            } catch (error: Throwable) {
                advance(Result.failure(error))
            }
        }

        cleanOrphan(0)
    }

    private data class SynchronizationInspectionSnapshot(
        val storedRegistrations: List<StoredGeofenceRegistration>,
        val rawIds: List<String>,
        val state: NativeGeofenceSynchronizationStateWire,
        val inspectedAtMillis: Long,
    )

    private data class SynchronizationSnapshot(
        val persistence: List<GeofencePersistenceSnapshot>,
        val activePlatformRegistrations: List<StoredGeofenceRegistration>,
        val registrationFingerprint: String?,
        val callbackRefreshScope: CallbackRefreshScopeSnapshot
    )

    /** Reads synchronization evidence without migrating or repairing persistence. */
    private fun inspectSynchronizationState(
        desired: List<GeofenceWire>,
    ): SynchronizationInspectionSnapshot {
        val inspectedAtMillis = System.currentTimeMillis()
        val stored = NativeGeofencePersistence.inspectAllStoredConfiguredGeofences(context)
        val rawIds = NativeGeofencePersistence.getAllRawGeofenceIds(context)
        val desiredIds = desired.map { it.id }.toSet()
        val storedById = stored.associateBy { it.configuredGeofence.id }
        val scopedRegistrations = desired.mapNotNull { storedById[it.id] }
        val currentPackageFingerprint = AndroidPackageFingerprint.current(context)
        val dispatcherPackageFingerprint = context.getSharedPreferences(
            Constants.SHARED_PREFERENCES_KEY,
            Context.MODE_PRIVATE
        ).getString(Constants.CALLBACK_DISPATCHER_PACKAGE_FINGERPRINT_KEY, null)
        val refreshState = AndroidCallbackRefreshPolicy.evaluate(
            currentFingerprint = currentPackageFingerprint,
            dispatcherFingerprint = dispatcherPackageFingerprint,
            registrationFingerprints = scopedRegistrations.map {
                it.callbackPackageFingerprint
            },
            callbackRefreshRequired = NativeGeofencePersistence
                .isCallbackRefreshRequiredFor(context, desiredIds)
        )
        val state = NativeGeofenceSynchronizationStateWire(
            platform = NativeGeofencePlatform.ANDROID,
            pluginOwnedIds = rawIds,
            registrations = stored.map { it.configuredGeofence },
            inactiveRegistrationIds = AndroidGeofenceSynchronizationPlanner
                .incompleteRegistrationIds(stored, rawIds, inspectedAtMillis),
            registrationFingerprint = NativeGeofencePersistence
                .getSynchronizationFingerprint(context),
            desiredRegistrationFingerprint = AndroidGeofenceSynchronizationPlanner
                .desiredRegistrationFingerprint(desired),
            callbackFingerprintCurrent = scopedRegistrations.isEmpty() ||
                refreshState == NativeGeofenceCallbackRefreshState.CURRENT,
            iosMaximumRegionMonitoringDistance = null,
        )
        return SynchronizationInspectionSnapshot(
            storedRegistrations = stored,
            rawIds = rawIds,
            state = state,
            inspectedAtMillis = inspectedAtMillis,
        )
    }

    private fun AndroidGeofenceSynchronizationReason.toWire() = when (this) {
        AndroidGeofenceSynchronizationReason.FIRST_RUN ->
            NativeGeofenceSynchronizationReasonWire.FIRST_RUN
        AndroidGeofenceSynchronizationReason.CALLBACK_FINGERPRINT_CHANGED ->
            NativeGeofenceSynchronizationReasonWire.CALLBACK_FINGERPRINT_CHANGED
        AndroidGeofenceSynchronizationReason.REGISTRATION_DRIFT ->
            NativeGeofenceSynchronizationReasonWire.REGISTRATION_DRIFT
    }

    private fun synchronizeGeofencesLocked(
        desired: List<GeofenceWire>,
        removeUnlisted: Boolean,
        callback: (Result<NativeGeofenceSynchronizationResultWire>) -> Unit
    ) {
        if (desired.map { it.id }.toSet().size != desired.size) {
            callback(
                Result.failure(
                    FlutterError(
                        NativeGeofenceErrorCode.INVALID_ARGUMENTS.raw.toString(),
                        "Synchronization registrations contain duplicate geofence IDs."
                    )
                )
            )
            return
        }
        val inspection = inspectSynchronizationState(desired)
        val current = inspection.storedRegistrations
        val rawIds = inspection.rawIds
        val currentPackageFingerprint = AndroidPackageFingerprint.current(context)
        val decision = AndroidGeofenceSynchronizationPlanner.decide(
            current = current,
            rawIds = rawIds,
            desired = desired,
            removeUnlisted = removeUnlisted,
            currentPackageFingerprint = currentPackageFingerprint,
            currentRegistrationFingerprint = inspection.state.registrationFingerprint,
            callbackFingerprintCurrent = inspection.state.callbackFingerprintCurrent,
            nowMillis = inspection.inspectedAtMillis,
        )
        val resultWire = NativeGeofenceSynchronizationResultWire(
            didSynchronize = decision.requiresSynchronization,
            reasons = decision.reasons.map { it.toWire() },
            desiredCount = decision.desiredCount.toLong(),
            previousCount = decision.previousCount.toLong(),
            registrationFingerprint = decision.desiredRegistrationFingerprint,
        )
        if (!decision.requiresSynchronization) {
            callback(Result.success(resultWire))
            return
        }

        // Capture every durable byte before any migration, metadata refresh, or
        // platform call performed by this transaction.
        val snapshotIds = (rawIds + desired.map { it.id }).toSet().sorted()
        val snapshot = SynchronizationSnapshot(
            persistence = snapshotIds.map { NativeGeofencePersistence.snapshot(context, it) },
            activePlatformRegistrations = current.filter { it.active },
            registrationFingerprint = NativeGeofencePersistence
                .getSynchronizationFingerprint(context),
            callbackRefreshScope = NativeGeofencePersistence
                .snapshotCallbackRefreshScope(context)
        )
        val plan = decision.plan
        val platformTouchedIds = linkedSetOf<String>()
        val terminalStarted = AtomicBoolean(false)

        fun fail(error: Throwable) {
            if (!terminalStarted.compareAndSet(false, true)) return
            rollbackSynchronization(snapshot, platformTouchedIds.toSet()) { rollbackFailures ->
                val flutterError = error as? FlutterError
                callback(
                    Result.failure(
                        FlutterError(
                            flutterError?.code
                                ?: NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                            (flutterError?.message
                                ?: "Android geofence synchronization failed.") +
                                if (rollbackFailures.isEmpty()) {
                                    ""
                                } else {
                                    " Rollback failed for ${rollbackFailures.size} operation(s)."
                                },
                            buildString {
                                flutterError?.details?.let { append(it.toString()).append('\n') }
                                if (rollbackFailures.isEmpty()) {
                                    append("rollback: succeeded")
                                } else {
                                    for (rollbackFailure in rollbackFailures) {
                                        append("rollback: ")
                                            .append(rollbackFailure)
                                            .append('\n')
                                    }
                                }
                            }.trimEnd()
                        )
                    )
                )
            }
        }

        fun finishSynchronization() {
            if (terminalStarted.get()) return
            val committed = if (removeUnlisted) {
                NativeGeofencePersistence.commitSynchronization(
                    context,
                    decision.desiredRegistrationFingerprint
                )
            } else {
                NativeGeofencePersistence.commitPartialSynchronization(
                    context,
                    desired.map { it.id }.toSet()
                )
            }
            if (!committed) {
                fail(
                    FlutterError(
                        NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                        "Failed to persist synchronization completion evidence."
                    )
                )
                return
            }
            if (terminalStarted.compareAndSet(false, true)) {
                callback(Result.success(resultWire))
            }
        }

        lateinit var upsertAt: (Int) -> Unit

        fun removeAt(index: Int) {
            if (terminalStarted.get()) return
            if (index >= plan.removeIds.size) {
                for (wanted in plan.metadataOnlyUpdates) {
                    if (terminalStarted.get()) return
                    if (!NativeGeofencePersistence.updateCallbackMetadata(context, wanted)) {
                        fail(
                            FlutterError(
                                NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                                "Failed to refresh synchronized callback metadata."
                            )
                        )
                        return
                    }
                }
                upsertAt(0)
                return
            }
            val id = plan.removeIds[index]
            platformTouchedIds.add(id)
            try {
                removeGeofenceByIdLocked(id) { result ->
                    result.fold(
                        onSuccess = { removeAt(index + 1) },
                        onFailure = ::fail
                    )
                }
            } catch (error: Throwable) {
                fail(error)
            }
        }

        upsertAt = fun(index: Int) {
            if (terminalStarted.get()) return
            if (index >= plan.platformUpserts.size) {
                finishSynchronization()
                return
            }
            val wanted = plan.platformUpserts[index]
            val prepared = try {
                NativeGeofencePersistence.prepareGeofenceForSynchronization(
                    context,
                    wanted
                )
            } catch (error: Throwable) {
                fail(error)
                return
            }
            val platformWire = prepared.platformGeofence
            if (platformWire == null) {
                fail(
                    FlutterError(
                        NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                        "A synchronized geofence had no usable remaining lifetime."
                    )
                )
                return
            }
            platformTouchedIds.add(wanted.id)
            try {
                createGeofenceHelper(
                    platformWire,
                    cache = false,
                    callback = synchronizationCreate@ { result ->
                        if (terminalStarted.get()) return@synchronizationCreate
                        result.fold(
                            onSuccess = {
                                if (!NativeGeofencePersistence.commitGeofenceForSynchronization(
                                        context,
                                        prepared
                                    )
                                ) {
                                    fail(
                                        FlutterError(
                                            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                                            "The synchronized geofence became active, but its " +
                                                "durable state could not be committed."
                                        )
                                    )
                                } else {
                                    upsertAt(index + 1)
                                }
                            },
                            onFailure = ::fail
                        )
                    },
                )
            } catch (error: Throwable) {
                fail(error)
            }
        }

        // Remove first so replacing a full 100-registration set never exceeds
        // Play services' capacity during the transaction.
        removeAt(0)
    }

    private fun rollbackSynchronization(
        snapshot: SynchronizationSnapshot,
        platformTouchedIds: Set<String>,
        completion: (List<String>) -> Unit
    ) {
        val failures = mutableListOf<String>()
        val rollbackPlan = AndroidGeofenceSynchronizationPlanner.rollbackPlan(
            platformTouchedIds = platformTouchedIds,
            previouslyActive = snapshot.activePlatformRegistrations,
        )
        val cleanupIds = rollbackPlan.cleanupIds
        val platformRegistrationsToRestore = rollbackPlan.platformRegistrationsToRestore
        val restorationOutcomes =
            mutableMapOf<String, AndroidGeofenceRollbackRestorationOutcome>()
        var cleanupFailed = false

        fun restorePersistence() {
            for (persisted in snapshot.persistence) {
                if (!NativeGeofencePersistence.restore(context, persisted)) {
                    failures.add("failed to restore durable registration state")
                }
            }
            if (!NativeGeofencePersistence.restoreSynchronizationFingerprint(
                    context,
                    snapshot.registrationFingerprint
                )
            ) {
                failures.add("failed to restore the synchronization fingerprint")
            }
            if (!NativeGeofencePersistence.restoreCallbackRefreshScope(
                    context,
                    snapshot.callbackRefreshScope
                )
            ) {
                failures.add("failed to restore callback-refresh scope")
            }
        }

        fun finish() {
            // Rearm temporarily marks registrations active. Reapply the exact
            // snapshot so deadlines, active flags, contexts, and fingerprints
            // match the pre-transaction bytes, then overlay only the conservative
            // ownership evidence learned while rollback was in flight.
            restorePersistence()
            val evidencePlan = AndroidGeofenceSynchronizationPlanner.rollbackEvidencePlan(
                cleanupFailed = cleanupFailed,
                cleanupIds = cleanupIds,
                previouslyActive = snapshot.activePlatformRegistrations,
                restorationOutcomes = restorationOutcomes
            )
            for (id in evidencePlan.cleanupMarkerIds) {
                if (!NativeGeofencePersistence.markGeofenceForPlatformCleanup(context, id)) {
                    failures.add("failed to retain native cleanup ownership evidence")
                }
            }
            for (id in evidencePlan.inactiveRecoveryIds) {
                if (!NativeGeofencePersistence.markGeofenceForRecovery(context, id)) {
                    failures.add("failed to retain inactive native recovery evidence")
                }
            }
            if (evidencePlan.requiresRecovery) {
                try {
                    startAutomaticRecovery("synchronization_rollback") { result ->
                        result.exceptionOrNull()?.let { error ->
                            NativeGeofenceLogger.e(
                                context,
                                TAG,
                                "Automatic recovery after synchronization rollback failed.",
                                error
                            )
                        }
                    }
                } catch (error: Throwable) {
                    failures.add("failed to start recovery after synchronization rollback")
                    NativeGeofenceLogger.e(
                        context,
                        TAG,
                        "Failed to start recovery after synchronization rollback.",
                        error
                    )
                }
            }
            completion(failures)
        }

        fun rearmAt(index: Int) {
            if (index >= platformRegistrationsToRestore.size) {
                finish()
                return
            }
            val snapshotRegistration = platformRegistrationsToRestore[index]
            val platformRegistration = AndroidGeofenceSynchronizationPlanner
                .platformRegistrationForRollback(
                    configuredGeofence = snapshotRegistration.configuredGeofence,
                    expirationDeadlineMillis = snapshotRegistration.expirationDeadlineMillis,
                    nowMillis = System.currentTimeMillis(),
                )
            if (platformRegistration == null) {
                // Its original absolute deadline elapsed while the transaction
                // or rollback was in flight; never grant it a fresh duration.
                restorationOutcomes[snapshotRegistration.configuredGeofence.id] =
                    AndroidGeofenceRollbackRestorationOutcome.EXPIRED
                rearmAt(index + 1)
                return
            }
            try {
                createGeofenceHelper(
                    geofence = platformRegistration,
                    cache = false,
                    callback = { result ->
                        if (result.isSuccess) {
                            restorationOutcomes[snapshotRegistration.configuredGeofence.id] =
                                AndroidGeofenceRollbackRestorationOutcome.RESTORED
                        } else {
                            restorationOutcomes[snapshotRegistration.configuredGeofence.id] =
                                AndroidGeofenceRollbackRestorationOutcome.FAILED
                            failures.add("failed to rearm a previous native registration")
                        }
                        rearmAt(index + 1)
                    },
                    configuredGeofence = snapshotRegistration.configuredGeofence,
                    expirationDeadlineMillisOverride =
                        snapshotRegistration.expirationDeadlineMillis,
                    includeInitialTriggers = false,
                )
            } catch (_: Throwable) {
                restorationOutcomes[snapshotRegistration.configuredGeofence.id] =
                    AndroidGeofenceRollbackRestorationOutcome.FAILED
                failures.add("failed to rearm a previous native registration")
                rearmAt(index + 1)
            }
        }

        fun restoreAndRearm() {
            restorePersistence()
            rearmAt(0)
        }

        if (cleanupIds.isEmpty()) {
            restoreAndRearm()
            return
        }
        val cleanupCompleted = AtomicBoolean(false)
        fun completeCleanup(failed: Boolean) {
            if (!cleanupCompleted.compareAndSet(false, true)) return
            cleanupFailed = failed
            if (failed) {
                failures.add("failed to clear transaction-owned native registrations")
            }
            restoreAndRearm()
        }
        try {
            geofencingClient.removeGeofences(cleanupIds)
                .attachWithGeofenceMutationDeadline(
                    kind = AndroidGeofenceMutationKind.REMOVAL,
                    onSuccess = { completeCleanup(failed = false) },
                    onFailure = { completeCleanup(failed = true) }
                )
        } catch (_: Throwable) {
            completeCleanup(failed = true)
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
            AndroidPackageManagerCompat.getReceiverInfo(
                context.packageManager,
                component,
            )
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
        callback: ((Result<Unit>) -> Unit)?,
        configuredGeofence: GeofenceWire = geofence,
        expirationDeadlineMillisOverride: Long? = null,
        includeInitialTriggers: Boolean = cache,
    ) {
        val geofencingRequest = try {
            buildGeofencingRequest(geofence, includeInitialTriggers = includeInitialTriggers)
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
            NativeGeofencePersistence.getRecoverableGeofence(context, configuredGeofence.id)
        val previousStored = NativeGeofencePersistence.getStoredGeofence(
            context,
            configuredGeofence.id,
        )
        val previousSnapshot = NativeGeofencePersistence.snapshot(context, configuredGeofence.id)
        val previousRegistrationExists = previousSnapshot.containsEvidenceFor(configuredGeofence.id)
        val previousPlatformGeofence = previousRecoverable?.takeIf {
            previousStored?.active == true && previousStored.lifecycleMetadataDurable
        }
        val expirationDeadlineMillis = expirationDeadlineMillisOverride
            ?: configuredGeofence.androidSettings.expirationDurationMillis?.let {
                GeofenceRegistrationStore.safeDeadline(System.currentTimeMillis(), it)
            }
        val registrationPersistence = AndroidGeofenceRegistrationPersistence(
            mode = AndroidGeofenceRegistrationPersistenceMode.select(
                persistConfiguredRegistration = cache,
                hasActivePreviousRegistration = previousPlatformGeofence != null,
            ),
            saveInactiveRegistration = {
                NativeGeofencePersistence.saveGeofence(
                    context,
                    configuredGeofence,
                    recoveryEligible = true,
                    active = false,
                    expirationDeadlineMillis = expirationDeadlineMillis,
                )
            },
            saveActiveRegistration = {
                NativeGeofencePersistence.saveGeofence(
                    context,
                    configuredGeofence,
                    recoveryEligible = true,
                    active = true,
                    expirationDeadlineMillis = expirationDeadlineMillis,
                )
            },
            markExistingRegistrationActive = {
                NativeGeofencePersistence.setLifecycleState(
                    context,
                    configuredGeofence.id,
                    recoveryEligible = true,
                    active = true,
                )
            },
        )

        AndroidGeofenceRegistrationTransaction(
            previousRegistrationExists = previousRegistrationExists,
            previousPlatformRestorationRequired = previousPlatformGeofence != null,
            saveProvisional = registrationPersistence::saveProvisional,
            markActive = registrationPersistence::commit,
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
                beginGeofenceRemoval(configuredGeofence.id)
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
                            "Successfully added Geofence ID=${configuredGeofence.id}.",
                        )
                        callback?.invoke(Result.success(Unit))
                    },
                    onFailure = { error ->
                        val failure = error as AndroidGeofenceRegistrationTransactionException
                        NativeGeofenceLogger.e(
                            context,
                            TAG,
                            "Failed to add Geofence ID=${configuredGeofence.id}: ${failure.message}",
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
            GeofenceEvents.initialTriggerMask(
                geofence.androidSettings.initialTriggers,
                includeInitialTriggers,
            ),
        )
        addGeofence(GeofenceWires.toGeofence(geofence))
    }.build()

    @SuppressLint("MissingPermission")
    private fun beginGeofenceAdd(
        request: GeofencingRequest,
    ): AndroidGeofenceAsyncOperation {
        val task = geofencingClient.addGeofences(request, getGeofencePendingIntent(context))
        return AndroidGeofenceAsyncOperation { onSuccess, onFailure ->
            task.attachWithGeofenceMutationDeadline(
                kind = AndroidGeofenceMutationKind.REGISTRATION,
                onSuccess = onSuccess,
                onFailure = onFailure
            )
        }
    }

    private fun beginGeofenceRemoval(id: String): AndroidGeofenceAsyncOperation {
        return beginGeofenceRemoval(listOf(id))
    }

    private fun beginGeofenceRemoval(ids: List<String>): AndroidGeofenceAsyncOperation {
        val task = geofencingClient.removeGeofences(ids)
        return AndroidGeofenceAsyncOperation { onSuccess, onFailure ->
            task.attachWithGeofenceMutationDeadline(
                kind = AndroidGeofenceMutationKind.REMOVAL,
                onSuccess = onSuccess,
                onFailure = onFailure
            )
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
        recordJson.hasStoredEvidence ||
            expirationDeadlineMillis.hasStoredEvidence ||
            recoveryEligible.hasStoredEvidence ||
            active.hasStoredEvidence ||
            callbackPackageFingerprint.hasStoredEvidence ||
            rawIds.containsOrMayContain(id) ||
            configuredIds.containsOrMayContain(id)

    private val PersistedValue<*>.hasStoredEvidence: Boolean
        get() = this !is PersistedValue.Absent

    private fun PersistedValue<Set<String>>.containsOrMayContain(id: String): Boolean =
        when (this) {
            PersistedValue.Absent -> false
            is PersistedValue.Readable -> value.contains(id)
            PersistedValue.Corrupt -> true
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

internal fun initializeCallbackDispatcher(
    callbackDispatcherHandle: Long,
    persist: (Long) -> Boolean,
    afterPersisted: () -> Unit,
) {
    persistCallbackDispatcherHandle(callbackDispatcherHandle, persist)
    afterPersisted()
}

internal class CallbackDispatcherRecoveryAdmission {
    private val admitted = AtomicBoolean(false)

    fun tryAcquire(hasRecoveryEvidence: Boolean): Boolean =
        hasRecoveryEvidence && admitted.compareAndSet(false, true)

    fun releaseAfterStartFailure() {
        admitted.set(false)
    }
}
