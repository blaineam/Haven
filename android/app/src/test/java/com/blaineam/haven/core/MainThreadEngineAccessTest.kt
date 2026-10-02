package com.blaineam.haven.core

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Main must never wait on the ENGINE LOCK.
 *
 * Every `HavenSocial` call takes one engine-wide lock, and background work (ingest bursts, whole-state
 * exports, re-seals) holds it for seconds on a loaded device. The e2e gate (2026-10-01) caught main
 * blocked for over a minute and the app ANR'd — through composition-time engine reads keyed on
 * `feedVersion`, call frames opened on main, a service booting the engine on main, and a nearby
 * callback sealing on main. None of that is visible to the type system, so the source is scanned:
 *
 *  - no `remember { … }` block in the UI may make an engine-backed read (use `rememberOffMain`);
 *  - `ConnectionService.onStartCommand` (main) must not call `HavenNet.init` itself;
 *  - HavenNet must not hop to main to hand a call frame to the router (it opens there, off main);
 *  - the Nearby callback must not run the greeting (engine seals) on its own thread;
 *  - no UI code may boot the engine inline — including the first-run seedless link, the last
 *    holdout, which now boots through SeedlessLinkStarter.
 */
class MainThreadEngineAccessTest {

    private fun repoRoot(): File {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/main/java").isDirectory) {
            d = d.parentFile ?: error("cannot locate repo root from ${System.getProperty("user.dir")}")
        }
        return d
    }

    private val src get() = File(repoRoot(), "android/app/src/main/java/com/blaineam/haven")

    /** Calls that go through the engine lock (directly or by decoding a feed). */
    private val engineReads = listOf(
        "HavenNet.engine.", "HavenNet.messages(", "HavenNet.unreadDmConversations(", "HavenNet.reports(",
        "HavenNet.lastActivity(", "HavenNet.unreadMessages(", "HavenNet.pendingCircleUpgrades(",
        "HavenNet.circleIsUpgradable(", "HavenNet.membersOf(", "ComposerAudience.othersCount(",
        "resolveStory(", "previewOf(",
    )

    /** The body of the `{ … }` block whose opening brace is at [open], braces matched. */
    private fun block(text: String, open: Int): String {
        var depth = 0
        for (i in open until text.length) {
            when (text[i]) {
                '{' -> depth++
                '}' -> { depth--; if (depth == 0) return text.substring(open, i + 1) }
            }
        }
        return text.substring(open)
    }

    @Test
    fun `no remember block in the ui reads the engine during composition`() {
        // `remember(keys) {` / `remember {` — but not rememberOffMain / rememberSaveable / remember*State.
        val rememberOpen = Regex("""\bremember\s*(\([^{}]*?\))?\s*\{""")
        val offenders = mutableListOf<String>()
        File(src, "ui").walkTopDown().filter { it.isFile && it.extension == "kt" }.forEach { f ->
            val text = f.readText()
            for (m in rememberOpen.findAll(text)) {
                val body = block(text, m.range.last)
                val hit = engineReads.firstOrNull { body.contains(it) } ?: continue
                val line = text.substring(0, m.range.first).count { it == '\n' } + 1
                offenders += "${f.name}:$line remember { … $hit … }"
            }
        }
        assertTrue("engine reads during composition (move them into rememberOffMain):\n" +
            offenders.joinToString("\n"), offenders.isEmpty())
    }

    @Test
    fun `the scan sees a composition engine read`() {
        // Guards the guard: the matcher must flag the shape the gate's ANR came from.
        val text = "val n = remember(feedTick, readTick) { HavenNet.unreadDmConversations() }"
        val m = Regex("""\bremember\s*(\([^{}]*?\))?\s*\{""").find(text)!!
        assertTrue(block(text, m.range.last).contains("HavenNet.unreadDmConversations("))
    }

    @Test
    fun `connection service never boots the engine on main`() {
        val text = File(src, "core/ConnectionService.kt").readText()
        val start = text.indexOf("override fun onStartCommand")
        assertTrue(start >= 0)
        val body = block(text, text.indexOf('{', start))
        assertTrue("onStartCommand runs on main — boot via EngineBoot.background",
            !body.contains("HavenNet.init(") && body.contains("bootEngine()"))
    }

    @Test
    fun `no ui code boots the engine on main`() {
        // Every UI caller is main (composition, click handlers, LaunchedEffect without a hop). The
        // only allowed shape is a hop: `EngineBoot.offMain { HavenNet.init(…) }`.
        val offenders = mutableListOf<String>()
        File(src, "ui").walkTopDown().filter { it.isFile && it.extension == "kt" }.forEach { f ->
            f.readLines().forEachIndexed { i, line ->
                val code = line.substringBefore("//")
                if (code.contains("HavenNet.init(") && !code.contains("EngineBoot.offMain { HavenNet.init(")) {
                    offenders += "${f.name}:${i + 1} ${line.trim()}"
                }
                if (code.contains("HavenNet.beginSeedlessLink(")) offenders += "${f.name}:${i + 1} ${line.trim()}"
            }
        }
        assertTrue("engine boot on main (use EngineBoot / SeedlessLinkStarter):\n" + offenders.joinToString("\n"),
            offenders.isEmpty())
    }

    @Test
    fun `the seedless onboarding link boots through the off-main starter`() {
        val onb = File(src, "ui/Onboarding.kt").readText()
        assertTrue("onboarding must link via SeedlessLinkStarter", onb.contains("SeedlessLinkStarter.forApp("))
        val starter = File(src, "core/SeedlessLinkStarter.kt").readText()
        val begin = block(starter, starter.indexOf('{', starter.indexOf("fun begin(text: String)")))
        assertTrue("SeedlessLinkStarter.begin must run the link on its worker",
            begin.contains("EngineBoot.offMain(worker) { link("))
    }

    @Test
    fun `call frames are opened off main`() {
        val net = File(src, "core/HavenNet.kt").readText()
        assertTrue("HavenNet must not hop to main before the router opens the frame",
            !Regex("""withContext\(Dispatchers\.Main\)\s*\{\s*callRouter""").containsMatchIn(net))
        val calls = File(src, "core/CallManager.kt").readText()
        assertTrue("the router must open off main, then hand the plaintext to main",
            calls.contains("HavenNet.callRouter = { type, body -> receive(type, body) }"))
    }

    @Test
    fun `a nearby connect greets off main`() {
        val net = File(src, "core/HavenNet.kt").readText()
        val start = net.indexOf("fun onNearbyConnected()")
        val body = block(net, net.indexOf('{', start))
        assertTrue("the Nearby callback is on main — the greeting must be launched off it",
            body.contains("scope.launch { greetNearbyPeer() }") && !body.contains("helloPayload("))
    }

    @Test
    fun `resume-time fan-outs hand themselves off main`() {
        // RootScreen calls these from ON_RESUME (main); each seals or decodes through the engine.
        val net = File(src, "core/HavenNet.kt").readText()
        for ((fn, self) in listOf("fun syncWithContacts()" to "syncWithContacts()", "fun requestMissingMedia()" to "requestMissingMedia()")) {
            val start = net.indexOf(fn)
            assertTrue(fn, start >= 0)
            val body = block(net, net.indexOf('{', start))
            assertTrue("$fn must offload when called on main",
                body.contains("if (onMainThread()) { scope.launch { $self }; return }"))
        }
        val shortcuts = File(src, "core/ShareShortcuts.kt").readText()
        assertTrue("ShareShortcuts.refresh must offload when called on main",
            shortcuts.contains("refreshLane.execute"))
    }

    @Test
    fun `process start makes no ffi call on main`() {
        // Application.onCreate -> LowDataMonitor.init -> publish was the process's first uniffi call,
        // so UniffiLib's class init (JNA registering every native) ran on main: "failed to complete
        // startup". The core call and the network registration must stay off the caller's thread.
        val ldm = File(src, "core/LowDataMonitor.kt").readText()
        val start = ldm.indexOf("private fun publish(resolved: LinkConstraint)")
        val body = block(ldm, ldm.indexOf('{', start))
        assertTrue("publish must hand the core call to its lane",
            body.contains("publishLane.execute") && !body.contains("setLinkConstraint("))
        val init = block(ldm, ldm.indexOf('{', ldm.indexOf("fun init(ctx: Context)")))
        assertTrue("network registration must run off main", init.contains("\"haven-link-monitor\""))
    }

    @Test
    fun `every core object holding compose state is initialized on main before composition`() {
        // The engine boots on its own thread from MainActivity.onCreate; an object it touches first
        // would create its Compose state after composition's snapshot and crash the launch.
        val stateCtor = Regex("""\bmutable(State|StateList|StateMap|IntState|LongState|FloatState|DoubleState)Of\b""")
        val objectDecl = Regex("""(?m)^(?:internal |private )?object (\w+)""")
        val missing = mutableListOf<String>()
        File(src, "core").listFiles { f -> f.extension == "kt" }!!.forEach { f ->
            val text = f.readText()
            if (!stateCtor.containsMatchIn(text)) return@forEach
            for (m in objectDecl.findAll(text)) {
                val name = m.groupValues[1]
                if (name != "ComposeStateHolders" && name !in ComposeStateHolders.CLASSES) missing += "${f.name}: $name"
            }
        }
        assertTrue("add these to ComposeStateHolders.CLASSES:\n" + missing.joinToString("\n"), missing.isEmpty())
        val main = File(src, "MainActivity.kt").readText()
        assertTrue("state holders must be initialized before the engine boot is queued",
            main.indexOf("ComposeStateHolders.initOnMain()") in 0 until main.indexOf("EngineBoot.background"))
    }
}
