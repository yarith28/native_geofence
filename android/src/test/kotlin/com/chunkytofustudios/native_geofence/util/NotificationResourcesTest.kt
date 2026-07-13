package com.chunkytofustudios.native_geofence.util

import kotlin.test.Test
import kotlin.test.assertEquals

class NotificationResourcesTest {
    @Test
    fun `defaults preserve the existing notification copy`() {
        assertEquals(
            NotificationResourceValues(
                channelName = "Geofence Events",
                title = "Processing geofence event.",
                text = "We noticed you are near a key location and are checking if we can help."
            ),
            NotificationResources.resolve { null }
        )
    }

    @Test
    fun `host resources can override every notification string independently`() {
        val overrides = mapOf(
            NotificationResources.CHANNEL_NAME to "Location updates",
            NotificationResources.TITLE to "Checking your location",
            NotificationResources.TEXT to "Your custom foreground disclosure"
        )

        assertEquals(
            NotificationResourceValues(
                channelName = "Location updates",
                title = "Checking your location",
                text = "Your custom foreground disclosure"
            ),
            NotificationResources.resolve(overrides::get)
        )
    }
}
