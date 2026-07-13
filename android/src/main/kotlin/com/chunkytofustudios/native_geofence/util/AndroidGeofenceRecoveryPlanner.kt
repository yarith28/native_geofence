package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.GeofenceWire

internal data class AndroidGeofenceRecoveryPlan(
    val recoverable: List<GeofenceWire>,
    val cleanupIds: List<String>,
    val unknownLifecycleIds: List<String>,
)

internal object AndroidGeofenceRecoveryPlanner {
    fun plan(inventory: List<GeofenceRecoveryInventoryEntry>): AndroidGeofenceRecoveryPlan {
        val recoverable = mutableListOf<GeofenceWire>()
        val cleanupIds = mutableListOf<String>()
        val unknownLifecycleIds = mutableListOf<String>()

        for (entry in inventory) {
            when (entry.disposition) {
                GeofenceRecoveryDisposition.RECOVERABLE -> {
                    val geofence = entry.geofenceToRecover
                    if (geofence == null) {
                        unknownLifecycleIds.add(entry.id)
                    } else {
                        recoverable.add(geofence)
                    }
                }
                GeofenceRecoveryDisposition.PENDING_CLEANUP,
                GeofenceRecoveryDisposition.CORRUPT_OR_RAW_ONLY -> cleanupIds.add(entry.id)
                GeofenceRecoveryDisposition.UNKNOWN_LIFECYCLE ->
                    unknownLifecycleIds.add(entry.id)
            }
        }

        return AndroidGeofenceRecoveryPlan(
            recoverable = recoverable,
            cleanupIds = cleanupIds,
            unknownLifecycleIds = unknownLifecycleIds,
        )
    }
}
