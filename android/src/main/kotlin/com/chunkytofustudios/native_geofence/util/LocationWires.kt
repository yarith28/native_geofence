package com.chunkytofustudios.native_geofence.util

import android.location.Location
import android.os.Build
import com.chunkytofustudios.native_geofence.generated.LocationWire

class LocationWires {
    companion object {
        fun fromLocation(e: Location): LocationWire {
            return LocationWire(
                e.latitude,
                e.longitude,
                if (e.hasAccuracy()) e.accuracy.toDouble() else null,
                isMock(e),
            )
        }

        @Suppress("DEPRECATION")
        private fun isMock(e: Location): Boolean =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) e.isMock
            else e.isFromMockProvider
    }
}
