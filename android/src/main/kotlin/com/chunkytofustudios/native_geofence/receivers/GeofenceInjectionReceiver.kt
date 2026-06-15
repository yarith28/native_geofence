package com.chunkytofustudios.native_geofence.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.Location
import android.util.Log
import com.chunkytofustudios.native_geofence.Constants
import com.chunkytofustudios.native_geofence.generated.GeofenceEvent
import com.chunkytofustudios.native_geofence.util.GeofenceEventInjector

/**
 * Receives externally-confirmed geofence transitions from a higher layer and
 * routes them through [GeofenceEventInjector] so they go out the same de-duped
 * dispatch path as OS geofence events.
 *
 * Same-app only (exported=false); callers target it explicitly by component.
 */
class GeofenceInjectionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Constants.ACTION_INJECT_GEOFENCE_EVENT) return

        val id = intent.getStringExtra(Constants.INJECT_EXTRA_GEOFENCE_ID)
        val eventName = intent.getStringExtra(Constants.INJECT_EXTRA_EVENT)
        if (id == null || eventName == null) {
            Log.w(TAG, "Injection missing id/event extras.")
            return
        }
        val event = try {
            GeofenceEvent.valueOf(eventName.uppercase())
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Injection has invalid event=$eventName.")
            return
        }

        val location = extractLocation(intent)
        val isMock = intent.getBooleanExtra(Constants.INJECT_EXTRA_MOCK, false)
        val source = intent.getStringExtra(Constants.INJECT_EXTRA_SOURCE)?.takeIf { it.isNotBlank() }
            ?: Constants.EVENT_SOURCE_EXTERNAL_INJECTION

        val pending = goAsync()
        try {
            GeofenceEventInjector.inject(context, id, event, location, isMock, source)
        } catch (e: Throwable) {
            Log.w(TAG, "Injection failed: ${e.message}")
        } finally {
            pending.finish()
        }
    }

    private fun extractLocation(intent: Intent): Location? {
        if (!intent.hasExtra(Constants.INJECT_EXTRA_LAT) ||
            !intent.hasExtra(Constants.INJECT_EXTRA_LNG)
        ) {
            return null
        }
        return Location("injected").apply {
            latitude = intent.getDoubleExtra(Constants.INJECT_EXTRA_LAT, 0.0)
            longitude = intent.getDoubleExtra(Constants.INJECT_EXTRA_LNG, 0.0)
            val acc = intent.getFloatExtra(Constants.INJECT_EXTRA_ACCURACY, -1f)
            if (acc >= 0f) accuracy = acc
            val t = intent.getLongExtra(Constants.INJECT_EXTRA_TIME, 0L)
            if (t > 0L) time = t
        }
    }

    companion object {
        private const val TAG = "GeofenceInjectionReceiver"
    }
}
