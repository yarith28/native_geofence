package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.google.android.gms.location.Geofence
import kotlin.test.Test
import kotlin.test.assertEquals

class GeofenceEventsTest {
    @Test
    fun `rollback restoration disables every configured initial trigger`() {
        val configured = listOf(
            GeofenceEvent.ENTER,
            GeofenceEvent.EXIT,
            GeofenceEvent.DWELL,
        )

        assertEquals(
            Geofence.GEOFENCE_TRANSITION_ENTER or
                Geofence.GEOFENCE_TRANSITION_EXIT or
                Geofence.GEOFENCE_TRANSITION_DWELL,
            GeofenceEvents.initialTriggerMask(
                configured,
                includeInitialTriggers = true,
            ),
        )
        assertEquals(
            0,
            GeofenceEvents.initialTriggerMask(
                configured,
                includeInitialTriggers = false,
            ),
        )
    }
}
