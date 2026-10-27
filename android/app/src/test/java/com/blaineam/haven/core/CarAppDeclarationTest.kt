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

    private fun service(name: String = ".car.HavenCarAppService"): Element =
        all(manifest(), "service").singleOrNull { attr(it, "name") == name }
            ?: error("AndroidManifest.xml must declare $name exactly once")

    private fun messagesService() = service(".car.HavenMessagesCarAppService")

    @Test fun `haven calls and haven messages are two car app entries one per category`() {
        // Each category is a Gradle placeholder so the Play production bundle can drop it (see the gating
        // tests below); the build resolves them to the real androidx.car.app.category.* names.
        val calls = service()
        assertEquals(listOf("androidx.car.app.CarAppService"), all(calls, "action").map { attr(it, "name") })
        assertEquals(listOf("\${carCallingCategory}"), all(calls, "category").map { attr(it, "name") })
        assertEquals("\${carAppEnabled}", attr(calls, "enabled"))
        val msgs = messagesService()
        assertEquals(listOf("androidx.car.app.CarAppService"), all(msgs, "action").map { attr(it, "name") })
        assertEquals(listOf("\${carMessagingCategory}"), all(msgs, "category").map { attr(it, "name") })
        assertEquals("\${carAppEnabled}", attr(msgs, "enabled"))
    }

    @Test fun `the two entries have distinct labels and icons so they show as separate Haven entries`() {
        val calls = service(); val msgs = messagesService()
        assertEquals("@string/car_calls_label", attr(calls, "label"))
        assertEquals("@string/car_messages_label", attr(msgs, "label"))
        assertEquals("@drawable/ic_car_entry_calls", attr(calls, "icon"))
        assertEquals("@drawable/ic_car_entry_messages", attr(msgs, "icon"))
        for (n in listOf("ic_car_entry_calls", "ic_car_entry_messages")) assertTrue(File(main, "res/drawable/$n.xml").isFile)
    }

    @Test fun `the messages entry is exported for the host and nothing else binds it`() {
        assertEquals("true", attr(messagesService(), "exported"))
        assertEquals("exactly one intent filter", 1, all(messagesService(), "intent-filter").size)
    }

    @Test fun `both services share the one host validator`() {
        for (f in listOf("HavenCarAppService.kt", "HavenMessagesCarAppService.kt")) {
            val src = File(main, "java/com/blaineam/haven/car/$f").readText()
            assertTrue("$f must validate hosts through CarHosts.validator", src.contains("CarHosts.validator(this, (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0)"))
        }
    }

    @Test fun `messages are their own entry unless the fallback tab is switched on`() {
        assertFalse("TAB_IN_CALLS_SERVICE must stay off while Haven Messages is a separate entry", CarConversations.TAB_IN_CALLS_SERVICE)
    }

    @Test fun `the car app categories are on for testing tracks and off for production and open testing`() {
        val gradle = File(repoRoot(), "android/app/build.gradle.kts").readText()
        // Defaults ON (local / debug / rc), OFF only on an explicit false.
        assertTrue(Regex("""havenCarApp"\)\s+as\s+String\?\)\s*\?:\s*System\.getenv\("HAVEN_CAR_APP"\)\s*\?:\s*"true"""").containsMatchIn(gradle))
        assertTrue(gradle.contains("""manifestPlaceholders["carCallingCategory"] = if (carApp) "androidx.car.app.category.CALLING""""))
        assertTrue(gradle.contains("""manifestPlaceholders["carMessagingCategory"] = if (carApp) "androidx.car.app.category.MESSAGING""""))
        // The off values must NOT be the real category names (Play scans the manifest for them).
        val off = Regex("""else "([^"]+)"""").findAll(gradle.substringAfter("carCallingCategory")).map { it.groupValues[1] }.take(2).toList()
        for (v in off) assertFalse("an 'off' category must not be a real car category: $v", v.startsWith("androidx.car.app.category."))
    }

    @Test fun `the source manifest never names a real car category - only the placeholders do`() {
        // Play scans the merged manifest (comments included) for the categories: a literal here would survive the
        // production strip. The real names live only in app/build.gradle.kts.
        assertFalse(File(main, "AndroidManifest.xml").readText().contains("androidx.car.app.category"))
    }

    @Test fun `the play workflow builds the car app only for the internal and closed testing tracks`() {
        val yml = File(repoRoot(), ".github/workflows/android.yml").readText()
        val line = yml.lines().singleOrNull { it.trim().startsWith("HAVEN_CAR_APP:") } ?: error("android.yml must set HAVEN_CAR_APP on the AAB build")
        assertTrue(line.contains("'internal'") && line.contains("'alpha'"))
        // …and never production / beta (open testing): the expression's fallback is 'false'.
        assertTrue(line.trimEnd().endsWith("&& 'true' || 'false' }}"))
        assertFalse(line.contains("'production'") || line.contains("'beta'"))
    }

    @Test fun `the car app service is exported for the host and nothing else binds it`() {
        assertEquals("true", attr(service(), "exported"))
        assertEquals("exactly one intent filter", 1, all(service(), "intent-filter").size)
    }

    @Test fun `the minimum car api level is declared`() {
        val v = all(manifest(), "meta-data").singleOrNull { attr(it, "name") == "androidx.car.app.minCarApiLevel" }
        assertTrue("androidx.car.app.minCarApiLevel meta-data is required", v != null)
        // ConversationItem (the Messages entry) needs Car App API level 7; the setting is app-wide.
        assertTrue(attr(v!!, "value").toInt() >= CarConversations.MESSAGES_API_LEVEL)
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
        // The Calls screens only. The Messages tab ([CarMessagesList]) is the one place message text goes to the
        // host — and only the already-redacted rows from CarConversations.rows (tested in CarConversationsTest).
        File(main, "java/com/blaineam/haven/car").walkTopDown().filter { it.isFile && it.extension == "kt" && it.name !in setOf("CarMessagesList.kt") }.forEach { f ->
            val code = f.readText().lineSequence().filterNot { it.trim().startsWith("*") || it.trim().startsWith("//") || it.trim().startsWith("/*") }.joinToString("\n")
            for (b in banned) assertFalse("${f.name} must not touch $b", code.contains(b))
        }
    }

    @Test fun `every shipped locale carries the car app strings`() {
        val keys = listOf("car_calls_title", "car_tab_recents", "car_tab_contacts", "car_setup_needed", "car_empty_recents",
            "car_empty_contacts", "car_row_subtitle", "car_calling", "car_in_call", "car_hang_up", "car_search_all", "car_search_hint",
            "car_tab_messages", "car_empty_messages", "car_generic_message", "car_calls_label", "car_messages_label",
            "car_messages_title", "car_messages_off")
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
        for (n in listOf("ic_car_recents", "ic_car_contacts", "ic_car_messages")) assertTrue(File(main, "res/drawable/$n.xml").isFile)
    }
}
