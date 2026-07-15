package com.chunkytofustudios.native_geofence.util

import android.content.Context
import android.content.SharedPreferences
import android.os.SystemClock
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceDeliveryTraceWire
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Privacy-safe, correlated evidence for callback delivery and bridge ownership. */
object NativeGeofenceDeliveryDiagnostics {
    private const val JOURNAL_KEY = "diagnostic_delivery_trace"
    private const val SEQUENCE_KEY = "diagnostic_delivery_trace_sequence"
    private const val DROPPED_KEY = "diagnostic_delivery_trace_dropped"
    private const val MAX_ENTRIES = 256

    @Serializable
    private data class StoredTrace(
        val sequence: Long,
        val occurredAtMillis: Long,
        val elapsedRealtimeMillis: Long? = null,
        val traceId: String? = null,
        val stage: String,
        val outcome: String,
        val event: String? = null,
        val geofenceCount: Int? = null,
        val attempt: Int? = null,
        val owner: String? = null,
        val reasonCode: String? = null,
        val durationMillis: Long? = null,
        val queueAgeMillis: Long? = null,
        val hasLocation: Boolean? = null,
        val locationAgeMillis: Long? = null,
        val accuracyMeters: Double? = null,
        val processorSource: String? = null,
        val processorClass: String? = null,
        val errorType: String? = null,
    ) {
        fun toWire() = NativeGeofenceDeliveryTraceWire(
            sequence = sequence,
            occurredAtMillis = occurredAtMillis,
            elapsedRealtimeMillis = elapsedRealtimeMillis,
            traceId = traceId,
            stage = stage,
            outcome = outcome,
            event = event,
            geofenceCount = geofenceCount?.toLong(),
            attempt = attempt?.toLong(),
            owner = owner,
            reasonCode = reasonCode,
            durationMillis = durationMillis,
            queueAgeMillis = queueAgeMillis,
            hasLocation = hasLocation,
            locationAgeMillis = locationAgeMillis,
            accuracyMeters = accuracyMeters,
            processorSource = processorSource,
            processorClass = processorClass,
            errorType = errorType,
        )
    }

    data class Snapshot(
        val entries: List<NativeGeofenceDeliveryTraceWire>,
        val droppedCount: Long,
    )

    @Synchronized
    fun record(
        context: Context,
        traceId: String?,
        stage: String,
        outcome: String,
        event: String? = null,
        geofenceCount: Int? = null,
        attempt: Int? = null,
        owner: String? = null,
        reasonCode: String? = null,
        durationMillis: Long? = null,
        queueAgeMillis: Long? = null,
        hasLocation: Boolean? = null,
        locationAgeMillis: Long? = null,
        accuracyMeters: Double? = null,
        processorSource: String? = null,
        processorClass: String? = null,
        errorType: String? = null,
        occurredAtMillis: Long = System.currentTimeMillis(),
        elapsedRealtimeMillis: Long = SystemClock.elapsedRealtime(),
    ) {
        val preferences = prefs(context.applicationContext)
        val previous = readStored(preferences)
        val nextSequence = preferences.getLong(SEQUENCE_KEY, 0L) + 1L
        val next = previous.entries + StoredTrace(
            sequence = nextSequence,
            occurredAtMillis = occurredAtMillis,
            elapsedRealtimeMillis = elapsedRealtimeMillis,
            traceId = bounded(traceId, 128),
            stage = code(stage),
            outcome = code(outcome),
            event = codeOrNull(event),
            geofenceCount = geofenceCount?.coerceAtLeast(0),
            attempt = attempt?.coerceAtLeast(0),
            owner = codeOrNull(owner),
            reasonCode = codeOrNull(reasonCode),
            durationMillis = durationMillis?.coerceAtLeast(0L),
            queueAgeMillis = queueAgeMillis?.coerceAtLeast(0L),
            hasLocation = hasLocation,
            locationAgeMillis = locationAgeMillis?.coerceAtLeast(0L),
            accuracyMeters = accuracyMeters?.takeIf { it.isFinite() && it >= 0.0 },
            processorSource = codeOrNull(processorSource),
            processorClass = bounded(processorClass, 256),
            errorType = bounded(errorType, 128),
        )
        val overflow = (next.size - MAX_ENTRIES).coerceAtLeast(0)
        val retained = next.takeLast(MAX_ENTRIES)
        val dropped = preferences.getLong(DROPPED_KEY, 0L) +
            previous.corruptEntryCount + overflow
        val committed = preferences.edit()
            .putString(JOURNAL_KEY, Json.encodeToString(retained))
            .putLong(SEQUENCE_KEY, nextSequence)
            .putLong(DROPPED_KEY, dropped)
            .commit()
        if (!committed) {
            NativeGeofenceLogger.w(
                context,
                "NativeGeofenceDeliveryDiagnostics",
                "Failed to persist callback delivery trace stage=${code(stage)}.",
            )
        }
    }

    @Synchronized
    fun snapshot(context: Context): Snapshot {
        val preferences = prefs(context.applicationContext)
        val stored = readStored(preferences)
        return Snapshot(
            entries = stored.entries.map(StoredTrace::toWire),
            droppedCount = preferences.getLong(DROPPED_KEY, 0L) +
                stored.corruptEntryCount,
        )
    }

    private data class StoredRead(
        val entries: List<StoredTrace>,
        val corruptEntryCount: Long,
    )

    private fun readStored(preferences: SharedPreferences): StoredRead {
        val encoded = preferences.getString(JOURNAL_KEY, null)
            ?: return StoredRead(emptyList(), 0L)
        return try {
            StoredRead(Json.decodeFromString<List<StoredTrace>>(encoded), 0L)
        } catch (_: RuntimeException) {
            StoredRead(emptyList(), 1L)
        }
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(Constants.SHARED_PREFERENCES_KEY, Context.MODE_PRIVATE)

    private fun code(value: String): String = codeOrNull(value) ?: "unknown"

    private fun codeOrNull(value: String?): String? = value
        ?.lowercase()
        ?.map { character ->
            if (character.isLetterOrDigit() || character in "._-") character else '_'
        }
        ?.joinToString(separator = "")
        ?.take(96)
        ?.ifBlank { null }

    private fun bounded(value: String?, maxLength: Int): String? =
        value?.take(maxLength)?.takeIf(String::isNotBlank)
}
