package com.chunkytofustudios.native_geofence.bridge

import android.content.Context

enum class NativeGeofenceBridgeTransition {
    ENTER,
    EXIT,
    DWELL
}

data class NativeGeofenceBridgeLocation(
    val latitude: Double,
    val longitude: Double,
    val accuracyMeters: Double?,
    val isMock: Boolean,
    val fixTimeMillis: Long? = null,
    val elapsedRealtimeNanos: Long? = null,
)

data class NativeGeofenceBridgeEvent(
    val geofenceIds: List<String>,
    val transition: NativeGeofenceBridgeTransition,
    val location: NativeGeofenceBridgeLocation?,
    val eventAtMillis: Long?,
    val eventId: String
)

data class NativeGeofenceBridgeTransformation(
    val geofenceIds: List<String>,
    val transition: NativeGeofenceBridgeTransition,
    val location: NativeGeofenceBridgeLocation?
)

sealed interface NativeGeofenceBridgeDecision {
    /** The native processor completed the event; Dart delivery is unnecessary. */
    data object Accept : NativeGeofenceBridgeDecision

    /** Continue to Dart with a validated transformation of the original event. */
    data class Transform(val transformation: NativeGeofenceBridgeTransformation) :
        NativeGeofenceBridgeDecision

    /** Continue through the plugin's normal Dart delivery unchanged. */
    data object Decline : NativeGeofenceBridgeDecision
}

fun interface NativeGeofenceEventProcessor {
    fun processNativeGeofenceEvent(
        context: Context,
        event: NativeGeofenceBridgeEvent,
        completion: (Result<NativeGeofenceBridgeDecision>) -> Unit
    )
}
