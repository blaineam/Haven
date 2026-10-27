package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A call placed from the car (or by a voice launch) can reach [CallManager] in a process nothing but the
 * car service started — no MainActivity, no RootScreen — where `CallManager.appContext` was never set and
 * the first call crashed the process (`UninitializedPropertyAccessException` on the Desktop Head Unit).
 * [CallRuntime] is the one place that brings the call stack up in such a process.
 */
class CallRuntimeTest {
    private class FakeBoot(
        var calls: Boolean = false,
        var onboarded: Boolean = true,
        var engineFails: Boolean = false,
        var callsFail: Boolean = false,
    ) : CallRuntime.Boot {
        val log = mutableListOf<String>()
        override fun callsReady() = calls
        override fun onboarded() = onboarded
        override fun bootEngine() { log += "engine"; if (engineFails) error("engine boom") }
        override fun initCalls() { log += "calls"; if (callsFail) error("calls boom"); calls = true }
    }

    @Test fun `an uninitialised process is brought up engine first then calls and reports ready`() {
        val b = FakeBoot()
        assertTrue(CallRuntime.ensureReady(b))
        assertEquals(listOf("engine", "calls"), b.log)
    }

    @Test fun `an already ready process boots nothing`() {
        val b = FakeBoot(calls = true)
        assertTrue(CallRuntime.ensureReady(b))
        assertTrue(b.log.isEmpty())
    }

    @Test fun `asking twice boots once`() {
        val b = FakeBoot()
        CallRuntime.ensureReady(b)
        CallRuntime.ensureReady(b)
        assertEquals(listOf("engine", "calls"), b.log)
    }

    @Test fun `no account yet is not ready and boots nothing`() {
        val b = FakeBoot(onboarded = false)
        assertFalse(CallRuntime.ensureReady(b))
        assertTrue(b.log.isEmpty())
    }

    @Test fun `an engine failure is a graceful not ready, never a thrown exception`() {
        val b = FakeBoot(engineFails = true)
        assertFalse(CallRuntime.ensureReady(b))
        assertEquals("calls are not initialised after a failed engine boot", listOf("engine"), b.log)
    }

    @Test fun `a call stack failure is a graceful not ready`() {
        assertFalse(CallRuntime.ensureReady(FakeBoot(callsFail = true)))
    }

    @Test fun `a retry after a failure can still succeed`() {
        val b = FakeBoot(engineFails = true)
        assertFalse(CallRuntime.ensureReady(b))
        b.engineFails = false
        assertTrue(CallRuntime.ensureReady(b))
    }

    // ---- source guards: nothing may reach the call engine before it is initialised ----

    private fun root(): File {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/main/java").isDirectory) d = d.parentFile ?: error("no repo root")
        return d
    }
    private val java get() = File(root(), "android/app/src/main/java/com/blaineam/haven")

    @Test fun `every non UI entry point that places a call goes through the shared initialiser`() {
        // The car app and the voice route run in processes with no RootScreen to initialise CallManager.
        val files = File(java, "car").walkTopDown().filter { it.isFile && it.extension == "kt" }.toList() +
            File(java, "core/AssistantLaunch.kt")
        // The Telecom service is an entry point of its own: the system can bind it in a cold process.
        assertTrue("HavenTelecomService must warm the call stack in onCreate",
            File(java, "core/HavenTelecomService.kt").readText().contains("CallRuntime.whenReady"))
        for (f in files) {
            val code = f.readText().lineSequence().filterNot { it.trim().startsWith("*") || it.trim().startsWith("//") }.joinToString("\n")
            if (code.contains("CallManager.startCall(")) {
                assertTrue("${f.name} places a call without CallRuntime.whenReady", code.contains("CallRuntime.whenReady"))
            }
        }
    }

    @Test fun `the call engine ignores an entry that arrives before init`() {
        val src = File(java, "core/CallManager.kt").readText()
        val onCall = src.substring(src.indexOf("private fun onCall("), src.indexOf("fun runOnCallThreadAndWait"))
        assertTrue("onCall must check isReady first", onCall.indexOf("if (!isReady)") in 0 until onCall.indexOf("callHandler.post"))
    }

    @Test fun `init stays idempotent and synchronised`() {
        val src = File(java, "core/CallManager.kt").readText()
        val at = src.indexOf("fun init(context: Context, myNodeHex: String)")
        assertTrue(src.substring(maxOf(0, at - 160), at).contains("@Synchronized"))
        assertTrue(src.substring(at, at + 200).contains("isInitialized"))
    }

    @Test fun `the cold start receivers and sessions boot the engine themselves`() {
        // Everything that can be the first code to run in a cold process initialises the engine before reading it.
        val checks = mapOf(
            "core/CarActionReceiver.kt" to "EngineBoot.background",
            "core/CarCallSource.kt" to "HavenNet.init",
            "core/CarConversationSource.kt" to "HavenNet.init",
        )
        for ((path, needle) in checks) {
            assertTrue("$path must contain $needle", File(java, path).readText().contains(needle))
        }
        // …and the runtime itself boots the engine before the call stack, in that order.
        val rt = File(java, "core/CallRuntime.kt").readText()
        assertTrue(rt.indexOf("bootEngine()") < rt.indexOf("initCalls()"))
    }
}
