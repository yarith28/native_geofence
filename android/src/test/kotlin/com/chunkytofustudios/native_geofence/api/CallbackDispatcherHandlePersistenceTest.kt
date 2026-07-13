package com.chunkytofustudios.native_geofence.api

import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class CallbackDispatcherHandlePersistenceTest {
    @Test
    fun `passes the dispatcher handle to durable storage`() {
        var persistedHandle: Long? = null

        persistCallbackDispatcherHandle(42L) { handle ->
            persistedHandle = handle
            true
        }

        assertEquals(42L, persistedHandle)
    }

    @Test
    fun `reports a typed error when durable storage fails`() {
        val error = assertFailsWith<FlutterError> {
            persistCallbackDispatcherHandle(42L) { false }
        }

        assertEquals(
            NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString(),
            error.code
        )
        assertEquals(
            "Failed to durably persist the callback dispatcher handle.",
            error.message
        )
    }
}
