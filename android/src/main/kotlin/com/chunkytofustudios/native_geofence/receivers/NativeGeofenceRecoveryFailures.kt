package com.chunkytofustudios.native_geofence.receivers

import com.chunkytofustudios.native_geofence.generated.FlutterError
import com.chunkytofustudios.native_geofence.generated.NativeGeofenceErrorCode

internal data class GeofenceRecoveryFailure(
    val id: String,
    val operation: String,
    val error: Throwable
)

internal class GeofenceRecoveryAggregateException(
    val publicError: FlutterError,
    val retryable: Boolean
) : RuntimeException(publicError.message, publicError)

internal object NativeGeofenceRecoveryFailures {
    const val MAX_MESSAGE_LENGTH = 1_000
    const val MAX_DETAILS_LENGTH = 4_000

    fun aggregate(
        reason: String,
        failures: List<GeofenceRecoveryFailure>
    ): GeofenceRecoveryAggregateException {
        require(failures.isNotEmpty())

        val typed = failures.mapNotNull { it.error as? FlutterError }
        val sharedCode = typed.map { it.code }.distinct().singleOrNull()
            ?.takeIf { typed.size == failures.size }
        val publicCode = sharedCode
            ?: NativeGeofenceErrorCode.PLUGIN_INTERNAL.raw.toString()
        val summary = failures.joinToString(separator = ", ") { failure ->
            "${sanitize(failure.operation).take(40)}:${sanitize(failure.id).take(80)}"
        }
        val message = (
            "Android geofence recovery failed for ${failures.size} operation(s): $summary"
            ).take(MAX_MESSAGE_LENGTH)

        val header = "reason=${sanitize(reason).take(160)} failures=${failures.size}"
        val lines = failures.mapIndexed { index, failure ->
            val flutterError = failure.error as? FlutterError
            val errorCode = flutterError?.code ?: "untyped"
            val errorClass = failure.error::class.java.name
            "failure[$index] " +
                "id=${sanitize(failure.id).take(160)} " +
                "operation=${sanitize(failure.operation).take(80)} " +
                "code=${sanitize(errorCode).take(80)} " +
                "class=${sanitize(errorClass).take(160)} " +
                "message=${sanitize(failure.error.message.orEmpty()).take(500)} " +
                "details=${sanitize(flutterError?.details?.toString().orEmpty()).take(1_000)}"
        }
        val details = boundedDetails(header, lines)
        val publicError = FlutterError(publicCode, message, details)
        return GeofenceRecoveryAggregateException(
            publicError = publicError,
            retryable = failures.all { NativeGeofenceRecoveryPolicy.isRetryable(it.error) }
        )
    }

    private fun boundedDetails(header: String, lines: List<String>): String {
        val safeHeader = header.take(MAX_DETAILS_LENGTH)
        if (lines.isEmpty() || safeHeader.length == MAX_DETAILS_LENGTH) {
            return safeHeader
        }
        val separatorBudget = lines.size
        val contentBudget = (
            MAX_DETAILS_LENGTH - safeHeader.length - separatorBudget
            ).coerceAtLeast(0)
        val baseBudget = if (lines.isEmpty()) 0 else contentBudget / lines.size
        var remainder = if (lines.isEmpty()) 0 else contentBudget % lines.size
        val boundedLines = lines.map { line ->
            val budget = baseBudget + if (remainder > 0) {
                remainder -= 1
                1
            } else {
                0
            }
            line.take(budget)
        }
        return (listOf(safeHeader) + boundedLines).joinToString("\n").take(MAX_DETAILS_LENGTH)
    }

    private fun sanitize(value: String): String = value.replace('\r', ' ').replace('\n', ' ')
}
