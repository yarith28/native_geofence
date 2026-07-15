package com.chunkytofustudios.native_geofence.model

import com.chunkytofustudios.native_geofence.generated.LocationWire
import kotlinx.serialization.Serializable

@Serializable
class LocationStorage(
    private val latitude: Double,
    private val longitude: Double,
    private val accuracyMeters: Double? = null,
    private val isMock: Boolean = false,
    private val fixTimeMillis: Long? = null,
    private val elapsedRealtimeNanos: Long? = null,
) {
    companion object {
        fun fromWire(e: LocationWire): LocationStorage {
            return LocationStorage(
                e.latitude,
                e.longitude,
                e.accuracyMeters,
                e.isMock,
                e.fixTimeMillis,
                e.elapsedRealtimeNanos,
            )
        }
    }

    fun toWire(): LocationWire {
        return LocationWire(
            latitude,
            longitude,
            accuracyMeters,
            isMock,
            fixTimeMillis,
            elapsedRealtimeNanos,
        )
    }
}
