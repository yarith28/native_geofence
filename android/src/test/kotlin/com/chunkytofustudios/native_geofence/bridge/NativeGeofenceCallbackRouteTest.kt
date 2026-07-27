package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import android.content.ContextWrapper
import androidx.work.OneTimeWorkRequest
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.NativeGeofenceBackgroundWorker
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.util.CallbackEnqueueOperation
import com.chunkytofustudios.native_geofence.util.CallbackPayloadBackend
import com.chunkytofustudios.native_geofence.util.GeofenceCallbackPayloadStore
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
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
    fun `callback refresh transfer preserves route source and transfer mode`() {
        val inputData = callbackWorkerInputData(
            payloadReference = PAYLOAD_REFERENCE,
            deliverySpec = NativeGeofenceCallbackDeliverySpec(
                route = NativeGeofenceCallbackRoute.FINAL_DART_CALLBACK,
                source = "smart_geofence",
            ),
            callbackRefreshTransfer = true,
        )

        assertEquals(
            NativeGeofenceCallbackRoute.FINAL_DART_CALLBACK.storageValue,
            inputData.getString(Constants.WORKER_DELIVERY_ROUTE_KEY),
        )
        assertEquals(
            "smart_geofence",
            inputData.getString(Constants.WORKER_DELIVERY_SOURCE_KEY),
        )
        assertTrue(inputData.getBoolean(Constants.WORKER_CALLBACK_REFRESH_TRANSFER_KEY, false))
    }

    @Test
    fun `enqueue final callback stores final route and worker bypasses bridge`() {
        val backend = MemoryPayloadBackend()
        val payloadStore = GeofenceCallbackPayloadStore(
            backend = backend,
            referenceGenerator = { PAYLOAD_REFERENCE },
        )
        var capturedWorkRequest: OneTimeWorkRequest? = null
        val outcomes = mutableListOf<NativeGeofenceCallbackEnqueueResult>()
        val testDependencies = NativeGeofenceCallbackDeliveryDependencies(
            execute = { task -> task() },
            packageFingerprint = { "package-v1" },
            payloadStore = { payloadStore },
            enqueueWork = { _, workRequest ->
                capturedWorkRequest = workRequest
                CallbackEnqueueOperation { completion ->
                    completion(Result.success(Unit))
                }
            },
        )
        NativeGeofenceCallbackDelivery.withDependenciesForTest(testDependencies) {
            NativeGeofenceCallbackDelivery.enqueueFinalCallback(
                context = TestContext(),
                params = GeofenceCallbackParamsWire(
                    geofences = emptyList(),
                    event = GeofenceEvent.ENTER,
                    callbackHandle = 1L,
                ),
                source = "smart_geofence",
                completion = outcomes::add,
            )
        }
        val workRequest = requireNotNull(capturedWorkRequest)
        val inputData = workRequest.workSpec.input

        assertEquals(listOf(NativeGeofenceCallbackEnqueueResult.ACCEPTED), outcomes)
        assertTrue(backend.values.containsKey(PAYLOAD_REFERENCE))
        assertEquals(UUID.fromString(PAYLOAD_REFERENCE), workRequest.id)
        assertEquals(
            NativeGeofenceBackgroundWorker::class.java.name,
            workRequest.workSpec.workerClassName,
        )
        assertEquals(
            PAYLOAD_REFERENCE,
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
        val recoverySpec = CallbackPayloadRecoveryPlanner.makeSpec(
            payloadStore.recoverablePayloads().getOrThrow().single(),
        )
        assertNotNull(recoverySpec)
        assertEquals(UUID.fromString(PAYLOAD_REFERENCE), recoverySpec.workRequestId)
        assertEquals(
            NativeGeofenceCallbackRoute.FINAL_DART_CALLBACK,
            recoverySpec.deliverySpec.route,
        )
        assertEquals("smart_geofence", recoverySpec.deliverySpec.source)

        var nativeBridgeCalls = 0
        var finalCallbackCalls = 0
        NativeGeofenceCallbackWorkerRouter.fromInputData(inputData).dispatch(
            processNativeBridge = { nativeBridgeCalls++ },
            processFinalCallback = { finalCallbackCalls++ },
        )

        assertEquals(0, nativeBridgeCalls)
        assertEquals(1, finalCallbackCalls)
    }

    private class TestContext : ContextWrapper(null) {
        override fun getApplicationContext(): Context = this
    }

    private class MemoryPayloadBackend : CallbackPayloadBackend {
        val values = linkedMapOf<String, String>()

        override fun write(reference: String, value: String): Boolean {
            values[reference] = value
            return true
        }

        override fun read(reference: String): Result<String?> = Result.success(values[reference])

        override fun delete(reference: String): Boolean = values.remove(reference) != null

        override fun listReferences(): Result<List<String>> =
            Result.success(values.keys.toList())
    }

    private companion object {
        const val PAYLOAD_REFERENCE = "00000000-0000-0000-0000-000000000001"
    }
}
