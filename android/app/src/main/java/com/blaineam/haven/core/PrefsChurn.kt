package com.blaineam.haven.core

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.blaineam.haven.BuildConfig
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * DEBUG-only SharedPreferences write counter: logs, once a minute, how many REAL changes each prefs
 * file took and which keys moved (`PrefsChurn: writes/min haven.contacts=3 [relayNodes2=2 …]`).
 *
 * A change listener fires exactly when a commit/apply changed a value — the same condition under
 * which SharedPreferences rewrites and fsyncs the whole file — so the count is the disk-write rate
 * that `QueuedWork.waitToFinish()` makes main pay for at every service start and activity stop.
 * Without it the only evidence is the platform's occasional "Time required to fsync" histogram.
 */
object PrefsChurn {
    private const val TAG = "PrefsChurn"
    private const val PERIOD_MS = 60_000L

    /** Strong refs: SharedPreferences holds listeners weakly. */
    private val listeners = ConcurrentHashMap<String, SharedPreferences.OnSharedPreferenceChangeListener>()
    private val counts = ConcurrentHashMap<String, AtomicInteger>()   // "file\u0000key" → changes
    @Volatile private var started = false

    fun start(context: Context) {
        if (!BuildConfig.DEBUG || started) return
        started = true
        val app = context.applicationContext
        val t = Thread({
            while (true) {
                runCatching { track(app) }
                try { Thread.sleep(PERIOD_MS) } catch (_: InterruptedException) { return@Thread }
                runCatching { report() }
            }
        }, "haven-prefs-churn")
        t.isDaemon = true
        t.start()
    }

    /** Attach to every prefs file that exists now (re-scanned each period for new ones). */
    private fun track(app: Context) {
        val dir = File(app.applicationInfo.dataDir, "shared_prefs")
        val names = dir.listFiles()?.mapNotNull { f -> f.name.removeSuffix(".xml").takeIf { f.name.endsWith(".xml") } }.orEmpty()
        for (name in names) {
            if (listeners.containsKey(name)) continue
            val l = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
                counts.getOrPut("$name\u0000${key ?: "<cleared>"}") { AtomicInteger() }.incrementAndGet()
            }
            listeners[name] = l
            app.getSharedPreferences(name, Context.MODE_PRIVATE).registerOnSharedPreferenceChangeListener(l)
        }
    }

    private fun report() {
        val snap = HashMap<String, Int>()
        for ((k, v) in counts) { val n = v.getAndSet(0); if (n > 0) snap[k] = n }
        val line = summarize(snap)
        if (line.isNotEmpty()) Log.i(TAG, "writes/min $line")
    }

    /**
     * "file=total [key=n …]" per file, busiest first. A listener sees one callback per changed KEY,
     * so a file's disk writes are at most its total (one apply() can change several keys at once).
     */
    fun summarize(perFileKey: Map<String, Int>): String {
        val byFile = perFileKey.entries.groupBy({ it.key.substringBefore('\u0000') }, { it.key.substringAfter('\u0000') to it.value })
        return byFile.entries
            .map { (file, keys) -> Triple(file, keys.sumOf { it.second }, keys.sortedByDescending { it.second }) }
            .sortedByDescending { it.second }
            .joinToString(" ") { (file, total, keys) ->
                "$file=$total [" + keys.joinToString(" ") { "${it.first}=${it.second}" } + "]"
            }
    }
}
