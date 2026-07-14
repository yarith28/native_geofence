package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.NativeGeofenceCallbackRefreshState
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceRegistrationHealth

internal data class NativeGeofenceHealthEvidence(
    val persistedRegistrationCount: Int,
    val locationPermissionGranted: Boolean?,
    val backgroundLocationPermissionGranted: Boolean?,
    val locationServicesEnabled: Boolean?,
    val platformMonitoringAvailable: Boolean?,
    val callbackInfrastructureAvailable: Boolean?,
    val callbackDispatcherRegistered: Boolean?,
    val callbackRefreshState: NativeGeofenceCallbackRefreshState,
    val pluginOwnedMonitoringCount: Int? = null,
    val androidLifecycleEvidence: AndroidGeofenceLifecycleEvidence? = null
)

internal data class AndroidGeofenceLifecycleEvidence(
    val activeCount: Int,
    val recoverableCount: Int,
    val pendingCleanupCount: Int,
    val corruptOrRawOnlyCount: Int,
    val unknownLifecycleCount: Int
) {
    val totalCount: Int
        get() = activeCount + recoverableCount + pendingCleanupCount +
            corruptOrRawOnlyCount + unknownLifecycleCount

    companion object {
        fun from(inventory: List<GeofenceStatusInventoryEntry>) =
            AndroidGeofenceLifecycleEvidence(
                activeCount = inventory.count {
                    it.disposition == GeofenceStatusDisposition.ACTIVE
                },
                recoverableCount = inventory.count {
                    it.disposition == GeofenceStatusDisposition.RECOVERABLE
                },
                pendingCleanupCount = inventory.count {
                    it.disposition == GeofenceStatusDisposition.PENDING_CLEANUP
                },
                corruptOrRawOnlyCount = inventory.count {
                    it.disposition == GeofenceStatusDisposition.CORRUPT_OR_RAW_ONLY
                },
                unknownLifecycleCount = inventory.count {
                    it.disposition == GeofenceStatusDisposition.UNKNOWN_LIFECYCLE
                }
            )
    }
}

internal object NativeGeofenceStatusHealth {
    fun compute(evidence: NativeGeofenceHealthEvidence): NativeGeofenceRegistrationHealth {
        if (evidence.persistedRegistrationCount == 0) {
            return NativeGeofenceRegistrationHealth.NO_REGISTRATIONS
        }
        evidence.androidLifecycleEvidence?.let { lifecycle ->
            if (
                lifecycle.totalCount != evidence.persistedRegistrationCount ||
                lifecycle.unknownLifecycleCount > 0
            ) {
                return NativeGeofenceRegistrationHealth.UNKNOWN
            }
            if (lifecycle.activeCount != evidence.persistedRegistrationCount) {
                return NativeGeofenceRegistrationHealth.DEGRADED
            }
        }
        val requiredEvidence = listOf(
            evidence.locationPermissionGranted,
            evidence.backgroundLocationPermissionGranted,
            evidence.locationServicesEnabled,
            evidence.platformMonitoringAvailable,
            evidence.callbackInfrastructureAvailable,
            evidence.callbackDispatcherRegistered
        )
        if (requiredEvidence.any { it == false }) {
            return NativeGeofenceRegistrationHealth.UNAVAILABLE
        }
        if (requiredEvidence.any { it == null }) {
            return NativeGeofenceRegistrationHealth.UNKNOWN
        }
        if (evidence.callbackRefreshState == NativeGeofenceCallbackRefreshState.REFRESH_REQUIRED) {
            return NativeGeofenceRegistrationHealth.DEGRADED
        }
        if (evidence.callbackRefreshState == NativeGeofenceCallbackRefreshState.UNKNOWN) {
            return NativeGeofenceRegistrationHealth.UNKNOWN
        }
        val monitoringCount = evidence.pluginOwnedMonitoringCount
        if (
            monitoringCount != null &&
            monitoringCount != evidence.persistedRegistrationCount
        ) {
            return NativeGeofenceRegistrationHealth.DEGRADED
        }
        return NativeGeofenceRegistrationHealth.HEALTHY
    }
}
