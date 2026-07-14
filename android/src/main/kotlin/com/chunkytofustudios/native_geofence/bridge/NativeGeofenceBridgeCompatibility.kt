package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import android.content.pm.PackageManager
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.util.AndroidPackageManagerCompat

/** Keeps the bridge processor manifest lookup out of bridge orchestration. */
internal object NativeGeofenceBridgeCompatibility {
    fun processorClassName(context: Context): String? = processorClassNameOrNull {
        val applicationInfo = AndroidPackageManagerCompat.getApplicationInfo(
            context.packageManager,
            context.packageName,
            PackageManager.GET_META_DATA,
        )
        applicationInfo.metaData
            ?.getString(Constants.NATIVE_EVENT_PROCESSOR_METADATA_KEY)
    }

    internal fun processorClassNameOrNull(load: () -> String?): String? = try {
        load()?.takeIf(String::isNotBlank)
    } catch (_: Exception) {
        null
    }
}
