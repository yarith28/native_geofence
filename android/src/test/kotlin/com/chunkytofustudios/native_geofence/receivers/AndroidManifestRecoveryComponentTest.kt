package com.chunkytofustudios.native_geofence.receivers

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class AndroidManifestRecoveryComponentTest {
    @Test
    fun `location-mode recovery receiver is enabled non-exported and manifest-backed`() {
        val manifest = findPluginManifest()
        val document = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
        }.newDocumentBuilder().parse(manifest)
        val receivers = document.getElementsByTagName("receiver")
        val receiver = (0 until receivers.length)
            .map { receivers.item(it) }
            .firstOrNull { node ->
                node.attributes?.getNamedItemNS(ANDROID_NAMESPACE, "name")?.nodeValue ==
                    ".receivers.NativeGeofenceLocationModeBroadcastReceiver"
            }

        assertNotNull(receiver)
        assertEquals(
            "true",
            receiver.attributes.getNamedItemNS(ANDROID_NAMESPACE, "enabled")?.nodeValue,
        )
        assertEquals(
            "false",
            receiver.attributes.getNamedItemNS(ANDROID_NAMESPACE, "exported")?.nodeValue,
        )
        val actions = (0 until receiver.childNodes.length)
            .flatMap { childIndex ->
                val child = receiver.childNodes.item(childIndex)
                (0 until child.childNodes.length).map { child.childNodes.item(it) }
            }
            .filter { it.nodeName == "action" }
            .mapNotNull { it.attributes?.getNamedItemNS(ANDROID_NAMESPACE, "name")?.nodeValue }
        assertTrue("android.location.MODE_CHANGED" in actions)
    }

    private fun findPluginManifest(): File {
        var directory = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
        repeat(8) {
            val candidate = File(directory, "android/src/main/AndroidManifest.xml")
            if (candidate.isFile) return candidate
            directory = directory.parentFile ?: return@repeat
        }
        error("Could not locate android/src/main/AndroidManifest.xml from the test directory.")
    }

    private companion object {
        const val ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android"
    }
}
