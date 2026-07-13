package com.chunkytofustudios.native_geofence.util

import android.content.Context
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceCallbackParamsWire
import com.chunkytofustudios.native_geofence.model.GeofenceCallbackParamsStorage
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal interface CallbackPayloadBackend {
    fun write(reference: String, value: String): Boolean
    fun read(reference: String): Result<String?>
    fun delete(reference: String): Boolean
}

@Serializable
internal data class GeofenceCallbackPayloadEnvelope(
    val payload: GeofenceCallbackParamsStorage,
    val packageFingerprint: String,
    val enqueuedAtMillis: Long
) {
    fun toWire(): GeofenceCallbackParamsWire = payload.toWire()
}

internal sealed interface CallbackPayloadReadResult {
    data class Found(val envelope: GeofenceCallbackPayloadEnvelope) :
        CallbackPayloadReadResult

    data object Missing : CallbackPayloadReadResult

    data object Corrupt : CallbackPayloadReadResult
}

internal sealed interface LegacyCallbackPayloadReadResult {
    data class Found(val params: GeofenceCallbackParamsWire) :
        LegacyCallbackPayloadReadResult

    data object Missing : LegacyCallbackPayloadReadResult

    data object Corrupt : LegacyCallbackPayloadReadResult
}

internal sealed interface CallbackPayloadInput {
    data class CurrentReference(val reference: String) : CallbackPayloadInput

    data class LegacyInline(val encoded: String) : CallbackPayloadInput

    data class LegacyReference(val reference: String) : CallbackPayloadInput

    data object Missing : CallbackPayloadInput
}

internal object CallbackPayloadMigration {
    fun selectInput(
        currentReference: String?,
        legacyInline: String?,
        legacyReference: String?
    ): CallbackPayloadInput = when {
        currentReference != null -> CallbackPayloadInput.CurrentReference(currentReference)
        legacyInline != null -> CallbackPayloadInput.LegacyInline(legacyInline)
        legacyReference != null -> CallbackPayloadInput.LegacyReference(legacyReference)
        else -> CallbackPayloadInput.Missing
    }

    fun decodeLegacyInline(encoded: String): LegacyCallbackPayloadReadResult =
        decodeLegacyPayload(encoded)

    fun withStableEventId(
        params: GeofenceCallbackParamsWire,
        workerId: String
    ): GeofenceCallbackParamsWire = if (params.eventId.isNullOrBlank()) {
        params.copy(eventId = workerId)
    } else {
        params
    }
}

internal enum class CallbackPayloadSettlement {
    RETAINED,
    DELETED,
    DELETE_FAILED,
    ALREADY_SETTLED
}

internal class CallbackPayloadLease(
    private val delete: () -> Boolean
) {
    private val settled = AtomicBoolean(false)

    fun settle(
        decision: CallbackDeliveryDecision,
        dispatch: ((() -> Unit) -> Unit),
        completion: (CallbackPayloadSettlement) -> Unit
    ) {
        val completionCalled = AtomicBoolean(false)
        val completeOnce: (CallbackPayloadSettlement) -> Unit = { outcome ->
            if (completionCalled.compareAndSet(false, true)) {
                completion(outcome)
            }
        }
        if (!decision.cleanupPayload) {
            completeOnce(CallbackPayloadSettlement.RETAINED)
            return
        }
        if (!settled.compareAndSet(false, true)) {
            completeOnce(CallbackPayloadSettlement.ALREADY_SETTLED)
            return
        }
        val cleanup = {
            val outcome = try {
                if (delete()) {
                    CallbackPayloadSettlement.DELETED
                } else {
                    CallbackPayloadSettlement.DELETE_FAILED
                }
            } catch (_: Exception) {
                CallbackPayloadSettlement.DELETE_FAILED
            }
            completeOnce(outcome)
        }
        try {
            dispatch(cleanup)
        } catch (_: Exception) {
            completeOnce(CallbackPayloadSettlement.DELETE_FAILED)
        }
    }
}

internal class GeofenceCallbackPayloadStore(
    private val backend: CallbackPayloadBackend,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val referenceGenerator: () -> String = { UUID.randomUUID().toString() }
) {
    fun store(params: GeofenceCallbackParamsWire, packageFingerprint: String): String? {
        if (params.eventId.isNullOrBlank()) {
            return null
        }
        val reference = referenceGenerator()
        if (!isValidReference(reference)) {
            return null
        }
        val encoded = try {
            Json.encodeToString(
                GeofenceCallbackPayloadEnvelope(
                    payload = GeofenceCallbackParamsStorage.fromWire(params),
                    packageFingerprint = packageFingerprint,
                    enqueuedAtMillis = nowMillis()
                )
            )
        } catch (_: Exception) {
            return null
        }
        return if (backend.write(reference, encoded)) reference else null
    }

    fun read(reference: String): CallbackPayloadReadResult {
        if (!isValidReference(reference)) {
            return CallbackPayloadReadResult.Corrupt
        }
        val encoded = backend.read(reference).getOrElse {
            return CallbackPayloadReadResult.Corrupt
        } ?: return CallbackPayloadReadResult.Missing
        return try {
            val envelope = Json.decodeFromString<GeofenceCallbackPayloadEnvelope>(encoded)
            if (envelope.payload.toWire().eventId.isNullOrBlank()) {
                CallbackPayloadReadResult.Corrupt
            } else {
                CallbackPayloadReadResult.Found(envelope)
            }
        } catch (_: RuntimeException) {
            CallbackPayloadReadResult.Corrupt
        }
    }

    fun delete(reference: String): Boolean =
        isValidReference(reference) && backend.delete(reference)

    companion object {
        fun forContext(context: Context): GeofenceCallbackPayloadStore =
            GeofenceCallbackPayloadStore(
                FileCallbackPayloadBackend(
                    File(
                        context.applicationContext.noBackupFilesDir,
                        Constants.CALLBACK_PAYLOAD_DIRECTORY
                    )
                )
            )

        internal fun isValidReference(reference: String): Boolean =
            REFERENCE_PATTERN.matches(reference)

        private val REFERENCE_PATTERN =
            Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    }
}

internal class LegacyGeofenceCallbackPayloadStore(
    private val backend: CallbackPayloadBackend
) {
    fun read(reference: String): LegacyCallbackPayloadReadResult {
        val normalized = normalizeReference(reference)
            ?: return LegacyCallbackPayloadReadResult.Corrupt
        val encoded = backend.read(normalized).getOrElse {
            return LegacyCallbackPayloadReadResult.Corrupt
        } ?: return LegacyCallbackPayloadReadResult.Missing
        return decodeLegacyPayload(encoded)
    }

    fun delete(reference: String): Boolean {
        val normalized = normalizeReference(reference) ?: return false
        return backend.delete(normalized)
    }

    companion object {
        fun forContext(context: Context): LegacyGeofenceCallbackPayloadStore =
            LegacyGeofenceCallbackPayloadStore(
                FileCallbackPayloadBackend(
                    File(
                        context.applicationContext.noBackupFilesDir,
                        Constants.LEGACY_CALLBACK_PAYLOAD_DIRECTORY
                    )
                )
            )

        internal fun normalizeReference(reference: String): String? = try {
            UUID.fromString(reference).toString()
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}

private val legacyPayloadJson = Json { ignoreUnknownKeys = true }

private fun decodeLegacyPayload(encoded: String): LegacyCallbackPayloadReadResult = try {
    LegacyCallbackPayloadReadResult.Found(
        legacyPayloadJson.decodeFromString<GeofenceCallbackParamsStorage>(encoded).toWire()
    )
} catch (_: RuntimeException) {
    LegacyCallbackPayloadReadResult.Corrupt
}

private class FileCallbackPayloadBackend(
    private val directory: File,
    private val nowMillis: () -> Long = System::currentTimeMillis
) : CallbackPayloadBackend {
    override fun write(reference: String, value: String): Boolean = try {
        check(GeofenceCallbackPayloadStore.isValidReference(reference))
        directory.mkdirs()
        pruneAbandonedPayloads()
        val target = file(reference)
        if (target.exists()) {
            false
        } else {
            val temporary = File(directory, "$reference.tmp")
            FileOutputStream(temporary).use { stream ->
                stream.write(value.toByteArray(Charsets.UTF_8))
                stream.fd.sync()
            }
            if (temporary.renameTo(target)) {
                true
            } else {
                temporary.delete()
                false
            }
        }
    } catch (_: Exception) {
        false
    }

    override fun read(reference: String): Result<String?> = runCatching {
        check(GeofenceCallbackPayloadStore.isValidReference(reference))
        val target = file(reference)
        if (target.exists()) target.readText(Charsets.UTF_8) else null
    }

    override fun delete(reference: String): Boolean = try {
        check(GeofenceCallbackPayloadStore.isValidReference(reference))
        val target = file(reference)
        !target.exists() || target.delete()
    } catch (_: Exception) {
        false
    }

    private fun file(reference: String) = File(directory, "$reference.json")

    private fun pruneAbandonedPayloads() {
        val cutoff = nowMillis() - MAX_PAYLOAD_AGE_MILLIS
        directory.listFiles()?.forEach { file ->
            if (file.lastModified() < cutoff) {
                file.delete()
            }
        }
    }

    private companion object {
        val MAX_PAYLOAD_AGE_MILLIS = TimeUnit.DAYS.toMillis(7)
    }
}
