package com.chunkytofustudios.native_geofence.util

import java.util.ArrayDeque
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue

class PlayServicesGeofenceMutationDeadlineTest {
    @Test
    fun `timeout resolves once and ignores late Play services callbacks`() {
        val scheduler = ManualDeadlineScheduler()
        val subject = deadline(scheduler)
        val results = mutableListOf<Result<Unit>>()
        lateinit var succeed: () -> Unit
        lateinit var fail: (Throwable) -> Unit

        subject.attach(
            kind = AndroidGeofenceMutationKind.REGISTRATION,
            onSuccess = { results += Result.success(Unit) },
            onFailure = { results += Result.failure(it) },
            attachListeners = { onSuccess, onFailure ->
                succeed = onSuccess
                fail = onFailure
            }
        )

        scheduler.fire()
        succeed()
        fail(IllegalStateException("late"))

        val failure = assertIs<AndroidGeofenceMutationTimeoutException>(
            results.single().exceptionOrNull()
        )
        assertEquals(AndroidGeofenceMutationKind.REGISTRATION, failure.kind)
    }

    @Test
    fun `success cancels deadline and late timeout cannot resolve failure`() {
        val scheduler = ManualDeadlineScheduler()
        val subject = deadline(scheduler)
        val events = mutableListOf<String>()

        subject.attach(
            kind = AndroidGeofenceMutationKind.REMOVAL,
            onSuccess = { events += "success" },
            onFailure = { events += "failure" },
            attachListeners = { succeed, _ -> succeed() }
        )
        scheduler.fire()

        assertEquals(listOf("success"), events)
        assertTrue(scheduler.cancelled)
    }

    @Test
    fun `listener wiring failure abandons deadline and remains synchronous`() {
        val scheduler = ManualDeadlineScheduler()
        val subject = deadline(scheduler)
        var callbackCount = 0

        assertFailsWith<IllegalArgumentException> {
            subject.attach(
                kind = AndroidGeofenceMutationKind.REMOVAL,
                onSuccess = { callbackCount += 1 },
                onFailure = { callbackCount += 1 },
                attachListeners = { _, _ -> throw IllegalArgumentException("wiring") }
            )
        }
        scheduler.fire()

        assertEquals(0, callbackCount)
        assertTrue(scheduler.cancelled)
    }

    @Test
    fun `timeout releases serialized mutation ownership exactly once`() {
        val scheduler = ManualDeadlineScheduler()
        val subject = deadline(scheduler)
        val dispatcher = DeadlineQueueDispatcher()
        val runner = GeofenceMutationRunner(GeofenceMutationQueue(dispatcher::dispatch))
        val events = mutableListOf<String>()
        lateinit var lateSuccess: () -> Unit

        runner.run(
            callback = { events += "first:${it.isFailure}" },
            start = { complete ->
                subject.attach(
                    kind = AndroidGeofenceMutationKind.REMOVAL,
                    onSuccess = { complete(Result.success(Unit)) },
                    onFailure = { complete(Result.failure(it)) },
                    attachListeners = { succeed, _ -> lateSuccess = succeed }
                )
            }
        )
        runner.run(
            callback = { events += "second" },
            start = { it(Result.success(Unit)) }
        )

        dispatcher.runNext()
        scheduler.fire()
        dispatcher.runNext()
        lateSuccess()
        dispatcher.runNext()

        assertEquals(listOf("first:true", "second"), events)
        assertEquals(0, dispatcher.pendingCount)
    }

    private fun deadline(scheduler: ManualDeadlineScheduler) =
        PlayServicesGeofenceMutationDeadline(
            timeoutMillis = PLAY_SERVICES_GEOFENCE_MUTATION_TIMEOUT_MILLIS,
            schedule = scheduler::schedule
        )
}

private class DeadlineQueueDispatcher {
    private val pending = ArrayDeque<() -> Unit>()
    val pendingCount: Int get() = pending.size

    fun dispatch(operation: () -> Unit) {
        pending.addLast(operation)
    }

    fun runNext() {
        pending.removeFirst().invoke()
    }
}

private class ManualDeadlineScheduler {
    private var action: (() -> Unit)? = null
    var cancelled = false
        private set

    fun schedule(delayMillis: Long, action: () -> Unit): () -> Unit {
        assertEquals(PLAY_SERVICES_GEOFENCE_MUTATION_TIMEOUT_MILLIS, delayMillis)
        this.action = action
        return { cancelled = true }
    }

    fun fire() {
        if (!cancelled) action?.invoke()
    }
}
