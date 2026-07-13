package com.chunkytofustudios.native_geofence.util

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat

internal object LocationState {
    fun isEnabled(context: Context): Boolean {
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return true
        return try {
            LocationManagerCompat.isLocationEnabled(manager)
        } catch (_: RuntimeException) {
            // Fail open so recovery can produce an authoritative Play services
            // result rather than waiting for a signal that may never arrive.
            true
        }
    }

    fun hasFinePermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

    fun hasBackgroundPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION
            ) == PackageManager.PERMISSION_GRANTED

    fun hasRequiredPermissions(context: Context): Boolean =
        hasFinePermission(context) && hasBackgroundPermission(context)
}
