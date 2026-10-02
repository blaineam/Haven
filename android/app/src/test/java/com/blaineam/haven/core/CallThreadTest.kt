package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Call state lives on CallManager's own "haven-call" thread, never main (gate-8: an accept parked main
 * for 61 s in WebRTC/binder setup and the queued ConnectionService start ANR'd). Nothing in the type
 * system says which thread a function runs on, so the source is held to it.
 */
class CallThreadTest {
    private val src: String by lazy {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/main/java").isDirectory) d = d.parentFile ?: error("no repo root")
        File(d, "android/app/src/main/java/com/blaineam/haven/core/CallManager.kt").readText()
    }

    /** Public functions that do not touch call state, or only read snapshots / post themselves. */
    private val exempt = setOf(
        "qaNoteCallEvent", "isOnCallThread", "runOnCallThreadAndWait", "init", "sealedSend", "openSealed",
        "addableContacts", "decline", "adoptHairpinRemoteVideo", "dropHairpinRemoteVideo",
    )

    @Test
    fun everyPublicEntryPointHopsToTheCallThread() {
        val decl = Regex("""^    fun (\w+)\((.*)$""", RegexOption.MULTILINE)
        val offenders = decl.findAll(src)
            .filter { it.groupValues[1] !in exempt }
            .filterNot { it.groupValues[2].contains("= onCall {") }
            .map { it.groupValues[1] }.toList()
        assertTrue("public CallManager entry points that run on the caller's thread: $offenders", offenders.isEmpty())
    }

    @Test
    fun nothingButTheUiHandlerTargetsMain() {
        assertEquals("only uiHandler may bind the main looper", 1, Regex("""getMainLooper\(\)""").findAll(src).count())
        assertTrue("inbound frames are handled on the call thread", !src.contains("Dispatchers.Main"))
        assertTrue("no mainHandler — call state is not main-thread state", !src.contains("mainHandler"))
    }

    @Test
    fun theTwoPostOnlyEntryPointsPostToTheCallThread() {
        for (name in listOf("adoptHairpinRemoteVideo", "dropHairpinRemoteVideo")) {
            val at = src.indexOf("    fun $name(")
            val body = src.substring(at, src.indexOf("\n    }", at))
            assertTrue(name, body.contains("callHandler.post"))
        }
    }
}
