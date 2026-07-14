package com.chunkytofustudios.native_geofence.util

import android.content.ComponentName
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build

/** Keeps the pre-API-33 flag overloads isolated from feature code. */
internal object AndroidPackageManagerCompat {
    fun getApplicationInfo(
        packageManager: PackageManager,
        packageName: String,
        flags: Int,
    ): ApplicationInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getApplicationInfo(
                packageName,
                PackageManager.ApplicationInfoFlags.of(flags.toLong()),
            )
        } else {
            getApplicationInfoLegacy(packageManager, packageName, flags)
        }

    fun getPackageInfo(
        packageManager: PackageManager,
        packageName: String,
        flags: Int = 0,
    ): PackageInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.PackageInfoFlags.of(flags.toLong()),
            )
        } else {
            getPackageInfoLegacy(packageManager, packageName, flags)
        }

    fun getReceiverInfo(
        packageManager: PackageManager,
        componentName: ComponentName,
        flags: Int = 0,
    ): ActivityInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getReceiverInfo(
                componentName,
                PackageManager.ComponentInfoFlags.of(flags.toLong()),
            )
        } else {
            getReceiverInfoLegacy(packageManager, componentName, flags)
        }

    fun getServiceInfo(
        packageManager: PackageManager,
        componentName: ComponentName,
        flags: Int = 0,
    ): ServiceInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getServiceInfo(
                componentName,
                PackageManager.ComponentInfoFlags.of(flags.toLong()),
            )
        } else {
            getServiceInfoLegacy(packageManager, componentName, flags)
        }

    @Suppress("DEPRECATION")
    private fun getApplicationInfoLegacy(
        packageManager: PackageManager,
        packageName: String,
        flags: Int,
    ): ApplicationInfo = packageManager.getApplicationInfo(packageName, flags)

    @Suppress("DEPRECATION")
    private fun getPackageInfoLegacy(
        packageManager: PackageManager,
        packageName: String,
        flags: Int,
    ): PackageInfo = packageManager.getPackageInfo(packageName, flags)

    @Suppress("DEPRECATION")
    private fun getReceiverInfoLegacy(
        packageManager: PackageManager,
        componentName: ComponentName,
        flags: Int,
    ): ActivityInfo = packageManager.getReceiverInfo(componentName, flags)

    @Suppress("DEPRECATION")
    private fun getServiceInfoLegacy(
        packageManager: PackageManager,
        componentName: ComponentName,
        flags: Int,
    ): ServiceInfo = packageManager.getServiceInfo(componentName, flags)
}
