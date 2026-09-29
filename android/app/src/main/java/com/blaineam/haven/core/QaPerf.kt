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

    /** A whole-state `exportState()` ran (HavenNet.persist and the legacy migration). */
    fun notePersistExport() {
        val now = System.currentTimeMillis()
        synchronized(lock) {
            persistExportCount += 1
            lastPersistExportAtMs = now
        }
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
                // Bounded, so a torn-down looper can't park this thread forever.
                val ran = try { ping.await(30, TimeUnit.SECONDS) } catch (_: InterruptedException) { return@Thread }
                if (ran && foreground) noteMainStall(SystemClock.uptimeMillis() - sentAt)
            }
        }, "haven-qa-stall-watchdog").apply { isDaemon = true; priority = Thread.MIN_PRIORITY }.start()
    }

    @Volatile var foreground = false
}
