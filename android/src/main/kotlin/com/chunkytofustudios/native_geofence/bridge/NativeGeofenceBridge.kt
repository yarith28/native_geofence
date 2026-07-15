package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger

/** Optional process-wide native event bridge for host Android applications. */
object NativeGeofenceBridge {
    private const val TAG = "NativeGeofenceBridge"
    private val lock = Object()

    internal data class Resolution(
        val processor: NativeGeofenceEventProcessor?,
        val outcome: String,
        val source: String,
        val className: String? = null,
        val errorType: String? = null,
    )

    @Volatile
    private var resolution: Resolution? = null

    /**
     * Installs a processor before geofence delivery. Passing null explicitly
     * disables both the programmatic processor and metadata discovery.
     */
    @JvmStatic
    fun setProcessor(processor: NativeGeofenceEventProcessor?) = synchronized(lock) {
        resolution = Resolution(
            processor = processor,
            outcome = if (processor == null) "disabled" else "loaded",
            source = if (processor == null) "programmatic_disabled" else "programmatic",
            className = processor?.javaClass?.name,
        )
    }

    internal fun resolve(context: Context): NativeGeofenceEventProcessor? {
        return resolveDetailed(context).processor
    }

    internal fun resolveDetailed(context: Context): Resolution {
        resolution?.let { return it }
        return synchronized(lock) {
            resolution?.let { return@synchronized it }
            loadMetadataProcessor(context.applicationContext).also { resolution = it }
        }
    }

    private fun loadMetadataProcessor(context: Context): Resolution {
        val metadata = when (val lookup = NativeGeofenceBridgeCompatibility.lookup(context)) {
            NativeGeofenceBridgeCompatibility.LookupResult.Absent -> {
                NativeGeofenceLogger.d(
                    context,
                    TAG,
                    "No native event processor metadata found; continuing with Dart delivery.",
                )
                return Resolution(null, "absent", "manifest")
            }
            is NativeGeofenceBridgeCompatibility.LookupResult.Failed -> {
                NativeGeofenceLogger.w(
                    context,
                    TAG,
                    "Native event processor metadata lookup failed; continuing with Dart delivery.",
                    lookup.error,
                )
                return Resolution(
                    null,
                    "lookup_failed",
                    "manifest",
                    errorType = lookup.error.javaClass.name,
                )
            }
            is NativeGeofenceBridgeCompatibility.LookupResult.Found -> lookup.metadata
        }
        return try {
            val className = metadata.className
            val loaded = Class.forName(className, false, context.classLoader)
                .asSubclass(NativeGeofenceEventProcessor::class.java)
                .getDeclaredConstructor()
                .newInstance()
            NativeGeofenceLogger.i(
                context,
                TAG,
                "Loaded native event processor class=$className.",
            )
            Resolution(loaded, "loaded", metadata.source, className)
        } catch (error: Throwable) {
            NativeGeofenceLogger.w(
                context,
                TAG,
                "The configured native event processor could not be loaded; " +
                    "continuing with Dart delivery.",
                error
            )
            Resolution(
                null,
                "class_load_failed",
                metadata.source,
                metadata.className,
                error.javaClass.name,
            )
        }
    }
}
