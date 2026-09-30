package com.blaineam.haven.core

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.blaineam.haven.BuildConfig
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Responsiveness counters for the QA dump's `perf` object (docs/QA.md). The key names are a
 * contract with the e2e orchestrator, shared with the Apple client — do not rename them.
 *
 * Android fills what it has a concept for: main-thread stalls (a DEBUG main-Looper watchdog) and
 * whole-state persist exports. The engine priority lane, feed-rebuild count, media-store-on-main
 * and held-ref index are Apple structures; those keys report 0 here so the schema stays identical.
 */
object QaPerf {
    private val lock = Any()
    private var mainStallCount = 0
    private var mainStallMaxMs = 0L
    private var persistExportCount = 0
    private var lastPersistExportAtMs = 0L

    private const val RING_CAP = 40
    /** "<startedAtMs> <reason>" of the last exports (Apple `recentExports` parity). */
    private val recentExports = ArrayDeque<String>()
    /** "<atMs> <source>" of the last inbound changes that owe a save (Apple `recentChanged`). */
    private val recentChanged = ArrayDeque<String>()

    private fun ring(q: ArrayDeque<String>, entry: String) {
        q.addLast(entry)
        while (q.size > RING_CAP) q.removeFirst()
    }

    /** A whole-state `exportState()` ran (HavenNet.persist and the legacy migration). */
    fun notePersistExport(startedAtMs: Long = System.currentTimeMillis(), reason: String = "persist") {
        val now = System.currentTimeMillis()
        synchronized(lock) {
            persistExportCount += 1
            lastPersistExportAtMs = now
            ring(recentExports, "$startedAtMs $reason")
        }
    }

    /** An inbound receive / hello really changed the engine — the save it owes is not idle churn. */
    fun noteInboundChange(source: String) {
        val now = System.currentTimeMillis()
        synchronized(lock) { ring(recentChanged, "$now $source") }
    }

    private fun noteMainStall(ms: Long) {
        if (ms < 100) return
        synchronized(lock) {
            mainStallCount += 1
            if (ms > mainStallMaxMs) mainStallMaxMs = ms
        }
    }

    fun reset() {
        synchronized(lock) {
            mainStallCount = 0; mainStallMaxMs = 0
            persistExportCount = 0; lastPersistExportAtMs = 0
            recentExports.clear(); recentChanged.clear()
            cpuSamples.clear(); cpuSampleTicks = 0; mainStallFrames.clear()
        }
    }

    // ---- where the CPU goes (DEBUG) ------------------------------------------------------------
    // The 2026-09-30 gate saw the app at 124 % CPU until the emulator's system_server hit its
    // watchdog, and a later launch with the main thread burning 10 s of CPU before the engine even
    // started — with nothing recorded to say on what. `adb shell debuggerd -j` needs root, so the
    // app samples itself: every 500 ms, every RUNNABLE thread's app-relevant top frames, counted.
    // Also, while a main-thread ping is overdue, the main thread's stack every 250 ms.

    private val cpuSamples = HashMap<String, Int>()
    private var cpuSampleTicks = 0
    private val mainStallFrames = HashMap<String, Int>()

    /** The frames that say what a thread is DOING: first app / engine frames, else the top. */
    internal fun stackKey(frames: Array<StackTraceElement>, depth: Int = 3): String? {
        if (frames.isEmpty()) return null
        val top = frames[0]
        val idle = listOf("nativePollOnce", "park", "wait", "sleep", "poll", "epoll", "accept", "read",
            "recvfrom", "socketRead", "select", "take", "await")
        if (top.isNativeMethod && idle.any { top.methodName.contains(it, ignoreCase = true) }) return null
        if (top.className.startsWith("java.lang.Object") && top.methodName == "wait") return null
        if (top.className.startsWith("jdk.internal.misc.Unsafe") || top.className.startsWith("sun.misc.Unsafe")) return null
        val app = frames.filter { it.className.startsWith("com.blaineam.") || it.className.startsWith("uniffi.") }
        val pick = (if (app.isNotEmpty()) app else frames.toList()).take(depth)
        return pick.joinToString(" < ") { "${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}" }
    }

    private fun bump(m: HashMap<String, Int>, k: String) { m[k] = (m[k] ?: 0) + 1 }

    private fun top(m: Map<String, Int>, n: Int): JSONObject {
        val o = JSONObject()
        for ((k, v) in m.entries.sortedByDescending { it.value }.take(n)) o.put(k, v)
        return o
    }

    private fun sampleCpu(self: Thread) {
        val all = runCatching { Thread.getAllStackTraces() }.getOrNull() ?: return
        synchronized(lock) {
            cpuSampleTicks++
            for ((t, frames) in all) {
                if (t === self || t.state != Thread.State.RUNNABLE) continue
                val k = stackKey(frames) ?: continue
                bump(cpuSamples, "${t.name.take(16)}: $k")
            }
            if (cpuSamples.size > 400) {   // bound the table: keep the heavy hitters
                val keep = cpuSamples.entries.sortedByDescending { it.value }.take(200).associate { it.key to it.value }
                cpuSamples.clear(); cpuSamples.putAll(keep)
            }
        }
    }

    fun snapshot(): JSONObject = synchronized(lock) {
        JSONObject()
            .put("mainStallCount", mainStallCount)
            .put("mainStallMaxMs", mainStallMaxMs)
            .put("engineUserWaitP95Ms", 0.0)
            .put("engineUserWaitMaxMs", 0.0)
            .put("persistExportCount", persistExportCount)
            .put("lastPersistExportAtMs", lastPersistExportAtMs)
            .put("refreshCount", 0)
            .put("mediaStoreOnMainCount", 0)
            .put("heldRefSetSize", 0)
            .put("recentExports", org.json.JSONArray(recentExports.toList()))
            .put("recentChanged", org.json.JSONArray(recentChanged.toList()))
            // Android-only diagnostics (not part of the shared contract): sampled busy stacks.
            .put("cpuSampleTicks", cpuSampleTicks)
            .put("cpuSamplesTop", top(cpuSamples, 12))
            .put("mainStallFramesTop", top(mainStallFrames, 8))
    }

    @Volatile private var watchdogStarted = false

    /**
     * DEBUG-only main-Looper watchdog: every 100 ms a background thread posts a ping to the main
     * Looper and measures how long it took to run — the same probe as Apple's
     * MainThreadStallDetector. One ping in flight at a time, so a long stall counts once. Paused
     * while the app is backgrounded (a stopped activity is not a blocked main thread): QaDriver's
     * onPause/onResume gate it.
     */
    fun startWatchdog() {
        if (!BuildConfig.DEBUG || watchdogStarted) return
        watchdogStarted = true
        val main = Handler(Looper.getMainLooper())
        Thread({
            while (true) {
                try { Thread.sleep(100) } catch (_: InterruptedException) { return@Thread }
                if (!foreground) continue
                val sentAt = SystemClock.uptimeMillis()
                val ping = CountDownLatch(1)
                main.post { ping.countDown() }
                // Bounded, so a torn-down looper can't park this thread forever. While the ping is
                // overdue, sample WHAT the main thread is doing (250 ms ticks, 30 s cap).
                var ran = false
                val mainThread = Looper.getMainLooper().thread
                while (SystemClock.uptimeMillis() - sentAt < 30_000) {
                    ran = try { ping.await(250, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { return@Thread }
                    if (ran) break
                    stackKey(mainThread.stackTrace, depth = 4)?.let { k -> synchronized(lock) { bump(mainStallFrames, k) } }
                }
                if (ran && foreground) noteMainStall(SystemClock.uptimeMillis() - sentAt)
            }
        }, "haven-qa-stall-watchdog").apply { isDaemon = true; priority = Thread.MIN_PRIORITY }.start()
        Thread({
            val self = Thread.currentThread()
            while (true) {
                try { Thread.sleep(500) } catch (_: InterruptedException) { return@Thread }
                if (foreground) sampleCpu(self)
            }
        }, "haven-qa-cpu-sampler").apply { isDaemon = true; priority = Thread.MIN_PRIORITY }.start()
    }

    @Volatile var foreground = false
}
