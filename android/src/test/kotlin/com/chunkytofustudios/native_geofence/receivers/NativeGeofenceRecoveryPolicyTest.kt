package com.chunkytofustudios.native_geofence.receivers

import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode
import com.google.android.gms.location.GeofenceStatusCodes
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class NativeGeofenceRecoveryPolicyTest {
    @Test
    fun `retry ladder is four exponential delays then ten hourly delays`() {
        assertEquals(4L, delayMinutes(1))
        assertEquals(8L, delayMinutes(2))
        assertEquals(16L, delayMinutes(3))
        assertEquals(32L, delayMinutes(4))
        assertEquals(60L, delayMinutes(5))
        assertEquals(60L, delayMinutes(14))
        assertEquals(
            660L,
            (1..NativeGeofenceRecoveryPolicy.MAX_ATTEMPTS).sumOf(::delayMinutes)
        )
    }

    @Test
    fun `retry step gives terminal and prerequisite states deterministic precedence`() {
        assertEquals(
            RecoveryRetryStep.DONE,
            NativeGeofenceRecoveryPolicy.retryStep(99, false, false, false)
        )
        assertEquals(
            RecoveryRetryStep.WAIT_FOR_PERMISSION,
            NativeGeofenceRecoveryPolicy.retryStep(1, true, false, false)
        )
        assertEquals(
            RecoveryRetryStep.WAIT_FOR_LOCATION,
            NativeGeofenceRecoveryPolicy.retryStep(1, true, false, true)
        )
        assertEquals(
            RecoveryRetryStep.RECOVER,
            NativeGeofenceRecoveryPolicy.retryStep(14, true, true, true)
        )
        assertEquals(
            RecoveryRetryStep.GIVE_UP,
            NativeGeofenceRecoveryPolicy.retryStep(15, true, true, true)
        )
    }

    @Test
    fun `contract errors are terminal while infrastructure errors retry`() {
        val terminalCodes = listOf(
            NativeGeofenceErrorCode.INVALID_ARGUMENTS,
            NativeGeofenceErrorCode.ANDROID_MANIFEST_COMPONENT_MISSING,
            NativeGeofenceErrorCode.MISSING_LOCATION_PERMISSION,
            NativeGeofenceErrorCode.MISSING_BACKGROUND_LOCATION_PERMISSION
        )
        terminalCodes.forEach { code ->
            assertFalse(
                NativeGeofenceRecoveryPolicy.isRetryable(
                    FlutterError(code.raw.toString(), "terminal")
                )
            )
        }
        assertTrue(
            NativeGeofenceRecoveryPolicy.isRetryable(
                FlutterError(
                    NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                    "transient"
                )
            )
        )
        assertTrue(NativeGeofenceRecoveryPolicy.isRetryable(IllegalStateException("transient")))
    }

    private fun delayMinutes(attempt: Int): Long = TimeUnit.MILLISECONDS.toMinutes(
        NativeGeofenceRecoveryPolicy.retryDelayMillis(attempt)
    )
}

class NativeGeofenceRecoveryOperationBudgetTest {
    @Test
    fun `one ordinary worker admits at most ten of one hundred platform operations`() {
        val budget = NativeGeofenceRecoveryOperationBudget(
            maxOperations = NativeGeofenceRecoveryPolicy.MAX_OPERATIONS_PER_WORKER_BATCH,
            shouldContinue = { true },
        )

        val admissions = (1..100).map { budget.admitNext() }

        assertEquals(
            List(10) { RecoveryOperationAdmission.START } +
                List(90) { RecoveryOperationAdmission.BATCH_EXHAUSTED },
            admissions,
        )
        assertEquals(10, budget.startedOperations)
    }

    @Test
    fun `cancellation prevents every later operation admission`() {
        var running = true
        val budget = NativeGeofenceRecoveryOperationBudget(10) { running }

        assertEquals(RecoveryOperationAdmission.START, budget.admitNext())
        running = false

        assertEquals(RecoveryOperationAdmission.CANCELLED, budget.admitNext())
        assertEquals(RecoveryOperationAdmission.CANCELLED, budget.admitNext())
        assertEquals(1, budget.startedOperations)
        assertTrue(budget.isCancelled())
    }

    @Test
    fun `durable completed IDs are skipped by the next batch`() {
        val candidates = (1..100).map { "fence-$it" }
        val completed = candidates.take(10).toSet()

        val resumed = candidates.filter {
            NativeGeofenceRecoveryProgressPolicy.shouldProcess(it, completed)
        }

        assertEquals("fence-11", resumed.first())
        assertEquals(90, resumed.size)
        assertTrue(resumed.none(completed::contains))
    }
}

class NativeGeofenceRecoverySchedulePolicyTest {
    @Test
    fun `first ticket accepts only attempt one`() {
        assertTrue(shouldSchedule(scheduled = null, requestedAttempt = 1))
        assertFalse(shouldSchedule(scheduled = null, requestedAttempt = 0))
        assertFalse(shouldSchedule(scheduled = null, requestedAttempt = 2))
        assertFalse(shouldSchedule(scheduled = null, requestedAttempt = 15))
    }

    @Test
    fun `next ticket accepts only exact successor in current generation`() {
        val scheduled = RecoveryRetryTicket(generation = 7, attempt = 2)

        assertTrue(shouldSchedule(scheduled, requestedAttempt = 3))
        assertFalse(shouldSchedule(scheduled, requestedAttempt = 2))
        assertFalse(shouldSchedule(scheduled, requestedAttempt = 4))
        assertFalse(
            NativeGeofenceRecoverySchedulePolicy.shouldSchedule(
                currentGeneration = 7,
                scheduled = scheduled,
                requested = RecoveryRetryTicket(6, 3)
            )
        )
    }

    @Test
    fun `worker admission requires exact persisted generation and attempt`() {
        val scheduled = RecoveryRetryTicket(9, 4)

        assertTrue(
            NativeGeofenceRecoverySchedulePolicy.shouldRunWorker(
                scheduled,
                RecoveryRetryTicket(9, 4)
            )
        )
        assertFalse(
            NativeGeofenceRecoverySchedulePolicy.shouldRunWorker(
                scheduled,
                RecoveryRetryTicket(9, 3)
            )
        )
        assertFalse(
            NativeGeofenceRecoverySchedulePolicy.shouldRunWorker(
                scheduled,
                RecoveryRetryTicket(8, 4)
            )
        )
        assertFalse(
            NativeGeofenceRecoverySchedulePolicy.shouldRunWorker(
                null,
                RecoveryRetryTicket(9, 4)
            )
        )
    }

    @Test
    fun `terminal facts require exact current generation and attempt authority`() {
        val worker = RecoveryRetryTicket(9, 4)

        assertTrue(
            NativeGeofenceRecoverySchedulePolicy.mayPublishTerminal(9, worker, worker)
        )
        assertFalse(
            NativeGeofenceRecoverySchedulePolicy.mayPublishTerminal(
                10,
                RecoveryRetryTicket(10, 1),
                worker
            )
        )
        assertFalse(
            NativeGeofenceRecoverySchedulePolicy.mayPublishTerminal(
                9,
                RecoveryRetryTicket(9, 5),
                worker
            )
        )
        assertFalse(
            NativeGeofenceRecoverySchedulePolicy.mayPublishTerminal(9, null, worker)
        )
    }

    @Test
    fun `worker terminal outcomes are fixed privacy-safe facts`() {
        assertEquals(
            listOf(
                Triple("completed", true, RecoveryWorkerTerminalOutcome.COMPLETED),
                Triple(
                    "non_retryable_failure",
                    false,
                    RecoveryWorkerTerminalOutcome.NON_RETRYABLE_FAILURE
                ),
                Triple("permission_wait", false, RecoveryWorkerTerminalOutcome.PERMISSION_WAIT),
                Triple("gave_up", false, RecoveryWorkerTerminalOutcome.GAVE_UP),
                Triple(
                    "retry_schedule_failed",
                    false,
                    RecoveryWorkerTerminalOutcome.RETRY_SCHEDULE_FAILED
                ),
                Triple("stale_generation", false, RecoveryWorkerTerminalOutcome.STALE_GENERATION)
            ),
            RecoveryWorkerTerminalOutcome.entries.map {
                Triple(it.storageName, it.succeeded, it)
            }
        )
        RecoveryWorkerTerminalOutcome.entries.forEach { outcome ->
            assertFalse(outcome.storageName.contains("reason"))
            assertFalse(outcome.storageName.contains("callback"))
            assertFalse(outcome.storageName.contains("latitude"))
            assertFalse(outcome.storageName.contains("longitude"))
        }
    }

    private fun shouldSchedule(
        scheduled: RecoveryRetryTicket?,
        requestedAttempt: Int
    ) = NativeGeofenceRecoverySchedulePolicy.shouldSchedule(
        currentGeneration = 7,
        scheduled = scheduled,
        requested = RecoveryRetryTicket(7, requestedAttempt)
    )
}

class GeofenceBroadcastOutcomeClassifierTest {
    @Test
    fun `not available starts recovery while other service errors are ignored`() {
        assertIs<GeofenceBroadcastOutcome.GeofenceNotAvailable>(
            GeofenceBroadcastOutcomeClassifier.fromErrorCode(
                GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE
            )
        )
        assertIs<GeofenceBroadcastOutcome.Ignored>(
            GeofenceBroadcastOutcomeClassifier.fromErrorCode(
                GeofenceStatusCodes.GEOFENCE_TOO_MANY_GEOFENCES
            )
        )
    }
}
