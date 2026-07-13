package com.chunkytofustudios.native_geofence.util

import android.content.pm.ServiceInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ForegroundServiceCompatibilityTest {
    @Test
    fun `host-added service types do not change the required runtime type`() {
        val mergedDeclaration =
            ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC

        assertTrue(
            ForegroundServiceCompatibility.declaresRequiredForegroundServiceType(
                mergedDeclaration
            )
        )
        assertFalse(
            ForegroundServiceCompatibility.declaresRequiredForegroundServiceType(
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        )
        assertFalse(
            ForegroundServiceCompatibility.RUNTIME_FOREGROUND_SERVICE_TYPE and
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC != 0
        )
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            ForegroundServiceCompatibility.RUNTIME_FOREGROUND_SERVICE_TYPE
        )
    }
}
