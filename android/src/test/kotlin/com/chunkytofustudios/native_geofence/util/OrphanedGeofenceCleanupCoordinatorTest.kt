package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.AndroidGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import com.chunkytofustudios.native_geofence.generated.IosGeofenceSettingsWire
import com.chunkytofustudios.native_geofence.generated.LocationWire
import java.util.ArrayDeque
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class OrphanedGeofenceCleanupCoordinatorTest {
    @Test
    fun `registration repaired before execution skips every cleanup mutation`() {
        val harness = CleanupHarness(lookup = { geofence(it, callbackHandle = 41) })

        harness.subject.cleanup("office", harness::record)
        harness.dispatcher.runNext()

        assertEquals(listOf(Result.success(Unit)), harness.results)
        assertTrue(harness.events.isEmpty())
    }

    @Test
    fun `cleanup retains evidence before platform removal and clears it last`() {
        val events = mutableListOf<String>()
        val harness = CleanupHarness(
            events = events,
            mark = {
                events += "mark:$it"
                true
            },
            remove = { id, complete ->
                events += "platform:$id"
                complete(Result.success(Unit))
            },
            clear = {
                events += "clear:$it"
                true
            }
        )

        harness.subject.cleanup("office", harness::record)
        harness.dispatcher.runNext()

        assertEquals(listOf("mark:office", "platform:office", "clear:office"), events)
        assertEquals(listOf(Result.success(Unit)), harness.results)
    }

    @Test
    fun `failed evidence marker prevents platform removal`() {
        val harness = CleanupHarness(mark = { false })

        harness.subject.cleanup("office", harness::record)
        harness.dispatcher.runNext()

        assertTrue(harness.events.isEmpty())
        assertIs<IllegalStateException>(harness.results.single().exceptionOrNull())
    }

    @Test
    fun `platform failure retains evidence and never clears durable state`() {
        val failure = IllegalArgumentException("platform")
        val events = mutableListOf<String>()
        val harness = CleanupHarness(
            events = events,
            remove = { id, complete ->
                events += "platform:$id"
                complete(Result.failure(failure))
            }
        )

        harness.subject.cleanup("office", harness::record)
        harness.dispatcher.runNext()

        assertEquals(failure, harness.results.single().exceptionOrNull())
        assertEquals(listOf("mark:office", "platform:office"), events)
    }

    @Test
    fun `durable clear failure is surfaced after platform success`() {
        val harness = CleanupHarness(clear = { false })

        harness.subject.cleanup("office", harness::record)
        harness.dispatcher.runNext()

        assertIs<IllegalStateException>(harness.results.single().exceptionOrNull())
    }

    @Test
    fun `double and late platform callbacks complete once and advance the queue once`() {
        lateinit var platformComplete: (Result<Unit>) -> Unit
        val dispatcher = CleanupDispatcher()
        val queue = GeofenceMutationQueue(dispatcher::dispatch)
        val runner = GeofenceMutationRunner(queue)
        var cleanupCompletions = 0
        var nextRuns = 0
        var clears = 0
        val subject = OrphanedGeofenceCleanupCoordinator(
            mutationRunner = runner,
            lookup = { null },
            markForPlatformCleanup = { true },
            removeFromPlatform = { _, complete -> platformComplete = complete },
            clearDurableState = {
                clears += 1
                true
            }
        )

        subject.cleanup("office") { cleanupCompletions += 1 }
        runner.run(callback = { nextRuns += 1 }, start = { it(Result.success(Unit)) })
        dispatcher.runNext()

        platformComplete(Result.success(Unit))
        platformComplete(Result.failure(IllegalStateException("late")))
        dispatcher.runNext()

        assertEquals(1, cleanupCompletions)
        assertEquals(1, clears)
        assertEquals(1, nextRuns)
    }

    @Test
    fun `synchronous platform throw wins over a late callback`() {
        lateinit var platformComplete: (Result<Unit>) -> Unit
        var clears = 0
        val harness = CleanupHarness(
            remove = { _, complete ->
                platformComplete = complete
                throw IllegalStateException("listener registration")
            },
            clear = {
                clears += 1
                true
            }
        )

        harness.subject.cleanup("office", harness::record)
        harness.dispatcher.runNext()
        platformComplete(Result.success(Unit))

        assertEquals(1, harness.results.size)
        assertIs<IllegalStateException>(harness.results.single().exceptionOrNull())
        assertEquals(0, clears)
    }
}

private class CleanupHarness(
    lookup: (String) -> GeofenceWire? = { null },
    val events: MutableList<String> = mutableListOf(),
    mark: (String) -> Boolean = {
        events += "mark:$it"
        true
    },
    remove: (String, (Result<Unit>) -> Unit) -> Unit = { id, complete ->
        events += "platform:$id"
        complete(Result.success(Unit))
    },
    clear: (String) -> Boolean = {
        events += "clear:$it"
        true
    }
) {
    val dispatcher = CleanupDispatcher()
    val results = mutableListOf<Result<Unit>>()
    private val runner = GeofenceMutationRunner(GeofenceMutationQueue(dispatcher::dispatch))
    val subject = OrphanedGeofenceCleanupCoordinator(runner, lookup, mark, remove, clear)

    fun record(result: Result<Unit>) {
        results += result
    }
}

private class CleanupDispatcher {
    private val pending = ArrayDeque<() -> Unit>()

    fun dispatch(operation: () -> Unit) {
        pending.addLast(operation)
    }

    fun runNext() {
        pending.removeFirst().invoke()
    }
}

private fun geofence(id: String, callbackHandle: Long) = GeofenceWire(
    id = id,
    location = LocationWire(
        latitude = 11.0,
        longitude = 104.0,
        accuracyMeters = null,
        isMock = false
    ),
    radiusMeters = 100.0,
    triggers = listOf(GeofenceEvent.ENTER, GeofenceEvent.EXIT),
    iosSettings = IosGeofenceSettingsWire(initialTrigger = false),
    androidSettings = AndroidGeofenceSettingsWire(
        initialTriggers = emptyList(),
        expirationDurationMillis = null,
        loiteringDelayMillis = 0,
        notificationResponsivenessMillis = null
    ),
    callbackHandle = callbackHandle
)
