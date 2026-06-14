package com.chunkytofustudios.native_geofence.util

import android.content.Context
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.NativeGeofenceBackgroundWorker
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.model.GeofenceCallbackParamsStorage
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class GeofenceCallbackWork {
    companion object {
        fun enqueue(context: Context, geofenceCallbackParams: GeofenceCallbackParamsWire) {
            val jsonData =
                Json.encodeToString(GeofenceCallbackParamsStorage.fromWire(geofenceCallbackParams))
            val workRequest = OneTimeWorkRequestBuilder<NativeGeofenceBackgroundWorker>()
                .setInputData(
                    Data.Builder()
                        .putString(Constants.WORKER_PAYLOAD_KEY, jsonData)
                        .build()
                )
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()

            val workManager = WorkManager.getInstance(context)
            val work = workManager.beginUniqueWork(
                Constants.GEOFENCE_CALLBACK_WORK_GROUP,
                // Process geofence callbacks sequentially.
                ExistingWorkPolicy.APPEND,
                workRequest
            )
            work.enqueue()
        }
    }
}
