package com.chunkytofustudios.native_geofence.receivers

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class LocationModeRecoveryAdmissionTest {
    @Test
    fun `dynamic and manifest observations share one active admission`() {
        val gate = LocationModeRecoveryAdmissionGate(duplicateWindowMillis = 5_000L)

        val dynamic = assertNotNull(gate.tryAcquire(nowMillis = 1_000L))
        assertNull(gate.tryAcquire(nowMillis = 1_000L))
        gate.release(dynamic)

        // A second receiver observing the same broadcast remains suppressed even
        // if the first recovery completed synchronously.
        assertNull(gate.tryAcquire(nowMillis = 1_001L))
    }

    @Test
    fun `later distinct location event is admitted after duplicate window`() {
        val gate = LocationModeRecoveryAdmissionGate(duplicateWindowMillis = 5_000L)
        val first = assertNotNull(gate.tryAcquire(nowMillis = 10_000L))
        gate.release(first)

        assertNull(gate.tryAcquire(nowMillis = 14_999L))
        assertNotNull(gate.tryAcquire(nowMillis = 15_000L))
    }

    @Test
    fun `stale release cannot release a newer recovery`() {
        val gate = LocationModeRecoveryAdmissionGate(duplicateWindowMillis = 5_000L)
        val first = assertNotNull(gate.tryAcquire(nowMillis = 0L))
        gate.release(first)
        val second = assertNotNull(gate.tryAcquire(nowMillis = 5_000L))

        gate.release(first)
        assertNull(gate.tryAcquire(nowMillis = 20_000L))

        gate.release(second)
        assertNotNull(gate.tryAcquire(nowMillis = 20_000L))
    }

    @Test
    fun `admission finish releases exactly once`() {
        var releases = 0
        val admission = LocationModeRecoveryAdmission { releases += 1 }

        admission.finish()
        admission.finish()

        assertEquals(1, releases)
    }
}
