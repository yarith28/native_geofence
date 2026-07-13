package com.chunkytofustudios.native_geofence.util

internal data class NotificationResourceValues(
    val channelName: String,
    val title: String,
    val text: String
)

internal object NotificationResources {
    const val CHANNEL_NAME = "native_geofence_notification_channel_name"
    const val TITLE = "native_geofence_notification_title"
    const val TEXT = "native_geofence_notification_text"

    fun resolve(lookup: (String) -> String?): NotificationResourceValues =
        NotificationResourceValues(
            channelName = lookup(CHANNEL_NAME) ?: "Geofence Events",
            title = lookup(TITLE) ?: "Processing geofence event.",
            text = lookup(TEXT)
                ?: "We noticed you are near a key location and are checking if we can help."
        )
}
