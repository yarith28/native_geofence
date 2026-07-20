package com.chunkytofustudios.native_geofence.bridge

import androidx.work.Data
import com.chunkytofustudios.native_geofence.Constants

/** Durable worker route for a callback payload. */
internal enum class NativeGeofenceCallbackRoute(val storageValue: String) {
    /** A raw platform observation must pass through the optional native processor first. */
    NATIVE_BRIDGE("native_bridge"),

    /** A higher-level processor has finalized the event; deliver it directly to Dart. */
    FINAL_DART_CALLBACK("final_dart_callback");

    val requiresNativeBridge: Boolean
        get() = this == NATIVE_BRIDGE

    companion object {
        fun fromStorageValue(value: String?): NativeGeofenceCallbackRoute =
            entries.firstOrNull { it.storageValue == value } ?: NATIVE_BRIDGE
    }
}

internal data class NativeGeofenceCallbackDeliverySpec(
    val route: NativeGeofenceCallbackRoute,
    val source: String?,
)

internal fun nativeBridgeCallbackDeliverySpec() = NativeGeofenceCallbackDeliverySpec(
    route = NativeGeofenceCallbackRoute.NATIVE_BRIDGE,
    source = null,
)

internal fun enqueueFinalCallbackDeliverySpec(
    source: String,
) = NativeGeofenceCallbackDeliverySpec(
    route = NativeGeofenceCallbackRoute.FINAL_DART_CALLBACK,
    source = source.takeIf(String::isNotBlank),
)

internal fun callbackWorkerInputData(
    payloadReference: String,
    deliverySpec: NativeGeofenceCallbackDeliverySpec,
): Data = Data.Builder()
    .putString(Constants.WORKER_PAYLOAD_REFERENCE_KEY, payloadReference)
    .putString(Constants.WORKER_DELIVERY_ROUTE_KEY, deliverySpec.route.storageValue)
    .putString(Constants.WORKER_DELIVERY_SOURCE_KEY, deliverySpec.source)
    .build()

internal fun callbackWorkerRoute(inputData: Data): NativeGeofenceCallbackRoute =
    NativeGeofenceCallbackRoute.fromStorageValue(
        inputData.getString(Constants.WORKER_DELIVERY_ROUTE_KEY),
    )

internal fun dispatchCallbackWorkerRoute(
    route: NativeGeofenceCallbackRoute,
    processNativeBridge: () -> Unit,
    processFinalCallback: () -> Unit,
) {
    if (route.requiresNativeBridge) {
        processNativeBridge()
    } else {
        processFinalCallback()
    }
}
