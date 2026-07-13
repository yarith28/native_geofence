package com.chunkytofustudios.native_geofence.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ForegroundPromotionCoordinatorTest {
    @Test
    fun `confirmation completes the matching token exactly once`() {
        val scheduler = PromotionScheduler()
        val results = mutableListOf<Result<Unit>>()
        val coordinator = coordinator(scheduler)

        assertTrue(coordinator.request("token-1", results::add))
        assertTrue(coordinator.complete("token-1", Result.success(Unit)))
        assertFalse(coordinator.complete("token-1", Result.success(Unit)))
        scheduler.fireAllIncludingCancelled()

        assertEquals(1, results.size)
        assertTrue(results.single().isSuccess)
    }

    @Test
    fun `promotion timeout is terminal and ignores late service confirmation`() {
        val scheduler = PromotionScheduler()
        val results = mutableListOf<Result<Unit>>()
        val coordinator = coordinator(scheduler)

        assertTrue(coordinator.request("token-timeout", results::add))
        scheduler.fire(0)
        assertFalse(coordinator.complete("token-timeout", Result.success(Unit)))

        assertEquals("promotion-timeout", results.single().exceptionOrNull()?.message)
    }

    @Test
    fun `abandon cancels pending ownership without completing Dart`() {
        val scheduler = PromotionScheduler()
        val results = mutableListOf<Result<Unit>>()
        val coordinator = coordinator(scheduler)

        assertTrue(coordinator.request("token-abandon", results::add))
        assertTrue(coordinator.abandon("token-abandon"))
        scheduler.fireAllIncludingCancelled()
        assertFalse(coordinator.complete("token-abandon", Result.success(Unit)))

        assertTrue(results.isEmpty())
    }

    @Test
    fun `independent tokens do not consume each other's confirmation`() {
        val scheduler = PromotionScheduler()
        val results = mutableListOf<String>()
        val coordinator = coordinator(scheduler)

        assertTrue(coordinator.request("a") { results += "a" })
        assertTrue(coordinator.request("b") { results += "b" })
        assertTrue(coordinator.complete("b", Result.success(Unit)))
        assertEquals(listOf("b"), results)
        assertTrue(coordinator.complete("a", Result.success(Unit)))
        assertEquals(listOf("b", "a"), results)
    }

    private fun coordinator(scheduler: PromotionScheduler) =
        ForegroundPromotionCoordinator(
            timeoutMillis = 10L,
            schedule = scheduler::schedule,
            timeoutError = { IllegalStateException("promotion-timeout") }
        )
}

private class PromotionScheduler {
    private data class Scheduled(val action: () -> Unit, var cancelled: Boolean = false)

    private val scheduled = mutableListOf<Scheduled>()

    fun schedule(@Suppress("UNUSED_PARAMETER") delayMillis: Long, action: () -> Unit): () -> Unit {
        val item = Scheduled(action)
        scheduled += item
        return { item.cancelled = true }
    }

    fun fire(index: Int) {
        val item = scheduled[index]
        if (!item.cancelled) item.action()
    }

    fun fireAllIncludingCancelled() {
        scheduled.forEach { it.action() }
    }
}
