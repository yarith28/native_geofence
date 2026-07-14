package com.chunkytofustudios.native_geofence.util

import android.content.Context
import androidx.core.content.pm.PackageInfoCompat
import java.security.MessageDigest

internal object AndroidPackageFingerprint {
    fun current(context: Context): String {
        val packageName = context.packageName
        val material = try {
            val packageInfo = AndroidPackageManagerCompat.getPackageInfo(
                context.packageManager,
                packageName,
            )
            val versionCode = PackageInfoCompat.getLongVersionCode(packageInfo)
            "$packageName:$versionCode:${packageInfo.lastUpdateTime}"
        } catch (_: RuntimeException) {
            packageName
        }
        return MessageDigest.getInstance("SHA-256")
            .digest(material.toByteArray(Charsets.UTF_8))
            .joinToString(separator = "") { byte -> "%02x".format(byte) }
    }
}
