package com.chunkytofustudios.native_geofence.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AndroidGeofenceRegistrationPersistenceTest {
    @Test
    fun `active replacement retains previous routing authority until commit`() {
        var routingAuthority = "previous"
        var inactiveSaves = 0
        var lifecycleCommits = 0
        val persistence = persistence(
            mode = AndroidGeofenceRegistrationPersistenceMode.select(
                persistConfiguredRegistration = true,
                hasActivePreviousRegistration = true,
            ),
            saveInactive = {
                inactiveSaves += 1
                routingAuthority = "new-inactive"
            },
            saveActive = { routingAuthority = "new-active" },
            markActive = { lifecycleCommits += 1 },
        )

        assertTrue(persistence.saveProvisional())
        assertEquals("previous", routingAuthority)
        assertEquals(0, inactiveSaves)

        assertTrue(persistence.commit())
        assertEquals("new-active", routingAuthority)
        assertEquals(0, lifecycleCommits)
    }

    @Test
    fun `new registration remains routable while awaiting initial trigger`() {
        var routingAuthority = "missing"
        var lifecycleCommits = 0
        val persistence = persistence(
            mode = AndroidGeofenceRegistrationPersistenceMode.select(
                persistConfiguredRegistration = true,
                hasActivePreviousRegistration = false,
            ),
            saveInactive = { routingAuthority = "new-inactive" },
            saveActive = { routingAuthority = "new-active" },
            markActive = { lifecycleCommits += 1 },
        )

        assertTrue(persistence.saveProvisional())
        assertEquals("new-inactive", routingAuthority)

        assertTrue(persistence.commit())
        assertEquals("new-inactive", routingAuthority)
        assertEquals(1, lifecycleCommits)
    }

    @Test
    fun `rearm changes only existing lifecycle state`() {
        var routingAuthority = "existing"
        var lifecycleCommits = 0
        val persistence = persistence(
            mode = AndroidGeofenceRegistrationPersistenceMode.select(
                persistConfiguredRegistration = false,
                hasActivePreviousRegistration = true,
            ),
            saveInactive = { routingAuthority = "inactive" },
            saveActive = { routingAuthority = "replacement" },
            markActive = { lifecycleCommits += 1 },
        )

        assertTrue(persistence.saveProvisional())
        assertEquals("existing", routingAuthority)
        assertTrue(persistence.commit())
        assertEquals("existing", routingAuthority)
        assertEquals(1, lifecycleCommits)
    }

    private fun persistence(
        mode: AndroidGeofenceRegistrationPersistenceMode,
        saveInactive: () -> Unit,
        saveActive: () -> Unit,
        markActive: () -> Unit,
    ) = AndroidGeofenceRegistrationPersistence(
        mode = mode,
        saveInactiveRegistration = {
            saveInactive()
            true
        },
        saveActiveRegistration = {
            saveActive()
            true
        },
        markExistingRegistrationActive = {
            markActive()
            true
        },
    )
}
