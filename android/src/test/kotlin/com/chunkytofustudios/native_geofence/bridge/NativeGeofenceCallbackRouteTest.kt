package com.chunkytofustudios.native_geofence.bridge

import com.chunkytofustudios.native_geofence.Constants
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NativeGeofenceCallbackRouteTest {
    @Test
    fun `missing and unknown routes retain native bridge compatibility`() {
        assertEquals(
            NativeGeofenceCallbackRoute.NATIVE_BRIDGE,
            NativeGeofenceCallbackRoute.fromStorageValue(null),
        )
        assertEquals(
            NativeGeofenceCallbackRoute.NATIVE_BRIDGE,
            NativeGeofenceCallbackRoute.fromStorageValue("future_route"),
        )
        assertTrue(NativeGeofenceCallbackRoute.NATIVE_BRIDGE.requiresNativeBridge)
    }

    @Test
    fun `final callback route bypasses native bridge`() {
        val route = NativeGeofenceCallbackRoute.fromStorageValue(
            NativeGeofenceCallbackRoute.FINAL_DART_CALLBACK.storageValue,
        )

        assertEquals(NativeGeofenceCallbackRoute.FINAL_DART_CALLBACK, route)
        assertFalse(route.requiresNativeBridge)
    }

    @Test
    fun `enqueue final callback stores final route and worker bypasses bridge`() {
        val inputData = callbackWorkerInputData(
            payloadReference = "payload-1",
            deliverySpec = enqueueFinalCallbackDeliverySpec("smart_geofence"),
        )

        assertEquals(
            "payload-1",
            inputData.getString(Constants.WORKER_PAYLOAD_REFERENCE_KEY),
        )
        assertEquals(
            NativeGeofenceCallbackRoute.FINAL_DART_CALLBACK.storageValue,
            inputData.getString(Constants.WORKER_DELIVERY_ROUTE_KEY),
        )
        assertEquals(
            "smart_geofence",
            inputData.getString(Constants.WORKER_DELIVERY_SOURCE_KEY),
        )

        var nativeBridgeCalls = 0
        var finalCallbackCalls = 0
        dispatchCallbackWorkerRoute(
            route = callbackWorkerRoute(inputData),
            processNativeBridge = { nativeBridgeCalls++ },
            processFinalCallback = { finalCallbackCalls++ },
        )

        assertEquals(0, nativeBridgeCalls)
        assertEquals(1, finalCallbackCalls)
    }
}
