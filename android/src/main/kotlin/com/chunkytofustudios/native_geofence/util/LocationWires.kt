package com.chunkytofustudios.native_geofence.util

import android.location.Location
import androidx.core.location.LocationCompat
import com.chunkytofustudios.native_geofence.generated.LocationWire

class LocationWires {
    companion object {
        fun fromLocation(e: Location): LocationWire {
            return LocationWire(
                e.latitude,
                e.longitude,
                if (e.hasAccuracy()) e.accuracy.toDouble() else null,
                LocationCompat.isMock(e),
                e.time.takeIf { it > 0L },
                e.elapsedRealtimeNanos.takeIf { it > 0L },
            )
        }
    }
}
