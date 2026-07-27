package com.chunkytofustudios.native_geofence.util

import android.content.Context
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.model.GeofenceCallbackParamsStorage
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal interface DeferredGeofenceCallbackBackend {
    fun read(): String?
    fun write(encoded: String): Boolean
}

internal data class DeferredGeofenceCallbackRequest(
    val params: GeofenceCallbackParamsWire,
    val deliveryRoute: String,
    val deliverySource: String? = null,
)

@Serializable
internal data class DeferredGeofenceCallbackEnvelope(
    val payload: GeofenceCallbackParamsStorage,
    val deferredAtMillis: Long,
    val deliveryRoute: String = DEFAULT_DEFERRED_CALLBACK_ROUTE,
    val deliverySource: String? = null,
    val originalGeofenceIds: List<String> = emptyList(),
) {
    fun toWire(): GeofenceCallbackParamsWire = payload.toWire()

    fun rootGeofenceIds(): Set<String> =
        originalGeofenceIds.ifEmpty { toWire().geofences.map { it.id } }.toSet()
}

@Serializable
private data class DeferredGeofenceCallbackQueueSnapshot(
    val entries: List<DeferredGeofenceCallbackEnvelope> = emptyList(),
)

internal enum class DeferredGeofenceCallbackStoreResult {
    STORED,
    DUPLICATE,
    FULL,
    STORAGE_FAILURE,
}

internal sealed interface DeferredGeofenceCallbackReadResult {
    data class Found(val entries: List<DeferredGeofenceCallbackEnvelope>) :
        DeferredGeofenceCallbackReadResult

    data object StorageFailure : DeferredGeofenceCallbackReadResult
}

/**
 * Durable queue for events that cannot safely resolve a Dart callback until
 * application-owned synchronization supplies metadata from the current build.
 */
internal class DeferredGeofenceCallbackStore(
    private val backend: DeferredGeofenceCallbackBackend,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val maximumEntries: Int = DEFAULT_MAXIMUM_ENTRIES,
    private val lock: Any = Any(),
) {
    private val json = Json {
        encodeDefaults = true
        ignoreUnknownKeys = true
    }

    init {
        require(maximumEntries > 0)
    }

    fun defer(request: DeferredGeofenceCallbackRequest): DeferredGeofenceCallbackStoreResult =
        deferAll(listOf(request))

    fun deferAll(
        requests: List<DeferredGeofenceCallbackRequest>,
    ): DeferredGeofenceCallbackStoreResult = synchronized(lock) {
        if (requests.isEmpty() || requests.any { request ->
                request.params.eventId.isNullOrBlank() ||
                    request.params.geofences.isEmpty() ||
                    request.deliveryRoute.isBlank()
            }
        ) {
            return@synchronized DeferredGeofenceCallbackStoreResult.STORAGE_FAILURE
        }
        val current = loadLocked()
            ?: return@synchronized DeferredGeofenceCallbackStoreResult.STORAGE_FAILURE
        val existingIds = current.mapNotNull { it.toWire().eventId }.toSet()
        val newRequests = requests
            .distinctBy { it.params.eventId }
            .filterNot { it.params.eventId in existingIds }
        if (newRequests.isEmpty()) {
            return@synchronized DeferredGeofenceCallbackStoreResult.DUPLICATE
        }
        if (current.size + newRequests.size > maximumEntries) {
            return@synchronized DeferredGeofenceCallbackStoreResult.FULL
        }
        val deferredAt = nowMillis()
        val updated = current + newRequests.map { request ->
            DeferredGeofenceCallbackEnvelope(
                payload = GeofenceCallbackParamsStorage.fromWire(request.params),
                deferredAtMillis = deferredAt,
                deliveryRoute = request.deliveryRoute,
                deliverySource = request.deliverySource,
                originalGeofenceIds = request.params.geofences.map { it.id }.distinct(),
            )
        }
        if (storeLocked(updated)) {
            DeferredGeofenceCallbackStoreResult.STORED
        } else {
            DeferredGeofenceCallbackStoreResult.STORAGE_FAILURE
        }
    }

    fun snapshot(): DeferredGeofenceCallbackReadResult = synchronized(lock) {
        val entries = loadLocked()
            ?: return@synchronized DeferredGeofenceCallbackReadResult.StorageFailure
        DeferredGeofenceCallbackReadResult.Found(entries)
    }

    /**
     * Transfers the listed geofences out of the deferred record after another
     * durable owner accepts them. A multi-geofence batch stays intact until the
     * current callback routing genuinely requires it to be split.
     */
    fun acknowledge(eventId: String, geofenceIds: Set<String>): Boolean = synchronized(lock) {
        if (geofenceIds.isEmpty()) return@synchronized true
        val current = loadLocked() ?: return@synchronized false
        val index = current.indexOfFirst { it.toWire().eventId == eventId }
        if (index < 0) return@synchronized true
        val envelope = current[index]
        val params = envelope.toWire()
        val retainedGeofences = params.geofences.filterNot { it.id in geofenceIds }
        val updated = if (retainedGeofences.isEmpty()) {
            current.filterIndexed { candidateIndex, _ -> candidateIndex != index }
        } else {
            current.toMutableList().apply {
                this[index] = envelope.copy(
                    payload = GeofenceCallbackParamsStorage.fromWire(
                        params.copy(
                            geofences = retainedGeofences,
                            callbackContextsByGeofenceId = params.callbackContextsByGeofenceId
                                ?.filterKeys { it !in geofenceIds }
                                ?.ifEmpty { null },
                        )
                    )
                )
            }
        }
        storeLocked(updated)
    }

    fun remove(eventId: String): Boolean = synchronized(lock) {
        val current = loadLocked() ?: return@synchronized false
        val retained = current.filterNot { it.toWire().eventId == eventId }
        retained.size == current.size || storeLocked(retained)
    }

    private fun loadLocked(): List<DeferredGeofenceCallbackEnvelope>? {
        val encoded = try {
            backend.read()
        } catch (_: RuntimeException) {
            return null
        } ?: return emptyList()
        val entries = try {
            json.decodeFromString<DeferredGeofenceCallbackQueueSnapshot>(encoded).entries
        } catch (_: RuntimeException) {
            return null
        }
        return entries.takeIf { stored ->
            stored.all {
                val params = it.toWire()
                !params.eventId.isNullOrBlank() &&
                    params.geofences.isNotEmpty() &&
                    it.deliveryRoute.isNotBlank()
            }
        }
    }

    private fun storeLocked(entries: List<DeferredGeofenceCallbackEnvelope>): Boolean {
        val encoded = try {
            json.encodeToString(DeferredGeofenceCallbackQueueSnapshot(entries))
        } catch (_: RuntimeException) {
            return false
        }
        return try {
            backend.write(encoded)
        } catch (_: RuntimeException) {
            false
        }
    }

    companion object {
        private const val DEFAULT_MAXIMUM_ENTRIES = 1_024
        private val productionLock = Object()

        fun forContext(context: Context): DeferredGeofenceCallbackStore {
            val preferences = NativeGeofencePreferences.get(context.applicationContext)
            return DeferredGeofenceCallbackStore(
                backend = object : DeferredGeofenceCallbackBackend {
                    override fun read(): String? = preferences.getString(
                        Constants.DEFERRED_CALLBACK_QUEUE_KEY,
                        null,
                    )

                    override fun write(encoded: String): Boolean = preferences.edit()
                        .putString(Constants.DEFERRED_CALLBACK_QUEUE_KEY, encoded)
                        .commit()
                },
                lock = productionLock,
            )
        }
    }
}

internal sealed interface DeferredGeofenceCallbackReplayDecision {
    data class Deliver(
        val callbackGroups: List<GeofenceCallbackParamsWire>,
        val discardedIds: Set<String>,
    ) :
        DeferredGeofenceCallbackReplayDecision

    data object WaitForRefresh : DeferredGeofenceCallbackReplayDecision

    data object Discard : DeferredGeofenceCallbackReplayDecision
}

internal object DeferredGeofenceCallbackReplayPlanner {
    fun decide(
        deferred: GeofenceCallbackParamsWire,
        rootGeofenceIds: Set<String>,
        synchronizedIds: Set<String>,
        registrationStateAuthoritative: Boolean,
        lookup: (String) -> GeofenceCallbackRegistration?,
        isCallbackFresh: (String) -> Boolean,
    ): DeferredGeofenceCallbackReplayDecision {
        if (deferred.geofences.isEmpty() || deferred.eventId.isNullOrBlank()) {
            return DeferredGeofenceCallbackReplayDecision.Discard
        }
        val registrations = deferred.geofences
            .distinctBy { it.id }
            .associate { geofence -> geofence.id to lookup(geofence.id) }
        val unavailableIds = registrations
            .filterValues { registration ->
                registration == null || registration.configuredGeofence.callbackHandle == 0L
            }
            .keys
        if (unavailableIds.isNotEmpty() && !registrationStateAuthoritative) {
            return DeferredGeofenceCallbackReplayDecision.WaitForRefresh
        }
        val deliverable = registrations
            .filterValues { registration ->
                registration != null && registration.configuredGeofence.callbackHandle != 0L
            }
            .mapValues { (_, registration) -> requireNotNull(registration) }
        if (deliverable.isEmpty()) {
            return DeferredGeofenceCallbackReplayDecision.Discard
        }
        if (
            deliverable.keys.any { id ->
                id !in synchronizedIds || !isCallbackFresh(id)
            }
        ) {
            return DeferredGeofenceCallbackReplayDecision.WaitForRefresh
        }
        val routed = GeofenceCallbackRouting.route(
            triggeredIds = deliverable.keys.toList(),
            event = deferred.event,
            location = deferred.location,
            eventAtMillis = deferred.eventAtMillis,
            lookup = deliverable::get,
        )
        if (routed.orphanIds.isNotEmpty() || routed.staleIds.isNotEmpty()) {
            return DeferredGeofenceCallbackReplayDecision.WaitForRefresh
        }
        if (routed.callbackGroups.isEmpty()) {
            return DeferredGeofenceCallbackReplayDecision.Discard
        }
        val rootEventId = requireNotNull(deferred.eventId)
        val traceId = deferred.traceId?.takeIf(String::isNotBlank) ?: rootEventId
        val callbackGroups = routed.callbackGroups.map { group ->
            val groupIds = group.geofences.map { it.id }.toSet()
            group.copy(
                eventId = if (
                    routed.callbackGroups.size == 1 &&
                    groupIds == rootGeofenceIds
                ) {
                    rootEventId
                } else {
                    "$rootEventId:${group.callbackHandle}"
                },
                traceId = traceId,
            )
        }
        return DeferredGeofenceCallbackReplayDecision.Deliver(
            callbackGroups = callbackGroups,
            discardedIds = unavailableIds,
        )
    }
}

internal const val DEFAULT_DEFERRED_CALLBACK_ROUTE = "native_bridge"
