package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import android.content.pm.PackageManager
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.util.AndroidPackageManagerCompat

/** Keeps the bridge processor manifest lookup out of bridge orchestration. */
internal object NativeGeofenceBridgeCompatibility {
    data class ProcessorMetadata(val className: String, val source: String)

    sealed interface LookupResult {
        data class Found(val metadata: ProcessorMetadata) : LookupResult
        data object Absent : LookupResult
        data class Failed(val error: Exception) : LookupResult
    }

    fun lookup(context: Context): LookupResult = lookupResult {
        val applicationInfo = AndroidPackageManagerCompat.getApplicationInfo(
            context.packageManager,
            context.packageName,
            PackageManager.GET_META_DATA,
        )
        val metadata = applicationInfo.metaData
        preferredProcessorMetadata(
            metadata?.getString(Constants.NATIVE_EVENT_PROCESSOR_METADATA_KEY),
            metadata?.getString(Constants.LEGACY_NATIVE_EVENT_PROCESSOR_METADATA_KEY),
        )
    }

    fun processorClassName(context: Context): String? = when (val result = lookup(context)) {
        is LookupResult.Found -> result.metadata.className
        LookupResult.Absent,
        is LookupResult.Failed -> null
    }

    internal fun preferredProcessorClassName(current: String?, legacy: String?): String? =
        current ?: legacy

    internal fun preferredProcessorMetadata(
        current: String?,
        legacy: String?,
    ): ProcessorMetadata? = when {
        !current.isNullOrBlank() -> ProcessorMetadata(current, "manifest_current")
        !legacy.isNullOrBlank() -> ProcessorMetadata(legacy, "manifest_legacy")
        else -> null
    }

    internal fun lookupResult(load: () -> ProcessorMetadata?): LookupResult = try {
        load()?.let(LookupResult::Found) ?: LookupResult.Absent
    } catch (error: Exception) {
        LookupResult.Failed(error)
    }

    internal fun processorClassNameOrNull(load: () -> String?): String? = try {
        load()?.takeIf(String::isNotBlank)
    } catch (_: Exception) {
        null
    }
}
