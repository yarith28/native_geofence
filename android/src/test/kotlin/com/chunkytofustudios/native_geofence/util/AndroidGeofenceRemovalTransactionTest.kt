package com.chunkytofustudios.native_geofence.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class AndroidGeofenceRemovalTransactionTest {
    @Test
    fun `success clears pending state after platform confirmation`() {
        val harness = RemovalHarness()

        harness.start()
        harness.succeed()

        assertEquals(listOf("mark", "begin", "attach", "clear", "complete"), harness.events)
        assertTrue(harness.result.isSuccess)
    }

    @Test
    fun `confirmed failure restores prior state without reconciliation`() {
        val failure = IllegalArgumentException("confirmed")
        val harness = RemovalHarness()

        harness.start()
        harness.fail(failure)

        assertEquals(
            listOf("mark", "begin", "attach", "restore:snapshot", "complete"),
            harness.events,
        )
        assertEquals(failure, harness.result.exceptionOrNull())
    }

    @Test
    fun `timeout retains pending state and schedules reconciliation`() {
        val timeout = AndroidGeofenceMutationTimeoutException(
            AndroidGeofenceMutationKind.REMOVAL
        )
        val harness = RemovalHarness()

        harness.start()
        harness.fail(timeout)

        assertEquals(
            listOf("mark", "begin", "attach", "complete", "reconcile"),
            harness.events,
        )
        assertEquals(timeout, harness.result.exceptionOrNull())
    }

    @Test
    fun `late platform result after timeout cannot clear or restore state`() {
        val harness = RemovalHarness()

        harness.start()
        harness.fail(
            AndroidGeofenceMutationTimeoutException(AndroidGeofenceMutationKind.REMOVAL)
        )
        harness.succeed()
        harness.fail(IllegalStateException("late"))

        assertEquals(
            listOf("mark", "begin", "attach", "complete", "reconcile"),
            harness.events,
        )
    }

    @Test
    fun `synchronous begin failure restores the snapshot`() {
        val failure = IllegalStateException("begin")
        val harness = RemovalHarness(beginFailure = failure)

        harness.start()

        assertEquals(
            listOf("mark", "begin", "restore:snapshot", "complete"),
            harness.events,
        )
        assertEquals(failure, harness.result.exceptionOrNull())
    }

    @Test
    fun `listener attachment failure retains pending state`() {
        val failure = IllegalStateException("attach")
        val harness = RemovalHarness(attachFailure = failure)

        harness.start()

        assertEquals(
            listOf("mark", "begin", "attach", "complete", "reconcile"),
            harness.events,
        )
        assertEquals(failure, harness.result.exceptionOrNull())
    }

    @Test
    fun `durable clear failure retains cleanup evidence for reconciliation`() {
        val harness = RemovalHarness(clearSucceeds = false)

        harness.start()
        harness.succeed()

        assertEquals(
            listOf("mark", "begin", "attach", "clear", "complete", "reconcile"),
            harness.events,
        )
        assertIs<IllegalStateException>(harness.result.exceptionOrNull())
    }

    @Test
    fun `failed rollback schedules reconciliation instead of losing ownership evidence`() {
        val harness = RemovalHarness(restoreSucceeds = false)

        harness.start()
        harness.fail(IllegalArgumentException("confirmed"))

        assertEquals(
            listOf(
                "mark",
                "begin",
                "attach",
                "restore:snapshot",
                "complete",
                "reconcile",
            ),
            harness.events,
        )
        assertIs<IllegalStateException>(harness.result.exceptionOrNull())
    }
}

private class RemovalHarness(
    private val beginFailure: Throwable? = null,
    private val attachFailure: Throwable? = null,
    private val clearSucceeds: Boolean = true,
    private val restoreSucceeds: Boolean = true,
) {
    val events = mutableListOf<String>()
    private var recordedResult: Result<Unit>? = null
    val result: Result<Unit>
        get() = requireNotNull(recordedResult)
    private lateinit var onSuccess: () -> Unit
    private lateinit var onFailure: (Throwable) -> Unit

    private val subject = AndroidGeofenceRemovalTransaction(
        snapshot = "snapshot",
        markRemovalPending = {
            events += "mark"
            true
        },
        restoreSnapshot = {
            events += "restore:$it"
            restoreSucceeds
        },
        beginRemoval = {
            events += "begin"
            beginFailure?.let { throw it }
            AndroidGeofenceAsyncOperation { success, failure ->
                events += "attach"
                onSuccess = success
                onFailure = failure
                attachFailure?.let { throw it }
            }
        },
        clearDurableState = {
            events += "clear"
            clearSucceeds
        },
        scheduleReconciliation = { events += "reconcile" },
        completion = {
            events += "complete"
            recordedResult = it
        },
    )

    fun start() = subject.start()

    fun succeed() = onSuccess()

    fun fail(error: Throwable) = onFailure(error)
}
