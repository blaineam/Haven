package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The Android Auto declarations are plain XML that nothing in the JVM ever loads, so a bad edit
 * (dropped meta-data, an exported action receiver, a locale missing the new strings) would only show
 * up on a head unit. Scanned from source, like [MainThreadEngineAccessTest].
 */
class AndroidAutoDeclarationTest {
    private fun repoRoot(): File {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/main").isDirectory) {
            d = d.parentFile ?: error("cannot locate repo root from ${System.getProperty("user.dir")}")
        }
        return d
    }
    private val main get() = File(repoRoot(), "android/app/src/main")

    @Test fun `manifest links the automotive descriptor`() {
        val m = File(main, "AndroidManifest.xml").readText()
        assertTrue(Regex("""com\.google\.android\.gms\.car\.application"\s+android:resource="@xml/automotive_app_desc"""").containsMatchIn(m))
    }

    @Test fun `descriptor uses the notification capability for messages and the template one for the calls screen`() {
        // `notification` = Haven's MessagingStyle notifications; `template` = the Car App Library calls screen
        // (CarAppDeclarationTest checks the service). Never sms / media.
        val x = File(main, "res/xml/automotive_app_desc.xml").readText()
        val uses = Regex("""<uses\s+name="([^"]+)"""").findAll(x).map { it.groupValues[1] }.toList()
        assertEquals(listOf("notification", "template"), uses)
    }

    @Test fun `the car action receiver is registered and not exported`() {
        val m = File(main, "AndroidManifest.xml").readText()
        val block = Regex("""<receiver\s+android:name="\.core\.CarActionReceiver"[^>]*/>""").find(m)?.value
        assertTrue("CarActionReceiver must be declared", block != null)
        assertTrue(block!!.contains("""android:exported="false""""))
        assertTrue("no intent-filter: only our own PendingIntents may reach it", !block.contains("intent-filter"))
    }

    @Test fun `every shipped locale carries the Android Auto strings`() {
        val keys = listOf("settings_car_header", "settings_android_auto", "settings_android_auto_desc",
            "car_reply_label", "car_mark_read_label")
        val dirs = File(main, "res").listFiles { f -> f.isDirectory && f.name.startsWith("values") && File(f, "strings.xml").exists() }!!
        assertTrue("expected the 9 shipped locales", dirs.size == 9)
        for (d in dirs) {
            val s = File(d, "strings.xml").readText()
            for (k in keys) assertTrue("${d.name} is missing $k", s.contains("""name="$k""""))
        }
    }
}
