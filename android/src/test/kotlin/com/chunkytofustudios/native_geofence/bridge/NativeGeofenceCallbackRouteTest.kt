package com.chunkytofustudios.native_geofence.bridge

import android.content.ContextWrapper
import androidx.work.Data
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
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
        var capturedInputData: Data? = null
        val outcomes = mutableListOf<NativeGeofenceCallbackEnqueueResult>()
        val testDispatcher = NativeGeofenceCallbackDeliveryDispatcher {
            _, _, deliverySpec, completion ->
            capturedInputData = callbackWorkerInputData(
                payloadReference = "payload-1",
                deliverySpec = deliverySpec,
            )
            completion(NativeGeofenceCallbackEnqueueResult.ACCEPTED)
        }
        NativeGeofenceCallbackDelivery.withDispatcherForTest(testDispatcher) {
            NativeGeofenceCallbackDelivery.enqueueFinalCallback(
                context = ContextWrapper(null),
                params = GeofenceCallbackParamsWire(
                    geofences = emptyList(),
                    event = GeofenceEvent.ENTER,
                    callbackHandle = 1L,
                ),
                source = "smart_geofence",
                completion = outcomes::add,
            )
        }
        val inputData = requireNotNull(capturedInputData)

        assertEquals(listOf(NativeGeofenceCallbackEnqueueResult.ACCEPTED), outcomes)
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
