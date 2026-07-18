package com.chunkytofustudios.native_geofence.util

import android.content.Context
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceLifecycleFactWire
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal enum class NativeGeofenceDiagnosticStage(val storageName: String) {
    REGISTRATION("registration"),
    REMOVAL("removal"),
    BROADCAST("broadcast"),
    ENQUEUE("enqueue"),
    WORKER("worker"),
    RECOVERY("recovery"),
    FOREGROUND("foreground")
}

@Serializable
internal data class StoredNativeGeofenceFact(
    val occurredAtMillis: Long,
    val succeeded: Boolean,
    val outcome: String,
    val geofenceCount: Int? = null
) {
    fun toWire() = NativeGeofenceLifecycleFactWire(
        occurredAtMillis = occurredAtMillis,
        succeeded = succeeded,
        outcome = outcome,
        geofenceCount = geofenceCount?.toLong()
    )
}

internal interface DiagnosticFactBackend {
    fun put(stage: NativeGeofenceDiagnosticStage, encoded: String): Boolean
    fun get(stage: NativeGeofenceDiagnosticStage): String?
}

internal class NativeGeofenceDiagnosticFactStore(
    private val backend: DiagnosticFactBackend,
    private val nowMillis: () -> Long = System::currentTimeMillis
) {
    fun record(
        stage: NativeGeofenceDiagnosticStage,
        succeeded: Boolean,
        outcome: String,
        geofenceCount: Int? = null
    ): Boolean {
        val fact = StoredNativeGeofenceFact(
            occurredAtMillis = nowMillis(),
            succeeded = succeeded,
            outcome = sanitizeOutcome(outcome),
            geofenceCount = geofenceCount?.coerceAtLeast(0)
        )
        return backend.put(stage, Json.encodeToString(fact))
    }

    fun read(stage: NativeGeofenceDiagnosticStage): StoredNativeGeofenceFact? {
        val encoded = backend.get(stage) ?: return null
        return try {
            Json.decodeFromString<StoredNativeGeofenceFact>(encoded)
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun sanitizeOutcome(value: String): String {
        val normalized = value.lowercase()
            .map { character ->
                if (character.isLetterOrDigit() || character in "._-") character else '_'
            }
            .joinToString(separator = "")
            .take(MAX_OUTCOME_LENGTH)
        return normalized.ifBlank { "unknown" }
    }

    private companion object {
        const val MAX_OUTCOME_LENGTH = 80
    }
}

internal object NativeGeofenceDiagnostics {
    fun record(
        context: Context,
        stage: NativeGeofenceDiagnosticStage,
        succeeded: Boolean,
        outcome: String,
        geofenceCount: Int? = null
    ) {
        if (!store(context).record(stage, succeeded, outcome, geofenceCount)) {
            NativeGeofenceLogger.w(
                context,
                "NativeGeofenceDiagnostics",
                "Failed to persist a privacy-safe lifecycle fact for ${stage.storageName}."
            )
        }
    }

    fun fact(
        context: Context,
        stage: NativeGeofenceDiagnosticStage
    ): NativeGeofenceLifecycleFactWire? = store(context).read(stage)?.toWire()

    private fun store(context: Context) = NativeGeofenceDiagnosticFactStore(
        NoBackupDiagnosticFactBackend(
            NativeGeofencePreferences.get(context)
        )
    )
}

private class NoBackupDiagnosticFactBackend(
    private val preferences: NoBackupNativeGeofencePreferences
) : DiagnosticFactBackend {
    override fun put(stage: NativeGeofenceDiagnosticStage, encoded: String): Boolean =
        preferences.edit()
            .putString(Constants.DIAGNOSTIC_FACT_KEY_PREFIX + stage.storageName, encoded)
            .commit()

    override fun get(stage: NativeGeofenceDiagnosticStage): String? =
        preferences.getString(Constants.DIAGNOSTIC_FACT_KEY_PREFIX + stage.storageName, null)
}
