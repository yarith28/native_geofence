package com.chunkytofustudios.native_geofence.bridge

import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.ActiveGeofenceWire
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.generated.LocationWire
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertSame
import kotlin.test.assertTrue

class NativeGeofenceBridgeDecisionGateTest {
    @Test
    fun `first completion owns the decision and late completions are ignored`() {
        val scheduler = BridgeScheduler()
        val decisions = mutableListOf<NativeGeofenceBridgeDecision?>()
        val gate = NativeGeofenceBridgeDecisionGate(
            timeoutMillis = 10L,
            schedule = scheduler::schedule,
            onResolved = decisions::add
        )

        assertTrue(gate.resolve(NativeGeofenceBridgeDecision.Accept))
        assertFalse(gate.resolve(NativeGeofenceBridgeDecision.Decline))
        scheduler.fireIncludingCancelled()

        assertEquals(
            listOf<NativeGeofenceBridgeDecision?>(NativeGeofenceBridgeDecision.Accept),
            decisions
        )
    }

    @Test
    fun `ownership timeout falls through and ignores a late accept`() {
        val scheduler = BridgeScheduler()
        val decisions = mutableListOf<NativeGeofenceBridgeDecision?>()
        val gate = NativeGeofenceBridgeDecisionGate(
            timeoutMillis = 10L,
            schedule = scheduler::schedule,
            onResolved = decisions::add
        )

        scheduler.fire()
        assertFalse(gate.resolve(NativeGeofenceBridgeDecision.Accept))
        assertEquals(listOf<NativeGeofenceBridgeDecision?>(null), decisions)
    }

    @Test
    fun `production ownership deadline is independent from the main looper`() {
        val fired = CountDownLatch(1)
        var timeoutThread: String? = null

        NativeGeofenceBridgeTimeoutScheduler.schedule(0L) {
            timeoutThread = Thread.currentThread().name
            fired.countDown()
        }

        assertTrue(fired.await(2L, TimeUnit.SECONDS))
        assertEquals("native-geofence-bridge-timeout", timeoutThread)
    }
}

class NativeGeofenceBridgeMetadataTest {
    @Test
    fun `metadata keys preserve current and legacy bridge contracts`() {
        assertEquals(
            "com.chunkytofustudios.native_geofence.native_event_processor",
            Constants.NATIVE_EVENT_PROCESSOR_METADATA_KEY
        )
        assertEquals(
            "com.chunkytofustudios.native_geofence.BRIDGE_PROCESSOR",
            Constants.LEGACY_NATIVE_EVENT_PROCESSOR_METADATA_KEY
        )
    }

    @Test
    fun `legacy metadata remains compatible while the current key takes precedence`() {
        assertEquals(
            "legacy.Processor",
            NativeGeofenceBridgeCompatibility.preferredProcessorClassName(
                current = null,
                legacy = "legacy.Processor",
            ),
        )
        assertEquals(
            "current.Processor",
            NativeGeofenceBridgeCompatibility.preferredProcessorClassName(
                current = "current.Processor",
                legacy = "legacy.Processor",
            ),
        )
    }

    @Test
    fun `metadata discovery exceptions safely disable the processor`() {
        val className = NativeGeofenceBridgeCompatibility.processorClassNameOrNull {
            throw Exception("package metadata unavailable")
        }

        assertEquals(null, className)
    }

    @Test
    fun `typed lookup distinguishes absent current legacy and failed metadata`() {
        assertIs<NativeGeofenceBridgeCompatibility.LookupResult.Absent>(
            NativeGeofenceBridgeCompatibility.lookupResult { null },
        )
        val current = assertIs<NativeGeofenceBridgeCompatibility.LookupResult.Found>(
            NativeGeofenceBridgeCompatibility.lookupResult {
                NativeGeofenceBridgeCompatibility.preferredProcessorMetadata(
                    current = "current.Processor",
                    legacy = "legacy.Processor",
                )
            },
        )
        assertEquals("manifest_current", current.metadata.source)
        val legacy = assertIs<NativeGeofenceBridgeCompatibility.LookupResult.Found>(
            NativeGeofenceBridgeCompatibility.lookupResult {
                NativeGeofenceBridgeCompatibility.preferredProcessorMetadata(
                    current = null,
                    legacy = "legacy.Processor",
                )
            },
        )
        assertEquals("manifest_legacy", legacy.metadata.source)
        assertIs<NativeGeofenceBridgeCompatibility.LookupResult.Failed>(
            NativeGeofenceBridgeCompatibility.lookupResult {
                throw IllegalStateException("metadata unavailable")
            },
        )
    }
}

class NativeGeofenceBridgeMapperTest {
    @Test
    fun `accepted event is owned while decline preserves the original`() {
        val original = params()

        assertIs<NativeGeofenceBridgeOutcome.Accepted>(
            NativeGeofenceBridgeMapper.outcome(
                original,
                NativeGeofenceBridgeDecision.Accept
            )
        )
        val declined = assertIs<NativeGeofenceBridgeOutcome.Continue>(
            NativeGeofenceBridgeMapper.outcome(
                original,
                NativeGeofenceBridgeDecision.Decline
            )
        )
        assertSame(original, declined.params)
    }

    @Test
    fun `valid transformation preserves delivery identity and callback routing`() {
        val original = params()
        val transformed = assertIs<NativeGeofenceBridgeOutcome.Continue>(
            NativeGeofenceBridgeMapper.outcome(
                original,
                NativeGeofenceBridgeDecision.Transform(
                    NativeGeofenceBridgeTransformation(
                        geofenceIds = listOf("b"),
                        transition = NativeGeofenceBridgeTransition.EXIT,
                        location = NativeGeofenceBridgeLocation(
                            latitude = 12.0,
                            longitude = 105.0,
                            accuracyMeters = 5.0,
                            isMock = true
                        )
                    )
                )
            )
        ).params

        assertEquals(listOf("b"), transformed.geofences.map { it.id })
        assertEquals(GeofenceEvent.EXIT, transformed.event)
        assertEquals(12.0, transformed.location?.latitude)
        assertEquals(91L, transformed.callbackHandle)
        assertEquals(123L, transformed.eventAtMillis)
        assertEquals("delivery-1", transformed.eventId)
        assertEquals("trace-1", transformed.traceId)
        assertEquals(mapOf("b" to 2L), transformed.callbackContextsByGeofenceId)
    }

    @Test
    fun `invalid transformation safely falls through unchanged`() {
        val original = params()
        val invalid = NativeGeofenceBridgeDecision.Transform(
            NativeGeofenceBridgeTransformation(
                geofenceIds = listOf("not-triggered"),
                transition = NativeGeofenceBridgeTransition.DWELL,
                location = null
            )
        )
        val outcome = assertIs<NativeGeofenceBridgeOutcome.Continue>(
            NativeGeofenceBridgeMapper.outcome(original, invalid)
        )

        assertSame(original, outcome.params)
    }

    @Test
    fun `bridge event exposes no callback handle or registration geometry`() {
        val event = NativeGeofenceBridgeMapper.event(params())

        assertEquals(listOf("a", "b"), event?.geofenceIds)
        assertEquals(NativeGeofenceBridgeTransition.ENTER, event?.transition)
        assertEquals("delivery-1", event?.eventId)
        assertEquals(456L, event?.location?.fixTimeMillis)
        assertEquals(789L, event?.location?.elapsedRealtimeNanos)
    }

    private fun params() = GeofenceCallbackParamsWire(
        geofences = listOf(active("a"), active("b")),
        event = GeofenceEvent.ENTER,
        location = LocationWire(
            latitude = 11.0,
            longitude = 104.0,
            accuracyMeters = 3.0,
            isMock = false,
            fixTimeMillis = 456L,
            elapsedRealtimeNanos = 789L,
        ),
        eventAtMillis = 123L,
        callbackHandle = 91L,
        eventId = "delivery-1",
        callbackContextsByGeofenceId = mapOf("a" to 1L, "b" to 2L),
        traceId = "trace-1",
    )

    private fun active(id: String) = ActiveGeofenceWire(
        id = id,
        location = LocationWire(
            latitude = 10.0,
            longitude = 103.0,
            accuracyMeters = null,
            isMock = false
        ),
        radiusMeters = 100.0,
        triggers = listOf(GeofenceEvent.ENTER, GeofenceEvent.EXIT),
        androidSettings = null
    )
}

private class BridgeScheduler {
    private lateinit var action: () -> Unit
    private var cancelled = false

    fun schedule(@Suppress("UNUSED_PARAMETER") delayMillis: Long, action: () -> Unit): () -> Unit {
        this.action = action
        return { cancelled = true }
    }

    fun fire() {
        if (!cancelled) action()
    }

    fun fireIncludingCancelled() {
        action()
    }
}
