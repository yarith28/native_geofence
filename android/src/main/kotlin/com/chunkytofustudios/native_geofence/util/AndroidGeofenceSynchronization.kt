package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import java.util.Locale
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

internal data class AndroidGeofenceSynchronizationPlan(
    val removeIds: List<String>,
    val platformUpserts: List<GeofenceWire>,
    val metadataOnlyUpdates: List<GeofenceWire>
)

internal enum class AndroidGeofenceSynchronizationReason {
    FIRST_RUN,
    CALLBACK_FINGERPRINT_CHANGED,
    REGISTRATION_DRIFT
}

internal data class AndroidGeofenceSynchronizationDecision(
    val plan: AndroidGeofenceSynchronizationPlan,
    val reasons: List<AndroidGeofenceSynchronizationReason>,
    val desiredRegistrationFingerprint: String,
    val desiredCount: Int,
    val previousCount: Int
) {
    val requiresSynchronization: Boolean
        get() = reasons.isNotEmpty()
}

internal data class AndroidGeofenceSynchronizationRollbackPlan(
    val cleanupIds: List<String>,
    val platformRegistrationsToRestore: List<StoredGeofenceRegistration>
)

internal enum class AndroidGeofenceRollbackRestorationOutcome {
    RESTORED,
    FAILED,
    EXPIRED
}

internal data class AndroidGeofenceRollbackEvidencePlan(
    val cleanupMarkerIds: List<String>,
    val inactiveRecoveryIds: List<String>
) {
    val requiresRecovery: Boolean
        get() = cleanupMarkerIds.isNotEmpty() || inactiveRecoveryIds.isNotEmpty()
}

internal object AndroidGeofenceSynchronizationPlanner {
    fun decide(
        current: List<StoredGeofenceRegistration>,
        rawIds: List<String>,
        desired: List<GeofenceWire>,
        removeUnlisted: Boolean,
        currentPackageFingerprint: String,
        currentRegistrationFingerprint: String?,
        callbackFingerprintCurrent: Boolean,
        nowMillis: Long
    ): AndroidGeofenceSynchronizationDecision {
        val plan = plan(
            current = current,
            rawIds = rawIds,
            desired = desired,
            removeUnlisted = removeUnlisted,
            currentPackageFingerprint = currentPackageFingerprint,
            nowMillis = nowMillis
        )
        val desiredFingerprint = desiredRegistrationFingerprint(desired)
        val currentById = current.associateBy { it.configuredGeofence.id }
        val callbackMetadataChanged = desired.any { wanted ->
            val existing = currentById[wanted.id]?.configuredGeofence
            existing != null && (
                existing.callbackHandle != wanted.callbackHandle ||
                    existing.callbackContext != wanted.callbackContext
                )
        }
        val reasons = buildList {
            if (removeUnlisted && currentRegistrationFingerprint == null) {
                add(AndroidGeofenceSynchronizationReason.FIRST_RUN)
            }
            if (!callbackFingerprintCurrent || callbackMetadataChanged) {
                add(AndroidGeofenceSynchronizationReason.CALLBACK_FINGERPRINT_CHANGED)
            }
            if (
                (removeUnlisted && currentRegistrationFingerprint != desiredFingerprint) ||
                plan.removeIds.isNotEmpty() ||
                plan.platformUpserts.isNotEmpty()
            ) {
                add(AndroidGeofenceSynchronizationReason.REGISTRATION_DRIFT)
            }
        }
        return AndroidGeofenceSynchronizationDecision(
            plan = plan,
            reasons = reasons,
            desiredRegistrationFingerprint = desiredFingerprint,
            desiredCount = desired.size,
            previousCount = rawIds.toSet().size
        )
    }

    fun plan(
        current: List<StoredGeofenceRegistration>,
        rawIds: List<String>,
        desired: List<GeofenceWire>,
        removeUnlisted: Boolean,
        currentPackageFingerprint: String,
        nowMillis: Long
    ): AndroidGeofenceSynchronizationPlan {
        val currentById = current.associateBy { it.configuredGeofence.id }
        val desiredById = desired.associateBy { it.id }
        val removeIds = if (removeUnlisted) {
            rawIds.filterNot(desiredById::containsKey).sorted()
        } else {
            emptyList()
        }
        val platformUpserts = mutableListOf<GeofenceWire>()
        val metadataOnlyUpdates = mutableListOf<GeofenceWire>()
        desired.sortedBy { it.id }.forEach { wanted ->
            val existing = currentById[wanted.id]
            if (
                existing == null ||
                !existing.active ||
                !existing.recoveryEligible ||
                !existing.lifecycleMetadataDurable ||
                existing.expirationDeadlineMillis?.let { it <= nowMillis } == true ||
                !platformSemanticsMatch(existing.configuredGeofence, wanted)
            ) {
                platformUpserts.add(wanted)
            } else if (
                existing.configuredGeofence.callbackHandle != wanted.callbackHandle ||
                existing.configuredGeofence.callbackContext != wanted.callbackContext ||
                existing.callbackPackageFingerprint != currentPackageFingerprint
            ) {
                metadataOnlyUpdates.add(wanted)
            }
        }
        return AndroidGeofenceSynchronizationPlan(
            removeIds = removeIds,
            platformUpserts = platformUpserts,
            metadataOnlyUpdates = metadataOnlyUpdates
        )
    }

    fun incompleteRegistrationIds(
        current: List<StoredGeofenceRegistration>,
        rawIds: List<String>,
        nowMillis: Long
    ): List<String> {
        val parsedIds = current.map { it.configuredGeofence.id }.toSet()
        return (
            rawIds.filterNot(parsedIds::contains) +
                current.filter { stored ->
                    !stored.active ||
                        !stored.recoveryEligible ||
                        !stored.lifecycleMetadataDurable ||
                        stored.expirationDeadlineMillis?.let { it <= nowMillis } == true
                }.map { it.configuredGeofence.id }
            ).toSet().sorted()
    }

    fun platformSemanticsMatch(current: GeofenceWire, desired: GeofenceWire): Boolean =
        current.location.latitude == desired.location.latitude &&
            current.location.longitude == desired.location.longitude &&
            current.radiusMeters == desired.radiusMeters &&
            current.triggers.toSet() == desired.triggers.toSet() &&
            // Initial triggers are one-shot instructions, not active state.
            current.androidSettings.expirationDurationMillis ==
            desired.androidSettings.expirationDurationMillis &&
            current.androidSettings.loiteringDelayMillis ==
            desired.androidSettings.loiteringDelayMillis &&
            current.androidSettings.notificationResponsivenessMillis ==
            desired.androidSettings.notificationResponsivenessMillis

    /**
     * Canonical Android v1 fingerprint. Field order and value normalization
     * intentionally match the fingerprint emitted by the original Dart
     * synchronization implementation so existing durable fingerprints remain
     * valid when transaction authority moves into the native runtime.
     */
    fun desiredRegistrationFingerprint(desired: List<GeofenceWire>): String {
        val registrations = desired.sortedBy { it.id }.map { wire ->
            JsonObject(
                linkedMapOf(
                    "id" to JsonPrimitive(wire.id),
                    "latitude" to JsonPrimitive(wire.location.latitude),
                    "longitude" to JsonPrimitive(wire.location.longitude),
                    "radiusMeters" to JsonPrimitive(wire.radiusMeters),
                    "triggers" to JsonArray(
                        wire.triggers
                            .map { it.name.lowercase(Locale.ROOT) }
                            .sorted()
                            .map(::JsonPrimitive)
                    ),
                    "android" to JsonObject(
                        linkedMapOf(
                            "expirationDurationMillis" to
                                wire.androidSettings.expirationDurationMillis
                                    ?.let(::JsonPrimitive)
                                    .orJsonNull(),
                            "loiteringDelayMillis" to
                                JsonPrimitive(wire.androidSettings.loiteringDelayMillis),
                            "notificationResponsivenessMillis" to
                                wire.androidSettings.notificationResponsivenessMillis
                                    ?.let(::JsonPrimitive)
                                    .orJsonNull()
                        )
                    ),
                    "callbackHandle" to JsonPrimitive(wire.callbackHandle),
                    "callbackContext" to wire.callbackContext
                        ?.let(::JsonPrimitive)
                        .orJsonNull()
                )
            )
        }
        return JsonObject(
            linkedMapOf(
                "version" to JsonPrimitive(1),
                "platform" to JsonPrimitive("android"),
                "registrations" to JsonArray(registrations)
            )
        ).toString()
    }

    fun platformRegistrationForRollback(
        configuredGeofence: GeofenceWire,
        expirationDeadlineMillis: Long?,
        nowMillis: Long
    ): GeofenceWire? {
        if (expirationDeadlineMillis == null) return configuredGeofence
        val remaining = expirationDeadlineMillis - nowMillis
        if (remaining <= 0L) return null
        return configuredGeofence.copy(
            androidSettings = configuredGeofence.androidSettings.copy(
                expirationDurationMillis = remaining
            )
        )
    }

    fun hasConsistentRollbackDeadline(
        configuredGeofence: GeofenceWire,
        expirationDeadlineMillis: Long?,
    ): Boolean =
        (configuredGeofence.androidSettings.expirationDurationMillis == null) ==
            (expirationDeadlineMillis == null)

    fun rollbackPlan(
        platformTouchedIds: Set<String>,
        previouslyActive: List<StoredGeofenceRegistration>
    ) = AndroidGeofenceSynchronizationRollbackPlan(
        cleanupIds = platformTouchedIds.sorted(),
        platformRegistrationsToRestore = previouslyActive
            .filter { it.active && it.configuredGeofence.id in platformTouchedIds }
            .sortedBy { it.configuredGeofence.id }
    )

    /**
     * Derives the durable evidence that must remain after the exact pre-transaction
     * snapshot is restored. A failed batch cleanup leaves every non-restored ID
     * potentially platform-owned, while a failed rearm leaves a canonical previous
     * registration recoverable but deliberately inactive.
     */
    fun rollbackEvidencePlan(
        cleanupFailed: Boolean,
        cleanupIds: List<String>,
        previouslyActive: List<StoredGeofenceRegistration>,
        restorationOutcomes: Map<String, AndroidGeofenceRollbackRestorationOutcome>
    ): AndroidGeofenceRollbackEvidencePlan {
        val cleanupMarkerIds = mutableSetOf<String>()
        val inactiveRecoveryIds = mutableSetOf<String>()
        val activeById = previouslyActive
            .filter { it.active && it.configuredGeofence.id in cleanupIds }
            .associateBy { it.configuredGeofence.id }

        for ((id, registration) in activeById) {
            when (restorationOutcomes[id]) {
                AndroidGeofenceRollbackRestorationOutcome.RESTORED -> Unit
                AndroidGeofenceRollbackRestorationOutcome.FAILED -> {
                    if (registration.recoveryEligible) {
                        inactiveRecoveryIds.add(id)
                    } else {
                        cleanupMarkerIds.add(id)
                    }
                }
                AndroidGeofenceRollbackRestorationOutcome.EXPIRED,
                null -> cleanupMarkerIds.add(id)
            }
        }

        if (cleanupFailed) {
            val restoredPreviousIds = activeById.keys.filterTo(mutableSetOf()) { id ->
                restorationOutcomes[id] ==
                    AndroidGeofenceRollbackRestorationOutcome.RESTORED
            }
            for (id in cleanupIds) {
                if (id !in restoredPreviousIds && id !in inactiveRecoveryIds) {
                    cleanupMarkerIds.add(id)
                }
            }
        }

        cleanupMarkerIds.removeAll(inactiveRecoveryIds)
        return AndroidGeofenceRollbackEvidencePlan(
            cleanupMarkerIds = cleanupMarkerIds.sorted(),
            inactiveRecoveryIds = inactiveRecoveryIds.sorted()
        )
    }

    private fun JsonPrimitive?.orJsonNull() = this ?: JsonNull
}
