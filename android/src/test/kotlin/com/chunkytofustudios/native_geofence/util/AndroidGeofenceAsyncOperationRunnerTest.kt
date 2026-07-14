package com.chunkytofustudios.native_geofence.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame

class AndroidGeofenceAsyncOperationRunnerTest {
    @Test
    fun `synchronous operation creation failure reaches the mapped failure route`() {
        val expected = IllegalStateException("synchronous remove failure")
        val failures = mutableListOf<Throwable>()

        runAndroidGeofenceAsyncOperation(
            begin = { throw expected },
            onSuccess = { error("Unexpected success") },
            onFailure = failures::add,
        )

        assertSame(expected, failures.single())
    }

    @Test
    fun `listener attachment failure wins over late task callbacks`() {
        val expected = UnsupportedOperationException("listener wiring failed")
        val failures = mutableListOf<Throwable>()
        var successes = 0
        lateinit var lateSuccess: () -> Unit
        lateinit var lateFailure: (Throwable) -> Unit

        runAndroidGeofenceAsyncOperation(
            begin = {
                AndroidGeofenceAsyncOperation { onSuccess, onFailure ->
                    lateSuccess = onSuccess
                    lateFailure = onFailure
                    throw expected
                }
            },
            onSuccess = { successes += 1 },
            onFailure = failures::add,
        )
        lateSuccess()
        lateFailure(IllegalArgumentException("late"))

        assertEquals(0, successes)
        assertSame(expected, failures.single())
    }
}
