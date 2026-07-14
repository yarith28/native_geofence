package com.chunkytofustudios.native_geofence.util

internal enum class AndroidGeofenceRegistrationPersistenceMode {
    NEW_REGISTRATION,
    ACTIVE_REPLACEMENT,
    REARM_EXISTING;

    companion object {
        fun select(
            persistConfiguredRegistration: Boolean,
            hasActivePreviousRegistration: Boolean,
        ): AndroidGeofenceRegistrationPersistenceMode = when {
            !persistConfiguredRegistration -> REARM_EXISTING
            hasActivePreviousRegistration -> ACTIVE_REPLACEMENT
            else -> NEW_REGISTRATION
        }
    }
}

/**
 * Controls when callback-routing metadata becomes authoritative during a
 * registration transaction.
 *
 * New registrations must be visible before Play services confirms the add so
 * an immediate initial trigger can be delivered. Active replacements instead
 * retain the previous route until confirmation; a queued event from the old
 * same-ID fence must never reach an uncommitted callback. Recovery re-arms do
 * not publish new configuration at either stage.
 */
internal class AndroidGeofenceRegistrationPersistence(
    private val mode: AndroidGeofenceRegistrationPersistenceMode,
    private val saveInactiveRegistration: () -> Boolean,
    private val saveActiveRegistration: () -> Boolean,
    private val markExistingRegistrationActive: () -> Boolean,
) {
    fun saveProvisional(): Boolean = when (mode) {
        AndroidGeofenceRegistrationPersistenceMode.NEW_REGISTRATION ->
            saveInactiveRegistration()
        AndroidGeofenceRegistrationPersistenceMode.ACTIVE_REPLACEMENT,
        AndroidGeofenceRegistrationPersistenceMode.REARM_EXISTING -> true
    }

    fun commit(): Boolean = when (mode) {
        AndroidGeofenceRegistrationPersistenceMode.ACTIVE_REPLACEMENT ->
            saveActiveRegistration()
        AndroidGeofenceRegistrationPersistenceMode.NEW_REGISTRATION,
        AndroidGeofenceRegistrationPersistenceMode.REARM_EXISTING ->
            markExistingRegistrationActive()
    }
}
