package com.chunkytofustudios.native_geofence.util

import android.content.Context
import androidx.core.content.ContextCompat
import androidx.work.BackoffPolicy
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.NativeGeofenceBackgroundWorker
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.model.GeofenceCallbackParamsStorage
import java.util.concurrent.TimeUnit
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class GeofenceCallbackWork {
    companion object {
        private const val TAG = "GeofenceCallbackWork"

        fun enqueue(
            context: Context,
            geofenceCallbackParams: GeofenceCallbackParamsWire,
            source: String = Constants.EVENT_SOURCE_EXTERNAL_INJECTION,
            onFinished: ((Boolean) -> Unit)? = null
        ) {
            val geofenceIdList = geofenceCallbackParams.geofences.map { it.id }
            val geofenceIds = geofenceIdList.joinToString(",")
            NativeGeofenceDiagnostics.recordCallbackEnqueueAttempt(
                context,
                geofenceCallbackParams.event,
                geofenceIdList
            )
            NativeGeofenceLogger.i(
                context,
                TAG,
                "Queueing geofence callback work: source=$source, " +
                    "event=${geofenceCallbackParams.event}, ids=$geofenceIds, " +
                    "callbackHandle=${geofenceCallbackParams.callbackHandle}, " +
                    "hasLocation=${geofenceCallbackParams.location != null}."
            )

            try {
                val jsonData =
                    Json.encodeToString(GeofenceCallbackParamsStorage.fromWire(geofenceCallbackParams))
                val workRequest = OneTimeWorkRequestBuilder<NativeGeofenceBackgroundWorker>()
                    .setInputData(
                        Data.Builder()
                            .putString(Constants.WORKER_PAYLOAD_KEY, jsonData)
                            .build()
                    )
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .build()

                val workManager = WorkManager.getInstance(context)
                val work = workManager.beginUniqueWork(
                    Constants.GEOFENCE_CALLBACK_WORK_GROUP,
                    // Process geofence callbacks sequentially without letting a failed
                    // historical chain poison future geofence events.
                    ExistingWorkPolicy.APPEND_OR_REPLACE,
                    workRequest
                )
                val enqueueResult = work.enqueue().result
                enqueueResult.addListener(
                    {
                        try {
                            enqueueResult.get()
                            NativeGeofenceLogger.d(
                                context,
                                TAG,
                                "Enqueued geofence callback work: source=$source, " +
                                    "event=${geofenceCallbackParams.event}, ids=$geofenceIds."
                            )
                            onFinished?.invoke(true)
                        } catch (e: Exception) {
                            NativeGeofenceDiagnostics.recordCallbackEnqueueFailure(
                                context,
                                geofenceCallbackParams.event,
                                geofenceIdList,
                                e.toString()
                            )
                            NativeGeofenceLogger.e(
                                context,
                                TAG,
                                "Failed to enqueue geofence callback work: source=$source, " +
                                    "event=${geofenceCallbackParams.event}, ids=$geofenceIds.",
                                e
                            )
                            onFinished?.invoke(false)
                        }
                    },
                    ContextCompat.getMainExecutor(context)
                )
            } catch (e: Exception) {
                NativeGeofenceDiagnostics.recordCallbackEnqueueFailure(
                    context,
                    geofenceCallbackParams.event,
                    geofenceIdList,
                    e.toString()
                )
                NativeGeofenceLogger.e(
                    context,
                    TAG,
                    "Failed while queueing geofence callback work: source=$source, " +
                        "event=${geofenceCallbackParams.event}, ids=$geofenceIds.",
                    e
                )
                onFinished?.invoke(false)
            }
        }
    }
}
