package com.chunkytofustudios.native_geofence.util

import com.google.android.gms.location.GeofenceStatusCodes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AndroidGeofenceFailureMapperTest {
    @Test
    fun `known Play Services statuses have actionable messages and stable details`() {
        val unavailable = AndroidGeofenceFailureMapper.fromStatus(
            GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE,
            "fallback"
        )
        val tooManyGeofences = AndroidGeofenceFailureMapper.fromStatus(
            GeofenceStatusCodes.GEOFENCE_TOO_MANY_GEOFENCES,
            "fallback"
        )
        val tooManyPendingIntents = AndroidGeofenceFailureMapper.fromStatus(
            GeofenceStatusCodes.GEOFENCE_TOO_MANY_PENDING_INTENTS,
            "fallback"
        )

        assertTrue(unavailable.message.contains("Location may be turned off"))
        assertTrue(tooManyGeofences.message.contains("at most 100 geofences"))
        assertTrue(tooManyPendingIntents.message.contains("at most 5 distinct PendingIntents"))
        assertEquals(
            "GeofenceStatusCodes=${GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE}",
            unavailable.details
        )
    }

    @Test
    fun `unknown numeric status keeps fallback message and numeric evidence`() {
        val result = AndroidGeofenceFailureMapper.fromStatus(42_424, "opaque failure")

        assertEquals("opaque failure", result.message)
        assertEquals("GeofenceStatusCodes=42424", result.details)
    }

    @Test
    fun `non ApiException does not fabricate Play Services status`() {
        val result = AndroidGeofenceFailureMapper.from(IllegalStateException("failed"))

        assertTrue(result.message.contains("failed"))
        assertNull(result.details)
    }
}
