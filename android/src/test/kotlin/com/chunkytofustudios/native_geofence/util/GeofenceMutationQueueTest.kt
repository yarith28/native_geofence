package com.chunkytofustudios.native_geofence.util

import java.util.ArrayDeque
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class GeofenceMutationQueueTest {
    @Test
    fun `mutations run FIFO and never overlap`() {
        val dispatcher = ManualDispatcher()
        val queue = GeofenceMutationQueue(dispatcher::dispatch)
        val events = mutableListOf<String>()
        lateinit var finishFirst: () -> Unit

        queue.enqueue { done ->
            events += "first-start"
            finishFirst = done
        }
        queue.enqueue { done ->
            events += "second-start"
            done()
            events += "second-finish"
        }

        dispatcher.runNext()
        assertEquals(listOf("first-start"), events)
        finishFirst()
        assertEquals(listOf("first-start"), events)
        dispatcher.runNext()
        assertEquals(
            listOf("first-start", "second-start", "second-finish"),
            events
        )
    }

    @Test
    fun `synchronous exception advances the queue`() {
        val dispatcher = ManualDispatcher()
        val errors = mutableListOf<Throwable>()
        val queue = GeofenceMutationQueue(dispatcher::dispatch, errors::add)
        val events = mutableListOf<String>()

        queue.enqueue { throw IllegalStateException("boom") }
        queue.enqueue { done ->
            events += "second"
            done()
        }

        dispatcher.runNext()
        dispatcher.runNext()
        assertEquals(listOf("second"), events)
        assertIs<IllegalStateException>(errors.single())
    }

    @Test
    fun `double completion schedules the next mutation once`() {
        val dispatcher = ManualDispatcher()
        val queue = GeofenceMutationQueue(dispatcher::dispatch)
        var secondRuns = 0

        queue.enqueue { done ->
            done()
            done()
        }
        queue.enqueue { done ->
            secondRuns += 1
            done()
        }

        dispatcher.runNext()
        dispatcher.runNext()
        dispatcher.runNext()
        assertEquals(1, secondRuns)
        assertEquals(0, dispatcher.pendingCount)
    }

    @Test
    fun `callback exception and late completion cannot stall or duplicate`() {
        val dispatcher = ManualDispatcher()
        val queue = GeofenceMutationQueue(dispatcher::dispatch)
        val callbackErrors = mutableListOf<Throwable>()
        val runner = GeofenceMutationRunner(queue, callbackErrors::add)
        var callbackCount = 0
        var secondRuns = 0
        lateinit var lateComplete: (Result<Unit>) -> Unit

        runner.run(
            callback = {
                callbackCount += 1
                throw IllegalArgumentException("callback")
            },
            start = { complete ->
                lateComplete = complete
                complete(Result.success(Unit))
            }
        )
        runner.run(
            callback = { secondRuns += 1 },
            start = { it(Result.success(Unit)) }
        )

        dispatcher.runNext()
        lateComplete(Result.failure(IllegalStateException("late")))
        dispatcher.runNext()
        dispatcher.runNext()

        assertEquals(1, callbackCount)
        assertEquals(1, secondRuns)
        assertIs<IllegalArgumentException>(callbackErrors.single())
    }
}

private class ManualDispatcher {
    private val pending = ArrayDeque<() -> Unit>()
    val pendingCount: Int get() = pending.size

    fun dispatch(operation: () -> Unit) {
        pending.addLast(operation)
    }

    fun runNext() {
        pending.pollFirst()?.invoke()
    }
}
