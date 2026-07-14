package com.chunkytofustudios.native_geofence.bridge

import android.content.Context
import com.chunkytofustudios.native_geofence.util.NativeGeofenceLogger

/** Optional process-wide native event bridge for host Android applications. */
object NativeGeofenceBridge {
    private val lock = Object()

    @Volatile
    private var processor: NativeGeofenceEventProcessor? = null

    @Volatile
    private var metadataLoaded = false

    /**
     * Installs a processor before geofence delivery. Passing null explicitly
     * disables both the programmatic processor and metadata discovery.
     */
    @JvmStatic
    fun setProcessor(processor: NativeGeofenceEventProcessor?) = synchronized(lock) {
        this.processor = processor
        metadataLoaded = true
    }

    internal fun resolve(context: Context): NativeGeofenceEventProcessor? {
        processor?.let { return it }
        return synchronized(lock) {
            processor?.let { return@synchronized it }
            if (metadataLoaded) return@synchronized null
            metadataLoaded = true
            processor = loadMetadataProcessor(context.applicationContext)
            processor
        }
    }

    private fun loadMetadataProcessor(context: Context): NativeGeofenceEventProcessor? {
        return try {
            val className = NativeGeofenceBridgeCompatibility.processorClassName(context)
                ?: return null
            Class.forName(className, false, context.classLoader)
                .asSubclass(NativeGeofenceEventProcessor::class.java)
                .getDeclaredConstructor()
                .newInstance()
        } catch (error: Throwable) {
            NativeGeofenceLogger.w(
                context,
                "NativeGeofenceBridge",
                "The configured native event processor could not be loaded; " +
                    "continuing with Dart delivery.",
                error
            )
            null
        }
    }
}
