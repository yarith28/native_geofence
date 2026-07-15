package com.chunkytofustudios.native_geofence.receivers

import android.content.ContextWrapper
import com.chunkytofustudios.native_geofence.bridge.NativeGeofenceCallbackEnqueueResult
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.util.BroadcastCompletionBarrier
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Test

class GeofenceBroadcastCallbackEnqueuerTest {
    @Test
    fun `public delivery completion releases each broadcast ticket exactly once`() {
        val delivered = mutableListOf<GeofenceCallbackParamsWire>()
        val completions = mutableListOf<(NativeGeofenceCallbackEnqueueResult) -> Unit>()
        var barrierCompletions = 0
        val barrier = BroadcastCompletionBarrier(2) { barrierCompletions++ }
        val subject = GeofenceBroadcastCallbackEnqueuer(
            enqueue = { _, params, completion ->
                delivered += params
                completions += completion
            },
            eventId = sequenceOf("event-1", "event-2").iterator()::next,
        )

        subject.enqueue(
            ContextWrapper(null),
            listOf(params(), params()),
            barrier,
        )

        assertEquals(listOf("event-1", "event-2"), delivered.map { it.eventId })
        assertNotEquals(delivered[0].eventId, delivered[1].eventId)
        completions[0](NativeGeofenceCallbackEnqueueResult.ACCEPTED)
        completions[0](NativeGeofenceCallbackEnqueueResult.REJECTED)
        assertEquals(0, barrierCompletions)
        completions[1](NativeGeofenceCallbackEnqueueResult.UNCONFIRMED)
        assertEquals(1, barrierCompletions)
    }

    @Test
    fun `synchronous delivery failure still releases the broadcast ticket`() {
        var barrierCompletions = 0
        val subject = GeofenceBroadcastCallbackEnqueuer(
            enqueue = { _, _, _ -> error("dispatch failed") },
        )

        subject.enqueue(
            ContextWrapper(null),
            listOf(params()),
            BroadcastCompletionBarrier(1) { barrierCompletions++ },
        )

        assertEquals(1, barrierCompletions)
    }

    private fun params() = GeofenceCallbackParamsWire(
        geofences = emptyList(),
        event = GeofenceEvent.ENTER,
        location = null,
        callbackHandle = 1L,
    )
}
