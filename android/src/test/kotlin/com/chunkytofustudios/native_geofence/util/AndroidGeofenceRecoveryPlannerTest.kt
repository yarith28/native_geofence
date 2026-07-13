package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.AndroidGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.generated.IosGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.LocationWire
import kotlin.test.Test
import kotlin.test.assertEquals

class AndroidGeofenceRecoveryPlannerTest {
    @Test
    fun `unknown lifecycle is excluded from both recovery and cleanup`() {
        val plan = AndroidGeofenceRecoveryPlanner.plan(
            listOf(
                entry("active", GeofenceRecoveryDisposition.RECOVERABLE, geofence("active")),
                entry("expired", GeofenceRecoveryDisposition.PENDING_CLEANUP),
                entry("corrupt", GeofenceRecoveryDisposition.CORRUPT_OR_RAW_ONLY),
                entry("legacy", GeofenceRecoveryDisposition.UNKNOWN_LIFECYCLE),
                entry("inconsistent", GeofenceRecoveryDisposition.RECOVERABLE),
            ),
        )

        assertEquals(listOf("active"), plan.recoverable.map(GeofenceWire::id))
        assertEquals(listOf("expired", "corrupt"), plan.cleanupIds)
        assertEquals(listOf("legacy", "inconsistent"), plan.unknownLifecycleIds)
    }

    private fun entry(
        id: String,
        disposition: GeofenceRecoveryDisposition,
        geofence: GeofenceWire? = null,
    ) = GeofenceRecoveryInventoryEntry(
        id = id,
        disposition = disposition,
        storedRegistration = null,
        geofenceToRecover = geofence,
    )

    private fun geofence(id: String) = GeofenceWire(
        id = id,
        location = LocationWire(11.0, 104.0, null, false),
        radiusMeters = 100.0,
        triggers = listOf(GeofenceEvent.ENTER),
        iosSettings = IosGeofenceSettingsWire(initialTrigger = false),
        androidSettings = AndroidGeofenceSettingsWire(
            initialTriggers = emptyList(),
            expirationDurationMillis = null,
            loiteringDelayMillis = 0,
            notificationResponsivenessMillis = null,
        ),
        callbackHandle = 1L,
    )
}
