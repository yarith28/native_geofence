package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.bridge.NativeGeofenceCallbackEnqueueResult
import com.chunkytofustudios.native_geofence.bridge.NativeGeofenceCallbackCompletion
import com.chunkytofustudios.native_geofence.bridge.toPublicEnqueueResult
import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CallbackDeliveryPolicyTest {
    @Test
    fun `public enqueue completion resolves once across competing outcomes`() {
        val outcomes = mutableListOf<NativeGeofenceCallbackEnqueueResult>()
        val completion = NativeGeofenceCallbackCompletion(outcomes::add)

        val accepted = Thread {
            completion.complete(NativeGeofenceCallbackEnqueueResult.ACCEPTED)
        }
        val rejected = Thread {
            completion.complete(NativeGeofenceCallbackEnqueueResult.REJECTED)
        }
        accepted.start()
        rejected.start()
        accepted.join()
        rejected.join()
        completion.complete(NativeGeofenceCallbackEnqueueResult.UNCONFIRMED)

        assertEquals(1, outcomes.size)
    }

    @Test
    fun `infrastructure and Dart failures retry within the bound`() {
        val failures = listOf(
            CallbackDeliveryFailure.INFRASTRUCTURE,
            CallbackDeliveryFailure.DART_DELIVERY,
            CallbackDeliveryFailure.STARTUP_TIMEOUT,
            CallbackDeliveryFailure.API_READY_TIMEOUT,
            CallbackDeliveryFailure.CALLBACK_TIMEOUT
        )
        failures.forEach { failure ->
            assertEquals(
                CallbackDeliveryDecision(
                    CallbackWorkerResult.RETRY,
                    cleanupPayload = false
                ),
                CallbackDeliveryPolicy.failure(failure, runAttemptCount = 0)
            )
        }
    }

    @Test
    fun `retry exhaustion becomes a cleaned terminal drop that continues the queue`() {
        assertEquals(
            CallbackDeliveryDecision(
                CallbackWorkerResult.SUCCESS,
                cleanupPayload = true
            ),
            CallbackDeliveryPolicy.failure(
                CallbackDeliveryFailure.DART_DELIVERY,
                runAttemptCount = CallbackDeliveryPolicy.MAX_DELIVERY_ATTEMPTS - 1
            )
        )
    }

    @Test
    fun `invalid and missing callbacks are terminal while generic Dart errors retry`() {
        val callbackNotFound = FlutterError(
            NativeGeofenceErrorCode.CALLBACK_NOT_FOUND.raw.toString(),
            "missing"
        )
        val callbackInvalid = FlutterError(
            NativeGeofenceErrorCode.CALLBACK_INVALID.raw.toString(),
            "invalid"
        )

        assertEquals(
            CallbackDeliveryFailure.DART_CALLBACK_NOT_FOUND,
            CallbackDeliveryPolicy.classifyDartError(callbackNotFound)
        )
        assertEquals(
            CallbackDeliveryFailure.DART_CALLBACK_INVALID,
            CallbackDeliveryPolicy.classifyDartError(callbackInvalid)
        )
        assertEquals(
            CallbackDeliveryFailure.DART_DELIVERY,
            CallbackDeliveryPolicy.classifyDartError(IllegalStateException("late"))
        )
        assertTrue(
            CallbackDeliveryPolicy.requiresCallbackRefresh(
                CallbackDeliveryFailure.DART_CALLBACK_NOT_FOUND
            )
        )
        assertTrue(
            CallbackDeliveryPolicy.requiresCallbackRefresh(
                CallbackDeliveryFailure.DART_CALLBACK_INVALID
            )
        )
        assertFalse(
            CallbackDeliveryPolicy.requiresCallbackRefresh(
                CallbackDeliveryFailure.DISPATCHER_NOT_FOUND
            )
        )
        assertFalse(
            CallbackDeliveryPolicy.requiresCallbackRefresh(
                CallbackDeliveryFailure.INFRASTRUCTURE
            )
        )
    }
}

class CallbackWorkEnqueueCoordinatorTest {
    @Test
    fun `confirmed enqueue retains payload and completes once`() {
        var observed: ((Result<Unit>) -> Unit)? = null
        val deleted = mutableListOf<String>()
        val outcomes = mutableListOf<CallbackEnqueueOutcome>()
        val subject = CallbackWorkEnqueueCoordinator {
            deleted += it
            true
        }

        subject.enqueue(
            payloadReference = "payload",
            start = { CallbackEnqueueOperation { observed = it } },
            completion = outcomes::add
        )
        assertTrue(outcomes.isEmpty())
        observed?.invoke(Result.success(Unit))
        observed?.invoke(Result.failure(IllegalStateException("late")))

        assertTrue(deleted.isEmpty())
        assertEquals(listOf(CallbackEnqueueOutcome.ACCEPTED), outcomes)
    }

    @Test
    fun `definitive enqueue failure deletes payload and completes once`() {
        var observed: ((Result<Unit>) -> Unit)? = null
        val deleted = mutableListOf<String>()
        val outcomes = mutableListOf<CallbackEnqueueOutcome>()
        val subject = CallbackWorkEnqueueCoordinator {
            deleted += it
            true
        }

        subject.enqueue(
            payloadReference = "payload",
            start = { CallbackEnqueueOperation { observed = it } },
            completion = outcomes::add
        )
        observed?.invoke(Result.failure(IllegalStateException("rejected")))
        observed?.invoke(Result.success(Unit))

        assertEquals(listOf("payload"), deleted)
        assertEquals(listOf(CallbackEnqueueOutcome.REJECTED), outcomes)
    }

    @Test
    fun `synchronous pre-operation failure deletes payload`() {
        val deleted = mutableListOf<String>()
        val outcomes = mutableListOf<CallbackEnqueueOutcome>()
        val subject = CallbackWorkEnqueueCoordinator {
            deleted += it
            true
        }

        subject.enqueue(
            payloadReference = "payload",
            start = { throw IllegalStateException("before operation") },
            completion = outcomes::add
        )

        assertEquals(listOf("payload"), deleted)
        assertEquals(listOf(CallbackEnqueueOutcome.REJECTED), outcomes)
    }

    @Test
    fun `observer registration ambiguity retains payload`() {
        val deleted = mutableListOf<String>()
        val outcomes = mutableListOf<CallbackEnqueueOutcome>()
        val subject = CallbackWorkEnqueueCoordinator {
            deleted += it
            true
        }

        subject.enqueue(
            payloadReference = "payload",
            start = {
                CallbackEnqueueOperation { throw IllegalStateException("observer") }
            },
            completion = outcomes::add
        )

        assertTrue(deleted.isEmpty())
        assertEquals(listOf(CallbackEnqueueOutcome.UNCONFIRMED), outcomes)
    }

    @Test
    fun `observer interruption ambiguity retains payload`() {
        val deleted = mutableListOf<String>()
        val outcomes = mutableListOf<CallbackEnqueueOutcome>()
        val subject = CallbackWorkEnqueueCoordinator {
            deleted += it
            true
        }

        subject.enqueue(
            payloadReference = "payload",
            start = {
                CallbackEnqueueOperation { complete ->
                    complete(
                        Result.failure(
                            CallbackEnqueueUnconfirmedException(
                                InterruptedException("interrupted")
                            )
                        )
                    )
                }
            },
            completion = outcomes::add
        )

        assertTrue(deleted.isEmpty())
        assertEquals(listOf(CallbackEnqueueOutcome.UNCONFIRMED), outcomes)
    }
}

class NativeGeofenceCallbackDeliveryResultTest {
    @Test
    fun `public ownership results preserve all coordinator outcomes`() {
        assertEquals(
            NativeGeofenceCallbackEnqueueResult.ACCEPTED,
            CallbackEnqueueOutcome.ACCEPTED.toPublicEnqueueResult(),
        )
        assertEquals(
            NativeGeofenceCallbackEnqueueResult.REJECTED,
            CallbackEnqueueOutcome.REJECTED.toPublicEnqueueResult(),
        )
        assertEquals(
            NativeGeofenceCallbackEnqueueResult.UNCONFIRMED,
            CallbackEnqueueOutcome.UNCONFIRMED.toPublicEnqueueResult(),
        )
    }
}

class BroadcastCompletionBarrierTest {
    @Test
    fun `mixed tasks finish only after every exact-once ticket`() {
        var completions = 0
        val barrier = BroadcastCompletionBarrier(4) { completions += 1 }
        val firstCallback = barrier.ticket()
        val secondCallback = barrier.ticket()
        val firstCleanup = barrier.ticket()
        val secondCleanup = barrier.ticket()

        secondCleanup()
        firstCallback()
        firstCallback()
        secondCallback()
        assertEquals(0, completions)

        firstCleanup()
        firstCleanup()
        secondCleanup()
        assertEquals(1, completions)
    }

    @Test
    fun `zero-task barrier completes immediately`() {
        var completions = 0

        BroadcastCompletionBarrier(0) { completions += 1 }

        assertEquals(1, completions)
    }
}

class CallbackDeliveryCoordinatorTest {
    @Test
    fun `startup API and callback watchdogs advance in order`() {
        val scheduler = ManualWatchdogScheduler()
        val timeouts = mutableListOf<CallbackDeliveryStage>()
        val coordinator = CallbackDeliveryCoordinator(
            timeoutMillis = { 10L },
            schedule = scheduler::schedule,
            onTimeout = timeouts::add
        )

        assertTrue(
            coordinator.advance(
                CallbackDeliveryStage.STARTUP,
                CallbackDeliveryStage.API_READY
            )
        )
        assertTrue(
            coordinator.advance(
                CallbackDeliveryStage.API_READY,
                CallbackDeliveryStage.CALLBACK
            )
        )
        assertTrue(coordinator.complete(CallbackDeliveryStage.CALLBACK))
        scheduler.fireAllIncludingCancelled()

        assertTrue(timeouts.isEmpty())
    }

    @Test
    fun `stale and late completions are ignored and timeout fires once`() {
        val scheduler = ManualWatchdogScheduler()
        val timeouts = mutableListOf<CallbackDeliveryStage>()
        val coordinator = CallbackDeliveryCoordinator(
            timeoutMillis = { 10L },
            schedule = scheduler::schedule,
            onTimeout = timeouts::add
        )
        assertTrue(
            coordinator.advance(
                CallbackDeliveryStage.STARTUP,
                CallbackDeliveryStage.API_READY
            )
        )

        scheduler.fire(index = 0, evenIfCancelled = true)
        assertTrue(timeouts.isEmpty())
        scheduler.fire(index = 1, evenIfCancelled = true)
        scheduler.fire(index = 1, evenIfCancelled = true)

        assertEquals(listOf(CallbackDeliveryStage.API_READY), timeouts)
        assertFalse(
            coordinator.advance(
                CallbackDeliveryStage.API_READY,
                CallbackDeliveryStage.CALLBACK
            )
        )
        assertFalse(coordinator.complete(CallbackDeliveryStage.API_READY))
    }
}

private class ManualWatchdogScheduler {
    private data class Scheduled(val action: () -> Unit, var cancelled: Boolean = false)

    private val scheduled = mutableListOf<Scheduled>()

    fun schedule(@Suppress("UNUSED_PARAMETER") delayMillis: Long, action: () -> Unit): () -> Unit {
        val item = Scheduled(action)
        scheduled += item
        return { item.cancelled = true }
    }

    fun fire(index: Int, evenIfCancelled: Boolean) {
        val item = scheduled[index]
        if (!item.cancelled || evenIfCancelled) item.action()
    }

    fun fireAllIncludingCancelled() {
        scheduled.forEach { it.action() }
    }
}
