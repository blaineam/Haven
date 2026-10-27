package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The Assistant App Action is plain XML that nothing in the JVM ever loads, so a bad edit (a renamed
 * action, a key that no longer matches what MainActivity reads, a dropped share-target) would only
 * surface as "Hey Google" silently doing nothing. Parsed from source and cross-checked against the
 * constants in [AssistantRoute] — like [AndroidAutoDeclarationTest].
 */
class AssistantShortcutsDeclarationTest {
    private fun repoRoot(): File {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/main").isDirectory) {
            d = d.parentFile ?: error("cannot locate repo root from ${System.getProperty("user.dir")}")
        }
        return d
    }
    private val main get() = File(repoRoot(), "android/app/src/main")
    private val ns = "http://schemas.android.com/apk/res/android"

    private fun shortcuts(): Element {
        val f = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        return f.newDocumentBuilder().parse(File(main, "res/xml/shortcuts.xml")).documentElement
    }

    private fun children(e: Element, tag: String): List<Element> =
        (0 until e.childNodes.length).map { e.childNodes.item(it) }.filterIsInstance<Element>().filter { it.tagName == tag }

    private fun attr(e: Element, name: String) = e.getAttributeNS(ns, name)

    private fun capability(): Element =
        children(shortcuts(), "capability").singleOrNull { attr(it, "name") == AssistantRoute.CAPABILITY_CREATE_MESSAGE }
            ?: error("shortcuts.xml must declare exactly one ${AssistantRoute.CAPABILITY_CREATE_MESSAGE} capability")

    @Test fun `shortcuts xml is well formed and keeps the share target`() {
        val root = shortcuts()
        assertEquals("shortcuts", root.tagName)
        val share = children(root, "share-target").single()
        assertEquals("com.blaineam.haven.MainActivity", attr(share, "targetClass"))
        val cats = children(share, "category").map { attr(it, "name") }
        assertTrue(cats.contains(ShareShortcuts.CATEGORY))
    }

    @Test fun `the create message capability launches MainActivity with our action`() {
        val intent = children(capability(), "intent").single()
        assertEquals(AssistantRoute.ACTION, attr(intent, "action"))
        assertEquals("com.blaineam.haven", attr(intent, "targetPackage"))
        assertEquals("com.blaineam.haven.MainActivity", attr(intent, "targetClass"))
    }

    @Test fun `the capability binds the text and recipient name to the extras MainActivity reads`() {
        val params = children(children(capability(), "intent").single(), "parameter")
            .associate { attr(it, "name") to attr(it, "key") }
        assertEquals(AssistantRoute.EXTRA_TEXT, params["message.text"])
        assertEquals(AssistantRoute.EXTRA_NAME, params[AssistantRoute.PARAM_RECIPIENT_NAME])
    }

    @Test fun `no parameter is required so the one intent is also the fallback`() {
        for (p in children(children(capability(), "intent").single(), "parameter")) {
            assertFalse("${attr(p, "name")} must stay optional", attr(p, "required") == "true")
        }
    }

    @Test fun `MainActivity reads the same action and keys`() {
        val src = File(main, "java/com/blaineam/haven/MainActivity.kt").readText()
        assertTrue(src.contains("AssistantRoute.ACTION"))
        assertTrue(src.contains("AssistantRoute.EXTRA_NAME"))
        assertTrue(src.contains("AssistantRoute.EXTRA_TEXT"))
    }

    @Test fun `every launcher entry still points at the shortcuts file`() {
        val m = File(main, "AndroidManifest.xml").readText()
        val metas = Regex("""android:name="android\.app\.shortcuts"\s+android:resource="@xml/shortcuts"""").findAll(m).count()
        assertTrue("MainActivity and its launcher aliases must all carry the shortcuts meta-data (found $metas)", metas >= 2)
    }

    @Test fun `the dynamic shortcuts carry the capability binding and the conversation markers`() {
        val src = File(main, "java/com/blaineam/haven/core/ShareShortcuts.kt").readText()
        assertTrue(src.contains("addCapabilityBinding(AssistantRoute.CAPABILITY_CREATE_MESSAGE"))
        assertTrue(src.contains("setLocusId"))
        assertTrue(src.contains("setIsConversation()"))
        assertEquals("android.shortcut.conversation", ShareShortcuts.CONVERSATION_CATEGORY)
    }

    // ---- actions.intent.CREATE_CALL ("call Tracy on Haven") ----
    private fun callCapability(): Element =
        children(shortcuts(), "capability").singleOrNull { attr(it, "name") == AssistantCallRoute.CAPABILITY_CREATE_CALL }
            ?: error("shortcuts.xml must declare exactly one ${AssistantCallRoute.CAPABILITY_CREATE_CALL} capability")

    @Test fun `both capabilities are declared side by side`() {
        val names = children(shortcuts(), "capability").map { attr(it, "name") }
        assertTrue(names.containsAll(listOf(AssistantRoute.CAPABILITY_CREATE_MESSAGE, AssistantCallRoute.CAPABILITY_CREATE_CALL)))
    }

    @Test fun `the create call capability launches MainActivity with the call action`() {
        val intent = children(callCapability(), "intent").single()
        assertEquals(AssistantCallRoute.ACTION, attr(intent, "action"))
        assertEquals("com.blaineam.haven", attr(intent, "targetPackage"))
        assertEquals("com.blaineam.haven.MainActivity", attr(intent, "targetClass"))
        assertTrue("the call and message actions must differ", AssistantCallRoute.ACTION != AssistantRoute.ACTION)
    }

    @Test fun `the call capability binds the participant name and format to the extras MainActivity reads`() {
        val params = children(children(callCapability(), "intent").single(), "parameter")
            .associate { attr(it, "name") to attr(it, "key") }
        assertEquals(AssistantCallRoute.EXTRA_NAME, params[AssistantCallRoute.PARAM_PARTICIPANT_NAME])
        assertEquals(AssistantCallRoute.EXTRA_FORMAT, params[AssistantCallRoute.PARAM_CALL_FORMAT])
        assertEquals("a phone number is never bound — calls go to Haven contacts only", 2, params.size)
    }

    @Test fun `no call parameter is required so the one intent is also the fallback`() {
        for (p in children(children(callCapability(), "intent").single(), "parameter")) {
            assertFalse("${attr(p, "name")} must stay optional", attr(p, "required") == "true")
        }
    }

    @Test fun `MainActivity reads the call action keys and checks the referrer before dialing`() {
        val src = File(main, "java/com/blaineam/haven/MainActivity.kt").readText()
        assertTrue(src.contains("AssistantCallRoute.ACTION"))
        assertTrue(src.contains("AssistantCallRoute.EXTRA_NAME"))
        assertTrue(src.contains("AssistantCallRoute.EXTRA_FORMAT"))
        assertTrue("the trust decision must come from the launch referrer", src.contains("AssistantCallRoute.isTrustedReferrer(referrer"))
    }

    @Test fun `only one to one shortcuts are bound for calling`() {
        val src = File(main, "java/com/blaineam/haven/core/ShareShortcuts.kt").readText()
        val at = src.indexOf("AssistantCallRoute.CAPABILITY_CREATE_CALL")
        assertTrue(at > 0)
        assertTrue("the call binding must sit under an others.size == 1 guard",
            src.substring(maxOf(0, at - 160), at).contains("others.size == 1"))
    }
}
