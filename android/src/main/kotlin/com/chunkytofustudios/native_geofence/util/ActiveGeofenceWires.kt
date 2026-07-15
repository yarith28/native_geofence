package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.ActiveGeofenceWire
import com.chunkytofustudios.native_geofence.generated.AndroidGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.generated.LocationWire
import com.google.android.gms.location.Geofence

class ActiveGeofenceWires {
    companion object {
        fun fromGeofence(e: Geofence): ActiveGeofenceWire {
            return ActiveGeofenceWire(
                e.requestId,
                // A fence center is not a device fix, so it has no accuracy or
                // mock-provider state.
                LocationWire(e.latitude, e.longitude, null, false),
                e.radius.toDouble(),
                GeofenceEvents.fromMask(e.transitionTypes),
                AndroidGeofenceSettingsWire(
                    emptyList(),
                    e.expirationTime,
                    e.loiteringDelay.toLong(),
                    e.notificationResponsiveness.toLong()
                ),
                null,
            )
        }

        fun fromGeofenceWire(
            e: GeofenceWire,
            expirationDeadlineMillis: Long? = null,
        ): ActiveGeofenceWire {
            return ActiveGeofenceWire(
                e.id,
                // Persisted registration input can contain device-fix metadata,
                // but the active geofence exposes only the configured center.
                LocationWire(e.location.latitude, e.location.longitude, null, false),
                e.radiusMeters,
                e.triggers,
                e.androidSettings,
                expirationDeadlineMillis,
            )
        }
    }
}
