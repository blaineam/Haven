package com.blaineam.haven.core

import com.blaineam.haven.car.CarHosts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Haven's Android Auto CAR APP is wired in the manifest, a descriptor and a host allowlist — none of
 * which a JVM test would otherwise load. Drop the category and the head unit silently never lists the
 * app; widen the host check and any app could drive it. Parsed from source, like [TelecomDeclarationTest].
 */
class CarAppDeclarationTest {
    private fun repoRoot(): File {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/main").isDirectory) {
            d = d.parentFile ?: error("cannot locate repo root from ${System.getProperty("user.dir")}")
        }
        return d
    }
    private val main get() = File(repoRoot(), "android/app/src/main")
    private val ns = "http://schemas.android.com/apk/res/android"

    private fun manifest(): Element {
        val f = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        return f.newDocumentBuilder().parse(File(main, "AndroidManifest.xml")).documentElement
    }
    private fun all(e: Element, tag: String): List<Element> =
        (0 until e.getElementsByTagName(tag).length).map { e.getElementsByTagName(tag).item(it) as Element }
    private fun attr(e: Element, name: String) = e.getAttributeNS(ns, name)

    private fun service(): Element =
        all(manifest(), "service").singleOrNull { attr(it, "name") == ".car.HavenCarAppService" }
            ?: error("AndroidManifest.xml must declare .car.HavenCarAppService exactly once")

    @Test fun `the car app service answers the car app action in the calling category`() {
        val s = service()
        assertEquals(listOf("androidx.car.app.CarAppService"), all(s, "action").map { attr(it, "name") })
        assertEquals(listOf("androidx.car.app.category.CALLING"), all(s, "category").map { attr(it, "name") })
    }

    @Test fun `the car app service is exported for the host and nothing else binds it`() {
        assertEquals("true", attr(service(), "exported"))
        assertEquals("exactly one intent filter", 1, all(service(), "intent-filter").size)
    }

    @Test fun `the minimum car api level is declared`() {
        val v = all(manifest(), "meta-data").singleOrNull { attr(it, "name") == "androidx.car.app.minCarApiLevel" }
        assertTrue("androidx.car.app.minCarApiLevel meta-data is required", v != null)
        assertTrue(attr(v!!, "value").toInt() >= 1)
    }

    @Test fun `the descriptor declares both the notification and the template capability`() {
        val x = File(main, "res/xml/automotive_app_desc.xml").readText()
        val uses = Regex("""<uses\s+name="([^"]+)"""").findAll(x).map { it.groupValues[1] }.toList()
        assertEquals(listOf("notification", "template"), uses)
    }

    @Test fun `the host check is lenient only for a debuggable build`() {
        assertTrue(CarHosts.allowAnyHost(debuggable = true))
        assertFalse("a release build must validate the host", CarHosts.allowAnyHost(debuggable = false))
    }

    @Test fun `the allow all validator appears only inside the guarded helper`() {
        val hits = File(main, "java").walkTopDown().filter { it.isFile && it.extension == "kt" }
            .filter { it.readText().contains("ALLOW_ALL_HOSTS_VALIDATOR") }.map { it.name }.toList()
        assertEquals(listOf("CarHosts.kt"), hits)
        val src = File(main, "java/com/blaineam/haven/car/CarHosts.kt").readText()
        assertTrue(Regex("""if \(allowAnyHost\(debuggable\)\) HostValidator\.ALLOW_ALL_HOSTS_VALIDATOR""").containsMatchIn(src))
        assertTrue("the release path uses the Google host allowlist", src.contains("hosts_allowlist_sample"))
    }

    @Test fun `the car app code never reads message text`() {
        // The head unit shows names and avatars only — a driver-distraction and privacy rule (CarPlay parity).
        val banned = listOf("HavenNet.messages(", "body", "ciphertext", "plaintext")
        File(main, "java/com/blaineam/haven/car").walkTopDown().filter { it.isFile && it.extension == "kt" }.forEach { f ->
            val code = f.readText().lineSequence().filterNot { it.trim().startsWith("*") || it.trim().startsWith("//") || it.trim().startsWith("/*") }.joinToString("\n")
            for (b in banned) assertFalse("${f.name} must not touch $b", code.contains(b))
        }
    }

    @Test fun `every shipped locale carries the car app strings`() {
        val keys = listOf("car_calls_title", "car_tab_recents", "car_tab_contacts", "car_setup_needed", "car_empty_recents",
            "car_empty_contacts", "car_row_subtitle", "car_calling", "car_in_call", "car_hang_up", "car_search_all", "car_search_hint")
        val dirs = File(main, "res").listFiles { f -> f.isDirectory && f.name.startsWith("values") && File(f, "strings.xml").exists() }!!
        assertEquals("expected the 9 shipped locales", 9, dirs.size)
        for (d in dirs) {
            val s = File(d, "strings.xml").readText()
            for (k in keys) assertTrue("${d.name} is missing $k", s.contains("""name="$k""""))
            // The two call-status strings take the contact's name.
            for (k in listOf("car_calling", "car_in_call")) {
                val v = Regex("""<string name="$k">([^<]*)</string>""").find(s)!!.groupValues[1]
                assertTrue("${d.name}/$k must contain %1${'$'}s", v.contains("%1${'$'}s"))
            }
        }
    }

    @Test fun `the tab icons exist`() {
        for (n in listOf("ic_car_recents", "ic_car_contacts")) assertTrue(File(main, "res/drawable/$n.xml").isFile)
    }
}
