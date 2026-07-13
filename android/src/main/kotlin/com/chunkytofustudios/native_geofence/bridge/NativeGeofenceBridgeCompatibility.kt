package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.chunkytofustudios.native_geofence.Constants

/** Keeps package-manager version checks out of the bridge orchestration. */
internal object NativeGeofenceBridgeCompatibility {
    fun processorClassName(context: Context): String? {
        val applicationInfo = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getApplicationInfo(
                    context.packageName,
                    PackageManager.ApplicationInfoFlags.of(
                        PackageManager.GET_META_DATA.toLong()
                    )
                )
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getApplicationInfo(
                    context.packageName,
                    PackageManager.GET_META_DATA
                )
            }
        } catch (_: RuntimeException) {
            return null
        }
        return applicationInfo.metaData
            ?.getString(Constants.NATIVE_EVENT_PROCESSOR_METADATA_KEY)
            ?.takeIf(String::isNotBlank)
    }
}
