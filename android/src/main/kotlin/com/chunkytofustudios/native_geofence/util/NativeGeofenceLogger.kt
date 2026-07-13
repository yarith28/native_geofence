package com.chunkytofustudios.native_geofence.util

import android.content.Context
import android.util.Log
import com.chunkytofustudios.native_geofence.Constants
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Single logging bridge for native_geofence.
 *
 * Messages always go to logcat. When file logging is enabled, the same messages
 * are appended to a bounded app-private file so the host app can fetch/export
 * them after background receivers or workers run without Dart.
 */
object NativeGeofenceLogger {
    private val timestampFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US)
    private val fileLock = Any()

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var fileLoggingEnabled: Boolean? = null

    fun initialize(context: Context) {
        val ctx = context.applicationContext
        appContext = ctx
        if (fileLoggingEnabled == null) {
            fileLoggingEnabled = isEnabled(ctx)
        }
    }

    fun configure(context: Context, enabled: Boolean, maxBytes: Int) {
        initialize(context)
        context.applicationContext
            .getSharedPreferences(Constants.SHARED_PREFERENCES_KEY, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(Constants.LOG_FILE_ENABLED_KEY, enabled)
            .putInt(Constants.LOG_FILE_MAX_BYTES_KEY, normalizeMaxBytes(maxBytes))
            .apply()
        fileLoggingEnabled = enabled
    }

    fun d(tag: String, message: String) {
        Log.d(tag, message)
        append(null, "debug", tag, message)
    }

    fun d(context: Context, tag: String, message: String) {
        Log.d(tag, message)
        append(context, "debug", tag, message)
    }

    fun i(tag: String, message: String) {
        Log.i(tag, message)
        append(null, "info", tag, message)
    }

    fun i(context: Context, tag: String, message: String) {
        Log.i(tag, message)
        append(context, "info", tag, message)
    }

    fun w(tag: String, message: String, throwable: Throwable? = null) {
        if (throwable == null) Log.w(tag, message) else Log.w(tag, message, throwable)
        append(null, "warning", tag, message, throwable)
    }

    fun w(context: Context, tag: String, message: String, throwable: Throwable? = null) {
        if (throwable == null) Log.w(tag, message) else Log.w(tag, message, throwable)
        append(context, "warning", tag, message, throwable)
    }

    fun e(tag: String, message: String, throwable: Throwable? = null) {
        if (throwable == null) Log.e(tag, message) else Log.e(tag, message, throwable)
        append(null, "error", tag, message, throwable)
    }

    fun e(context: Context, tag: String, message: String, throwable: Throwable? = null) {
        if (throwable == null) Log.e(tag, message) else Log.e(tag, message, throwable)
        append(context, "error", tag, message, throwable)
    }

    fun readAsync(context: Context, callback: (Result<String>) -> Unit) {
        initialize(context)
        val ctx = context.applicationContext
        NativeGeofenceIo.execute {
            try {
                callback(Result.success(readLogFile(logFile(ctx))))
            } catch (e: Throwable) {
                callback(Result.failure(e))
            }
        }
    }

    fun clearAsync(context: Context, callback: (Result<Unit>) -> Unit) {
        initialize(context)
        val ctx = context.applicationContext
        NativeGeofenceIo.execute {
            try {
                val file = logFile(ctx)
                if (file.exists()) file.writeText("", Charsets.UTF_8)
                callback(Result.success(Unit))
            } catch (e: Throwable) {
                callback(Result.failure(e))
            }
        }
    }

    private fun append(
        context: Context?,
        level: String,
        tag: String,
        message: String,
        throwable: Throwable? = null,
    ) {
        val ctx = context?.applicationContext ?: appContext ?: return
        if (fileLoggingEnabled == false) return
        NativeGeofenceIo.execute {
            if (!isEnabled(ctx)) {
                fileLoggingEnabled = false
                return@execute
            }
            fileLoggingEnabled = true
            synchronized(fileLock) {
                val file = logFile(ctx)
                file.parentFile?.mkdirs()
                file.appendText(formatLine(level, tag, message, throwable), Charsets.UTF_8)
                trimToMaxBytes(file, maxBytes(ctx))
            }
        }
    }

    private fun formatLine(
        level: String,
        tag: String,
        message: String,
        throwable: Throwable?,
    ): String {
        val timestamp = synchronized(timestampFormat) {
            timestampFormat.format(Date(System.currentTimeMillis()))
        }
        return buildString {
            append(timestamp)
            append(" [")
            append(level)
            append("] ")
            append(tag)
            append(": ")
            append(message)
            append('\n')
            if (throwable != null) {
                append(Log.getStackTraceString(throwable))
                if (isEmpty() || this[length - 1] != '\n') append('\n')
            }
        }
    }

    private fun isEnabled(context: Context): Boolean =
        prefs(context).getBoolean(Constants.LOG_FILE_ENABLED_KEY, false)

    private fun maxBytes(context: Context): Int =
        normalizeMaxBytes(
            prefs(context).getInt(
                Constants.LOG_FILE_MAX_BYTES_KEY,
                Constants.DEFAULT_LOG_FILE_MAX_BYTES
            )
        )

    private fun normalizeMaxBytes(maxBytes: Int): Int =
        maxBytes.coerceIn(Constants.MIN_LOG_FILE_MAX_BYTES, Constants.MAX_LOG_FILE_MAX_BYTES)

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(
            Constants.SHARED_PREFERENCES_KEY,
            Context.MODE_PRIVATE
        )

    private fun logFile(context: Context): File =
        File(context.applicationContext.noBackupFilesDir, Constants.LOG_FILE_NAME)

    private fun readLogFile(file: File): String {
        if (!file.exists()) return ""
        val content = StringBuilder()
        file.inputStream().bufferedReader(Charsets.UTF_8).use { reader ->
            val buffer = CharArray(8192)
            while (true) {
                val count = reader.read(buffer)
                if (count < 0) break
                content.append(buffer, 0, count)
            }
        }
        return content.toString()
    }

    private fun trimToMaxBytes(file: File, maxBytes: Int) {
        if (!file.exists() || file.length() <= maxBytes) return
        val bytes = file.readBytes()
        val keep = maxBytes.coerceAtMost(bytes.size)
        val start = bytes.size - keep
        var trimmed = bytes.copyOfRange(start, bytes.size)
        val newline = trimmed.indexOf('\n'.code.toByte())
        if (newline >= 0 && newline < trimmed.lastIndex) {
            trimmed = trimmed.copyOfRange(newline + 1, trimmed.size)
        }
        file.writeBytes(trimmed)
    }
}
