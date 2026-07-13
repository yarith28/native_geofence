package com.chunkytofustudios.native_geofence.util

import com.chunkytofustudios.native_geofence.generated.GeofenceWire
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Serializes cleanup of triggered IDs that no longer have a usable callback.
 * Durable evidence is cleared only after Play services confirms removal.
 */
internal class OrphanedGeofenceCleanupCoordinator(
    private val mutationRunner: GeofenceMutationRunner,
    private val lookup: (String) -> GeofenceWire?,
    private val markForPlatformCleanup: (String) -> Boolean,
    private val removeFromPlatform: (String, (Result<Unit>) -> Unit) -> Unit,
    private val clearDurableState: (String) -> Boolean
) {
    fun cleanup(id: String, callback: (Result<Unit>) -> Unit) {
        mutationRunner.run(callback) { complete ->
            val repaired = lookup(id)
            if (repaired != null && repaired.callbackHandle != 0L) {
                complete(Result.success(Unit))
                return@run
            }

            if (!markForPlatformCleanup(id)) {
                complete(
                    Result.failure(
                        IllegalStateException(
                            "Failed to retain durable cleanup evidence for an orphaned geofence."
                        )
                    )
                )
                return@run
            }

            val platformCompletion = AtomicBoolean(false)
            val finishPlatformRemoval: (Result<Unit>) -> Unit = { result ->
                if (platformCompletion.compareAndSet(false, true)) {
                    result.fold(
                        onSuccess = {
                            if (clearDurableState(id)) {
                                complete(Result.success(Unit))
                            } else {
                                complete(
                                    Result.failure(
                                        IllegalStateException(
                                            "Play services removed an orphaned geofence, but " +
                                                "durable cleanup evidence could not be cleared."
                                        )
                                    )
                                )
                            }
                        },
                        onFailure = { complete(Result.failure(it)) }
                    )
                }
            }

            try {
                removeFromPlatform(id, finishPlatformRemoval)
            } catch (error: Throwable) {
                if (platformCompletion.compareAndSet(false, true)) {
                    complete(Result.failure(error))
                }
            }
        }
    }
}
