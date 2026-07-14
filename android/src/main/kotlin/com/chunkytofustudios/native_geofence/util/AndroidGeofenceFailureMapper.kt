package com.chunkytofustudios.native_geofence.util

import com.google.android.gms.common.api.ApiException
import com.google.android.gms.location.GeofenceStatusCodes

internal data class AndroidGeofenceFailureEvidence(
    val message: String,
    val details: String?
)

internal object AndroidGeofenceFailureMapper {
    fun from(error: Throwable): AndroidGeofenceFailureEvidence =
        fromStatus(
            statusCode = (error as? ApiException)?.statusCode,
            fallbackMessage = if (error is AndroidGeofenceMutationTimeoutException) {
                error.message.orEmpty()
            } else {
                error.toString()
            }
        )

    internal fun fromStatus(
        statusCode: Int?,
        fallbackMessage: String
    ): AndroidGeofenceFailureEvidence {
        val message = when (statusCode) {
            GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE ->
                "Geofence service is not available. Location may be turned off, " +
                    "or the device may be in battery-saver or airplane mode."
            GeofenceStatusCodes.GEOFENCE_TOO_MANY_GEOFENCES ->
                "Too many geofences: an app may register at most 100 geofences."
            GeofenceStatusCodes.GEOFENCE_TOO_MANY_PENDING_INTENTS ->
                "Too many geofence PendingIntents: an app may register geofences " +
                    "with at most 5 distinct PendingIntents."
            else -> fallbackMessage
        }
        return AndroidGeofenceFailureEvidence(
            message = message,
            details = statusCode?.let { "GeofenceStatusCodes=$it" }
        )
    }
}
