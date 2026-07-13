package com.chunkytofustudios.native_geofence.receivers

import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NativeGeofenceRecoveryFailuresTest {
    @Test
    fun `identical typed failures preserve their public code`() {
        val code = NativeGeofenceErrorCode.MISSING_LOCATION_PERMISSION.raw.toString()
        val aggregate = aggregate(
            failure("a", "prepare_rearm", FlutterError(code, "first")),
            failure("b", "rearm", FlutterError(code, "second"))
        )

        assertEquals(code, aggregate.publicError.code)
        assertFalse(aggregate.retryable)
    }

    @Test
    fun `mixed typed and untyped failures use plugin internal`() {
        val pluginInternal = NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString()
        val invalid = NativeGeofenceErrorCode.INVALID_ARGUMENTS.raw.toString()

        val mixedCodes = aggregate(
            failure("a", "rearm", FlutterError(invalid, "bad")),
            failure("b", "rearm", FlutterError(pluginInternal, "transient"))
        )
        val mixedTypes = aggregate(
            failure("a", "rearm", FlutterError(pluginInternal, "typed")),
            failure("b", "clean_orphan", IllegalStateException("untyped"))
        )
        val untyped = aggregate(
            failure("a", "rearm", IllegalStateException("one")),
            failure("b", "clean_orphan", IllegalArgumentException("two"))
        )

        assertEquals(pluginInternal, mixedCodes.publicError.code)
        assertEquals(pluginInternal, mixedTypes.publicError.code)
        assertEquals(pluginInternal, untyped.publicError.code)
        assertFalse(mixedCodes.retryable)
        assertTrue(mixedTypes.retryable)
        assertTrue(untyped.retryable)
    }

    @Test
    fun `details are structured sanitized and bounded`() {
        val aggregate = NativeGeofenceRecoveryFailures.aggregate(
            reason = "boot\r\ninjected",
            failures = listOf(
                failure(
                    "office\nforged",
                    "clean_orphan\rforged",
                    FlutterError(
                        NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
                        "message\nforged" + "m".repeat(2_000),
                        "details\r\n" + "d".repeat(5_000)
                    )
                ),
                failure("home", "rearm", IllegalStateException("plain"))
            )
        )
        val message = aggregate.publicError.message.orEmpty()
        val details = aggregate.publicError.details as String

        assertTrue(message.length <= NativeGeofenceRecoveryFailures.MAX_MESSAGE_LENGTH)
        assertTrue(details.length <= NativeGeofenceRecoveryFailures.MAX_DETAILS_LENGTH)
        assertFalse(details.contains('\r'))
        assertTrue(details.contains("office forged"))
        assertTrue(details.contains("clean_orphan forged"))
        assertTrue(details.contains("home"))
        assertTrue(details.contains("rearm"))
        assertTrue(details.contains("code="))
        assertTrue(details.contains("class="))
    }

    private fun aggregate(vararg failures: GeofenceRecoveryFailure) =
        NativeGeofenceRecoveryFailures.aggregate("test", failures.toList())

    private fun failure(id: String, operation: String, error: Throwable) =
        GeofenceRecoveryFailure(id, operation, error)
}
