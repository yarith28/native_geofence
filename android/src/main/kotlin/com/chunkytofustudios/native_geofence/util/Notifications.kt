package com.chunkytofustudios.native_geofence.util

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat

class Notifications {
    companion object {
        fun createBackgroundWorkerNotification(context: Context): Notification {
            // Background Worker notification is only needed for Android 30 and below (30% of users
            // as of Jan 2025), so we are re-using the Foreground Service notification.
            return createForegroundServiceNotification(context)
        }

        fun createForegroundServiceNotification(context: Context): Notification {
            val channelId = "native_geofence_plugin_channel"
            val text = NotificationResources.resolve { name ->
                stringResource(context, name)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    channelId,
                    text.channelName,
                    // This has to be at least IMPORTANCE_LOW.
                    // Source: https://developer.android.com/develop/background-work/services/foreground-services#start
                    NotificationManager.IMPORTANCE_LOW
                )
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .createNotificationChannel(channel)
            }

            @SuppressLint("DiscouragedApi") // Can't use R syntax in Flutter plugin.
            val launcherIconId =
                context.resources.getIdentifier("ic_launcher", "mipmap", context.packageName)
            val smallIconId = if (launcherIconId != 0) {
                launcherIconId
            } else {
                android.R.drawable.ic_dialog_info
            }

            return NotificationCompat.Builder(context, channelId)
                .setContentTitle(text.title)
                .setContentText(text.text)
                .setSmallIcon(smallIconId)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()
        }

        @SuppressLint("DiscouragedApi")
        private fun stringResource(context: Context, name: String): String? {
            val id = context.resources.getIdentifier(name, "string", context.packageName)
            return if (id == 0) null else runCatching { context.getString(id) }.getOrNull()
        }
    }
}
