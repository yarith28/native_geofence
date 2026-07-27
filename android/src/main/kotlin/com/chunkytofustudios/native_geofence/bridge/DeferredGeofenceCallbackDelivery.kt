package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.util.AndroidPackageFingerprint
import com.chunkytofustudios.native_geofence.util.DeferredGeofenceCallbackEnvelope
import com.chunkytofustudios.native_geofence.util.DeferredGeofenceCallbackReadResult
import com.chunkytofustudios.native_geofence.util.DeferredGeofenceCallbackReplayDecision
import com.chunkytofustudios.native_geofence.util.DeferredGeofenceCallbackReplayPlanner
import com.chunkytofustudios.native_geofence.util.DeferredGeofenceCallbackRequest
import com.chunkytofustudios.native_geofence.util.DeferredGeofenceCallbackStore
import com.chunkytofustudios.native_geofence.util.DeferredGeofenceCallbackStoreResult
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackRegistration
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnosticStage
import com.chunkytofustudios.native_geofence.util.NativeGeofenceDiagnostics
import com.chunkytofustudios.native_geofence.util.NativeGeofenceIo
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger
import com.chunkytofustudios.native_geofence.util.NativeGeofencePersistence
import com.chunkytofustudios.native_geofence.util.NativeGeofencePreferences
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Owns callbacks that cannot safely resolve a Dart callback yet.
 *
 * Replay is synchronization-owned: initialization alone is not evidence that
 * every app callback still exists. A successful app-owned synchronization
 * supplies both the IDs whose callback metadata was confirmed and whether a
 * missing registration can be treated as an authoritative removal.
 */
internal object DeferredGeofenceCallbackDelivery {
    private val replayRunning = AtomicBoolean(false)
    private val replayRequested = AtomicBoolean(false)
    private val replayRequestLock = Object()
    private val requestedSynchronizedIds = mutableSetOf<String>()
    private var authoritativeReplayRequested = false

    fun defer(
        context: Context,
        params: GeofenceCallbackParamsWire,
        completion: (Boolean) -> Unit,
    ) = defer(
        context = context,
        params = params,
        deliverySpec = nativeBridgeCallbackDeliverySpec(),
        completion = completion,
    )

    fun defer(
        context: Context,
        params: GeofenceCallbackParamsWire,
        deliverySpec: NativeGeofenceCallbackDeliverySpec,
        completion: (Boolean) -> Unit,
    ) {
        val appContext = context.applicationContext
        NativeGeofenceIo.execute {
            var accepted = false
            var outcome = DeferredGeofenceCallbackStoreResult.STORAGE_FAILURE
            val ids = params.geofences.map { it.id }.toSet()
            try {
                val refreshMarked = ids.isNotEmpty() &&
                    NativeGeofencePersistence.markCallbackRefreshRequired(appContext, ids)
                outcome = if (!refreshMarked) {
                    DeferredGeofenceCallbackStoreResult.STORAGE_FAILURE
                } else {
                    DeferredGeofenceCallbackStore.forContext(appContext).defer(
                        DeferredGeofenceCallbackRequest(
                            params = params,
                            deliveryRoute = deliverySpec.route.storageValue,
                            deliverySource = deliverySpec.source,
                        )
                    )
                }
                accepted = refreshMarked &&
                    (
                        outcome == DeferredGeofenceCallbackStoreResult.STORED ||
                            outcome == DeferredGeofenceCallbackStoreResult.DUPLICATE
                        )
                runCatching {
                    NativeGeofenceDiagnostics.record(
                        appContext,
                        NativeGeofenceDiagnosticStage.ENQUEUE,
                        succeeded = accepted,
                        outcome = when {
                            !refreshMarked -> "callback_defer_refresh_marker_failed"
                            outcome == DeferredGeofenceCallbackStoreResult.STORED ->
                                "callback_deferred_for_refresh"
                            outcome == DeferredGeofenceCallbackStoreResult.DUPLICATE ->
                                "callback_defer_duplicate"
                            outcome == DeferredGeofenceCallbackStoreResult.FULL ->
                                "callback_defer_queue_full"
                            else -> "callback_defer_storage_failed"
                        },
                        geofenceCount = ids.size,
                    )
                }
                runCatching {
                    if (accepted) {
                        NativeGeofenceLogger.w(
                            appContext,
                            TAG,
                            "Deferred ${ids.size} callback(s) until synchronization confirms " +
                                "current callback metadata.",
                        )
                    } else {
                        NativeGeofenceLogger.e(
                            appContext,
                            TAG,
                            "Failed to defer ${ids.size} callback(s); outcome=$outcome.",
                        )
                    }
                }
            } catch (error: Throwable) {
                runCatching {
                    NativeGeofenceLogger.e(
                        appContext,
                        TAG,
                        "Deferred callback persistence failed unexpectedly.",
                        error,
                    )
                }
            } finally {
                completion(accepted)
            }
        }
    }

    fun replay(
        context: Context,
        synchronizedIds: Set<String>,
        registrationStateAuthoritative: Boolean,
    ) {
        val appContext = context.applicationContext
        synchronized(replayRequestLock) {
            requestedSynchronizedIds.addAll(synchronizedIds)
            authoritativeReplayRequested =
                authoritativeReplayRequested || registrationStateAuthoritative
        }
        replayRequested.set(true)
        startReplayIfNeeded(appContext)
    }

    private fun startReplayIfNeeded(context: Context) {
        if (!replayRunning.compareAndSet(false, true)) return
        replayRequested.set(false)
        val request = synchronized(replayRequestLock) {
            ReplayRequest(
                synchronizedIds = requestedSynchronizedIds.toSet(),
                registrationStateAuthoritative = authoritativeReplayRequested,
            ).also {
                requestedSynchronizedIds.clear()
                authoritativeReplayRequested = false
            }
        }
        NativeGeofenceIo.execute {
            try {
                if (!dispatcherIsCurrent(context)) {
                    finishReplay(context)
                    return@execute
                }
                val store = DeferredGeofenceCallbackStore.forContext(context)
                when (val snapshot = store.snapshot()) {
                    DeferredGeofenceCallbackReadResult.StorageFailure -> {
                        NativeGeofenceDiagnostics.record(
                            context,
                            NativeGeofenceDiagnosticStage.ENQUEUE,
                            succeeded = false,
                            outcome = "callback_defer_read_failed",
                        )
                        finishReplay(context)
                    }
                    is DeferredGeofenceCallbackReadResult.Found ->
                        replayAt(context, store, snapshot.entries, index = 0, request)
                }
            } catch (error: Throwable) {
                failReplay(context, error)
            }
        }
    }

    private fun replayAt(
        context: Context,
        store: DeferredGeofenceCallbackStore,
        entries: List<DeferredGeofenceCallbackEnvelope>,
        index: Int,
        request: ReplayRequest,
    ) {
        try {
            var currentIndex = index
            while (currentIndex < entries.size) {
                val envelope = entries[currentIndex]
                val deferred = envelope.toWire()
                val eventId = deferred.eventId
                when (
                    val decision = DeferredGeofenceCallbackReplayPlanner.decide(
                        deferred = deferred,
                        rootGeofenceIds = envelope.rootGeofenceIds(),
                        synchronizedIds = request.synchronizedIds,
                        registrationStateAuthoritative =
                            request.registrationStateAuthoritative,
                        lookup = { id ->
                            NativeGeofencePersistence.getStoredGeofence(context, id)?.let {
                                GeofenceCallbackRegistration(
                                    configuredGeofence = it.configuredGeofence,
                                    expirationDeadlineMillis = it.expirationDeadlineMillis,
                                )
                            }
                        },
                        isCallbackFresh = { id ->
                            NativeGeofencePersistence.getCallbackPackageFingerprint(context, id) ==
                                AndroidPackageFingerprint.current(context) &&
                                !NativeGeofencePersistence.isCallbackRefreshRequiredFor(
                                    context,
                                    setOf(id),
                                )
                        },
                    )
                ) {
                    DeferredGeofenceCallbackReplayDecision.WaitForRefresh -> {
                        currentIndex += 1
                    }

                    DeferredGeofenceCallbackReplayDecision.Discard -> {
                        if (eventId != null) store.remove(eventId)
                        currentIndex += 1
                    }

                    is DeferredGeofenceCallbackReplayDecision.Deliver -> {
                        if (
                            eventId == null ||
                            !store.acknowledge(eventId, decision.discardedIds)
                        ) {
                            failReplay(
                                context,
                                IllegalStateException(
                                    "Failed to persist deferred callback discard progress."
                                ),
                            )
                            return
                        }
                        enqueueReplayGroup(
                            context = context,
                            store = store,
                            entries = entries,
                            nextIndex = currentIndex + 1,
                            eventId = eventId,
                            callbackGroups = decision.callbackGroups,
                            groupIndex = 0,
                            deliverySpec = envelope.deliverySpec(),
                            request = request,
                        )
                        return
                    }
                }
            }
            finishReplay(context)
        } catch (error: Throwable) {
            failReplay(context, error)
        }
    }

    private fun enqueueReplayGroup(
        context: Context,
        store: DeferredGeofenceCallbackStore,
        entries: List<DeferredGeofenceCallbackEnvelope>,
        nextIndex: Int,
        eventId: String,
        callbackGroups: List<GeofenceCallbackParamsWire>,
        groupIndex: Int,
        deliverySpec: NativeGeofenceCallbackDeliverySpec,
        request: ReplayRequest,
    ) {
        if (groupIndex >= callbackGroups.size) {
            replayAt(context, store, entries, nextIndex, request)
            return
        }
        val params = callbackGroups[groupIndex]
        try {
            NativeGeofenceCallbackDelivery.enqueue(
                context = context,
                params = params,
                deliverySpec = deliverySpec,
            ) { outcome ->
                NativeGeofenceIo.execute {
                    try {
                        val accepted = outcome == NativeGeofenceCallbackEnqueueResult.ACCEPTED
                        val progressPersisted = !accepted || store.acknowledge(
                            eventId,
                            params.geofences.map { it.id }.toSet(),
                        )
                        NativeGeofenceDiagnostics.record(
                            context,
                            NativeGeofenceDiagnosticStage.ENQUEUE,
                            succeeded = accepted && progressPersisted,
                            outcome = when {
                                accepted && progressPersisted ->
                                    "deferred_callback_replayed"
                                accepted -> "deferred_callback_replay_progress_failed"
                                outcome == NativeGeofenceCallbackEnqueueResult.UNCONFIRMED ->
                                    "deferred_callback_replay_unconfirmed"
                                else -> "deferred_callback_replay_rejected"
                            },
                            geofenceCount = params.geofences.size,
                        )
                        if (!accepted || !progressPersisted) {
                            // Keep the deferred record when WorkManager ownership
                            // is ambiguous or rejected. A later synchronization
                            // can retry without creating a known event-loss gap.
                            finishReplay(context)
                            return@execute
                        }
                        enqueueReplayGroup(
                            context = context,
                            store = store,
                            entries = entries,
                            nextIndex = nextIndex,
                            eventId = eventId,
                            callbackGroups = callbackGroups,
                            groupIndex = groupIndex + 1,
                            deliverySpec = deliverySpec,
                            request = request,
                        )
                    } catch (error: Throwable) {
                        failReplay(context, error)
                    }
                }
            }
        } catch (error: Throwable) {
            failReplay(context, error)
        }
    }

    private fun DeferredGeofenceCallbackEnvelope.deliverySpec() =
        NativeGeofenceCallbackDeliverySpec(
            route = NativeGeofenceCallbackRoute.fromStorageValue(deliveryRoute),
            source = deliverySource,
        )

    private fun failReplay(context: Context, error: Throwable) {
        runCatching {
            NativeGeofenceLogger.e(
                context,
                TAG,
                "Deferred callback replay failed.",
                error,
            )
            NativeGeofenceDiagnostics.record(
                context,
                NativeGeofenceDiagnosticStage.ENQUEUE,
                succeeded = false,
                outcome = "deferred_callback_replay_failed",
            )
        }
        finishReplay(context)
    }

    private fun dispatcherIsCurrent(context: Context): Boolean {
        val preferences = NativeGeofencePreferences.get(context)
        val handle = preferences.getLong(Constants.CALLBACK_DISPATCHER_HANDLE_KEY, 0L)
        val fingerprint = preferences.getString(
            Constants.CALLBACK_DISPATCHER_PACKAGE_FINGERPRINT_KEY,
            null,
        )
        return handle != 0L && fingerprint == AndroidPackageFingerprint.current(context)
    }

    private fun finishReplay(context: Context) {
        replayRunning.set(false)
        if (replayRequested.get()) startReplayIfNeeded(context)
    }

    private data class ReplayRequest(
        val synchronizedIds: Set<String>,
        val registrationStateAuthoritative: Boolean,
    )

    private const val TAG = "DeferredGeofenceCallback"
}
