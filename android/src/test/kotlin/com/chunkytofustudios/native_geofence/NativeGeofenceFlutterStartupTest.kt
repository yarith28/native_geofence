package com.chunkytofustudios.native_geofence

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class NativeGeofenceFlutterStartupTest {
    @Test
    fun `cold startup initializes Flutter before callback lookup`() {
        val events = mutableListOf<String>()

        val callbackInfo = initializeFlutterAndLookupCallback(
            isLoaderInitialized = { false },
            startLoader = { events += "loader_started" },
            completeLoader = { events += "loader_completed_call" },
            lookupCallback = {
                events += "callback_lookup_call"
                "callback"
            },
            recordStage = { events += it },
        )

        assertEquals("callback", callbackInfo)
        assertEquals(
            listOf(
                "loader_requested",
                "loader_started",
                "loader_completed_call",
                "loader_completed",
                "callback_lookup_requested",
                "callback_lookup_call",
                "callback_lookup_completed",
            ),
            events,
        )
    }

    @Test
    fun `loader failure escapes before callback lookup`() {
        val stages = mutableListOf<String>()

        assertFailsWith<IllegalStateException> {
            initializeFlutterAndLookupCallback(
                isLoaderInitialized = { false },
                startLoader = {},
                completeLoader = { error("loader failed") },
                lookupCallback = {
                    error("callback lookup must not run")
                },
                recordStage = { stages += it },
            )
        }

        assertEquals(listOf("loader_requested"), stages)
    }
}
