package com.chunkytofustudios.native_geofence.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class AndroidGeofenceRegistrationTransactionTest {
    @Test
    fun `new registration synchronous invocation failure restores empty snapshot`() {
        val fixture = Fixture().apply {
            currentBeginFailure = IllegalStateException("synchronous add failure")
        }

        fixture.start()

        val failure = fixture.singleFailure()
        assertEquals(AndroidGeofenceRegistrationFailureStage.PLATFORM_INVOCATION, failure.stage)
        assertEquals(AndroidGeofenceTransactionStepOutcome.SUCCEEDED, failure.durableRestoration)
        assertEquals(1, fixture.restoreCalls)
        assertEquals(0, fixture.compensation.attachCalls)
        assertEquals(1, fixture.results.size)
    }

    @Test
    fun `replacement synchronous invocation failure restores complete prior snapshot`() {
        val fixture = Fixture(previousRegistrationExists = true).apply {
            currentBeginFailure = UnsupportedOperationException("synchronous replacement failure")
        }

        fixture.start()

        val failure = fixture.singleFailure()
        assertEquals(AndroidGeofenceRegistrationFailureStage.PLATFORM_INVOCATION, failure.stage)
        assertEquals(AndroidGeofenceTransactionStepOutcome.SUCCEEDED, failure.durableRestoration)
        assertEquals(1, fixture.restoreCalls)
        assertEquals(0, fixture.preserveCalls)
    }

    @Test
    fun `synchronous invocation reports durable restoration failure`() {
        val fixture = Fixture(previousRegistrationExists = true).apply {
            currentBeginFailure = IllegalStateException("synchronous add failure")
            restoreSucceeds = false
        }

        fixture.start()

        val failure = fixture.singleFailure()
        assertEquals(AndroidGeofenceTransactionStepOutcome.FAILED, failure.durableRestoration)
        assertTrue(failure.message.orEmpty().contains("durableRestoration=failed"))
        assertTrue(failure.privacySafeDetails().contains("primaryCause=IllegalStateException"))
        assertFalse(failure.privacySafeDetails().contains("synchronous add failure"))
    }

    @Test
    fun `active commit failure compensates and removes provisional new record`() {
        val fixture = Fixture().apply { markActiveSucceeds = false }

        fixture.start()
        fixture.current.succeed()
        fixture.compensation.succeed()

        val failure = fixture.singleFailure()
        assertEquals(
            AndroidGeofenceRegistrationFailureStage.ACTIVE_STATE_PERSISTENCE,
            failure.stage,
        )
        assertEquals(AndroidGeofenceTransactionStepOutcome.SUCCEEDED, failure.compensation)
        assertEquals(AndroidGeofenceTransactionStepOutcome.SUCCEEDED, failure.durableRestoration)
        assertEquals(1, fixture.restoreCalls)
        assertEquals(0, fixture.preserveCalls)
    }

    @Test
    fun `failed compensation keeps raw provisional evidence for new registration`() {
        val fixture = Fixture().apply { markActiveSucceeds = false }

        fixture.start()
        fixture.current.succeed()
        fixture.compensation.fail(IllegalStateException("remove failed"))

        val failure = fixture.singleFailure()
        assertEquals(AndroidGeofenceTransactionStepOutcome.FAILED, failure.compensation)
        assertEquals(
            AndroidGeofenceTransactionStepOutcome.NOT_ATTEMPTED,
            failure.durableRestoration,
        )
        assertEquals(AndroidGeofenceTransactionStepOutcome.SUCCEEDED, failure.evidencePersistence)
        assertEquals(0, fixture.restoreCalls)
        assertEquals(1, fixture.preserveCalls)
    }

    @Test
    fun `replacement rollback restores prior platform registration and exact snapshot`() {
        val fixture = Fixture(
            previousRegistrationExists = true,
            previousPlatformRestorationRequired = true,
        ).apply { markActiveSucceeds = false }

        fixture.start()
        fixture.current.succeed()
        fixture.compensation.succeed()
        fixture.previousPlatformRestoration.succeed()

        val failure = fixture.singleFailure()
        assertEquals(AndroidGeofenceTransactionStepOutcome.SUCCEEDED, failure.compensation)
        assertEquals(AndroidGeofenceTransactionStepOutcome.SUCCEEDED, failure.durableRestoration)
        assertEquals(
            AndroidGeofenceTransactionStepOutcome.SUCCEEDED,
            failure.previousPlatformRestoration,
        )
        assertEquals(2, fixture.restoreCalls)
        assertEquals(0, fixture.preserveCalls)
    }

    @Test
    fun `previous platform restoration failure leaves inactive recoverable evidence`() {
        val fixture = Fixture(
            previousRegistrationExists = true,
            previousPlatformRestorationRequired = true,
        ).apply { markActiveSucceeds = false }

        fixture.start()
        fixture.current.succeed()
        fixture.compensation.succeed()
        fixture.previousPlatformRestoration.fail(IllegalArgumentException("restore failed"))
        fixture.previousPlatformRestoration.succeed()
        fixture.previousPlatformRestoration.fail(IllegalStateException("late restore failure"))

        val failure = fixture.singleFailure()
        assertEquals(
            AndroidGeofenceTransactionStepOutcome.FAILED,
            failure.previousPlatformRestoration,
        )
        assertEquals(AndroidGeofenceTransactionStepOutcome.SUCCEEDED, failure.evidencePersistence)
        assertEquals(1, fixture.preserveCalls)
        assertEquals(1, fixture.results.size)
    }

    @Test
    fun `listener wiring failure compensates and ignores every late current callback`() {
        val fixture = Fixture().apply {
            current.throwAfterAttach = IllegalStateException("listener wiring failed")
        }

        fixture.start()
        fixture.compensation.succeed()
        assertEquals(1, fixture.results.size)

        fixture.current.succeed()
        fixture.current.fail(IllegalStateException("late failure"))

        val failure = fixture.singleFailure()
        assertEquals(
            AndroidGeofenceRegistrationFailureStage.PLATFORM_LISTENER_REGISTRATION,
            failure.stage,
        )
        assertEquals(1, fixture.results.size)
        assertEquals(0, fixture.markActiveCalls)
    }

    @Test
    fun `successful completion is exact once despite duplicate task callbacks`() {
        val fixture = Fixture()

        fixture.start()
        fixture.current.succeed()
        fixture.current.succeed()
        fixture.current.fail(IllegalStateException("late failure"))

        assertEquals(1, fixture.results.size)
        assertTrue(fixture.results.single().isSuccess)
        assertEquals(1, fixture.markActiveCalls)
    }
}

private class Fixture(
    private val previousRegistrationExists: Boolean = false,
    private val previousPlatformRestorationRequired: Boolean = false,
) {
    val current = ManualAsyncOperation()
    val compensation = ManualAsyncOperation()
    val previousPlatformRestoration = ManualAsyncOperation()
    val results = mutableListOf<Result<Unit>>()

    var currentBeginFailure: Throwable? = null
    var saveProvisionalSucceeds = true
    var markActiveSucceeds = true
    var restoreSucceeds = true
    var preserveSucceeds = true
    var markActiveCalls = 0
    var restoreCalls = 0
    var preserveCalls = 0

    fun start() {
        AndroidGeofenceRegistrationTransaction(
            previousRegistrationExists = previousRegistrationExists,
            previousPlatformRestorationRequired = previousPlatformRestorationRequired,
            saveProvisional = { saveProvisionalSucceeds },
            markActive = {
                markActiveCalls += 1
                markActiveSucceeds
            },
            restoreDurableSnapshot = {
                restoreCalls += 1
                restoreSucceeds
            },
            preserveInactiveEvidence = {
                preserveCalls += 1
                preserveSucceeds
            },
            beginCurrentRegistration = {
                currentBeginFailure?.let { throw it }
                current
            },
            beginCompensation = { compensation },
            beginPreviousPlatformRestoration = { previousPlatformRestoration },
            completion = results::add,
        ).start()
    }

    fun singleFailure(): AndroidGeofenceRegistrationTransactionException =
        assertIs(results.single().exceptionOrNull())
}

private class ManualAsyncOperation : AndroidGeofenceAsyncOperation {
    var throwAfterAttach: Throwable? = null
    var attachCalls = 0
    private var onSuccess: (() -> Unit)? = null
    private var onFailure: ((Throwable) -> Unit)? = null

    override fun attach(onSuccess: () -> Unit, onFailure: (Throwable) -> Unit) {
        attachCalls += 1
        this.onSuccess = onSuccess
        this.onFailure = onFailure
        throwAfterAttach?.let { throw it }
    }

    fun succeed() {
        onSuccess?.invoke()
    }

    fun fail(error: Throwable) {
        onFailure?.invoke(error)
    }
}
