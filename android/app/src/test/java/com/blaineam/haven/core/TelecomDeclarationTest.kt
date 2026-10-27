package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The Telecom integration is wired in the manifest and nowhere a JVM test would notice: drop the
 * permission or the service's guard and calls silently stop being system calls (or, worse, the service
 * becomes bindable by any app). Parsed from source and cross-checked — like [AndroidAutoDeclarationTest].
 */
class TelecomDeclarationTest {
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

    private val permissions get() = all(manifest(), "uses-permission").map { attr(it, "name") }

    private fun service(): Element =
        all(manifest(), "service").singleOrNull { attr(it, "name") == ".core.HavenTelecomService" }
            ?: error("AndroidManifest.xml must declare .core.HavenTelecomService exactly once")

    @Test fun `the manifest asks for the own calls permission`() {
        assertTrue(permissions.contains("android.permission.MANAGE_OWN_CALLS"))
    }

    @Test fun `no phone state permission is requested for a self managed account`() {
        for (p in listOf("android.permission.READ_PHONE_STATE", "android.permission.READ_PHONE_NUMBERS",
            "android.permission.CALL_PHONE", "android.permission.ANSWER_PHONE_CALLS")) {
            assertFalse("$p is not needed for a self-managed Telecom account", permissions.contains(p))
        }
    }

    @Test fun `the telecom service is protected by the system only bind permission`() {
        val s = service()
        assertEquals("android.permission.BIND_TELECOM_CONNECTION_SERVICE", attr(s, "permission"))
        assertEquals("true", attr(s, "exported"))
    }

    @Test fun `the telecom service answers the connection service action`() {
        val actions = all(service(), "action").map { attr(it, "name") }
        assertEquals(listOf("android.telecom.ConnectionService"), actions)
    }

    @Test fun `the stay connected service is still its own unexported foreground service`() {
        val fg = all(manifest(), "service").single { attr(it, "name") == ".core.ConnectionService" }
        assertEquals("false", attr(fg, "exported"))
        assertTrue(attr(fg, "foregroundServiceType").contains("microphone"))
    }

    @Test fun `the telecom service class extends the platform ConnectionService`() {
        val src = File(main, "java/com/blaineam/haven/core/HavenTelecomService.kt").readText()
        assertTrue(src.contains("class HavenTelecomService : android.telecom.ConnectionService()"))
        assertTrue(src.contains("class HavenConnection : Connection()"))
        assertTrue("no hold: the engine has no hold state", src.contains("connectionCapabilities = 0"))
        assertTrue(src.contains("PROPERTY_SELF_MANAGED"))
    }

    @Test fun `the account is registered self managed with the haven scheme`() {
        val src = File(main, "java/com/blaineam/haven/core/TelecomCalls.kt").readText()
        assertTrue(src.contains("CAPABILITY_SELF_MANAGED"))
        assertTrue(src.contains("addSupportedUriScheme(TelecomPolicy.SCHEME)"))
        assertEquals("haven", TelecomPolicy.SCHEME)
    }

    @Test fun `every call entry point goes through CallManager startCall which tries Telecom first`() {
        val cm = File(main, "java/com/blaineam/haven/core/CallManager.kt").readText()
        assertTrue(cm.contains("fun startCall(others: List<String>, name: String, session: String? = null) = onCall {"))
        assertTrue(cm.contains("if (!TelecomCalls.place(others, name, session)) startCallOnCall(others, name, session)"))
        assertTrue("the direct path is what Telecom and its fallback call back into", cm.contains("fun startCallDirect("))
        // nothing outside CallManager/TelecomCalls may dial the engine directly
        val offenders = File(main, "java").walkTopDown().filter { it.isFile && it.extension == "kt" }
            .filter { it.name != "CallManager.kt" && it.name != "TelecomCalls.kt" }
            .filter { it.readText().contains("startCallDirect(") }.map { it.name }.toList()
        assertTrue("startCallDirect is Telecom-internal, found in $offenders", offenders.isEmpty())
    }

    @Test fun `the engine reports every connect and end to Telecom`() {
        val cm = File(main, "java/com/blaineam/haven/core/CallManager.kt").readText()
        assertTrue("an ended call must always reach Telecom", cm.contains("TelecomCalls.onEngineEnded(end)"))
        assertTrue("an incoming call must always reach Telecom", cm.contains("TelecomCalls.reportIncoming()"))
        assertTrue(Regex("TelecomCalls\\.onEngineActive\\(\\)").findAll(cm).count() >= 4)
        assertTrue(cm.contains("TelecomCalls.mirrorSpeaker("))
    }

    // ---- a refused Telecom connection must never take the ring with it ----
    @Test fun `the engine posts the notification and ring BEFORE it tells Telecom`() {
        val cm = File(main, "java/com/blaineam/haven/core/CallManager.kt").readText()
        val show = cm.indexOf("Notifications.showIncomingCall(appContext, name)")
        val report = cm.indexOf("TelecomCalls.reportIncoming()")
        assertTrue(show > 0 && report > 0)
        assertTrue("the ring comes from the engine path, so a Telecom refusal can never remove it", show < report)
    }

    @Test fun `the engine keeps a volatile live flag for Telecom to read from the main thread`() {
        val cm = File(main, "java/com/blaineam/haven/core/CallManager.kt").readText()
        assertTrue(cm.contains("@Volatile var telecomLive = false; private set"))
        assertEquals("set when a call starts ringing and when one starts dialing", 2,
            Regex("""telecomLive = true""").findAll(cm).count())
        assertEquals("cleared by teardown", 1, Regex("""telecomLive = false\n""").findAll(cm).count())
    }

    @Test fun `an incoming connection request goes through the tolerant decision and only refuses a duplicate or a finished call`() {
        val t = File(main, "java/com/blaineam/haven/core/TelecomCalls.kt").readText()
        val create = t.substring(t.indexOf("internal fun createIncoming()"), t.indexOf("internal fun incomingRefused()"))
        assertTrue(create.contains("TelecomPolicy.decideIncoming("))
        assertTrue("the engine's volatile flag counts as live", create.contains("CallManager.telecomLive"))
        assertEquals("only the duplicate and the gone verdicts return a failed connection", 2,
            Regex("""createFailedConnection""").findAll(create).count())
        assertTrue("an unverified connection is checked after the grace window", create.contains("TelecomPolicy.GRACE_MS"))
        assertFalse("the old blunt 'not ringing' refusal is gone", create.contains("if (!CallManager.ringing.value) {"))
    }

    @Test fun `a stale Telecom session from an earlier call is ended instead of blocking the next one`() {
        val t = File(main, "java/com/blaineam/haven/core/TelecomCalls.kt").readText()
        assertTrue(t.contains("boundSessionId != CallManager.liveSessionId"))
        assertTrue(t.contains("stale Telecom session"))
        assertTrue(t.contains("lastEndedAt = SystemClock.elapsedRealtime()"))
    }
}
