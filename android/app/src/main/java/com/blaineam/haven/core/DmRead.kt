package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableIntStateOf
import org.json.JSONObject

/**
 * Per-conversation read watermarks for DMs — the basis for unread badges. A message is unread
 * when it's inbound, not unsent, and newer than its conversation's watermark; only actually
 * viewing the thread advances the watermark. Watermarks are monotonic (only ever move forward),
 * which makes the cross-device merge trivial and safe: per-key MAX via the `setting:dmLastRead`
 * self-sync key (JSON map circleId → unix-ms, the iOS wire format) — reading a thread on the
 * phone clears its badge on every other device, and no device can ever "un-read" another.
 * Mirrors iOS `DMReadStore`.
 */
object DmRead {
    private const val PREFS = "haven.dm"
    private const val KEY = "lastRead"            // JSON {circleId: unix-ms watermark}
    private const val SEED_KEY = "lastRead.seededAt"
    private lateinit var appContext: Context

    /** Bumped on every watermark change so composables showing unread counts recompose. */
    val version = mutableIntStateOf(0)

    private val lastRead = HashMap<String, Long>()

    /** Watermark for conversations with no entry yet. Stamped ONCE at first run so the day this
     *  feature ships, pre-existing history doesn't light every conversation up as unread — only
     *  messages that arrive after the seed (or after the last real read) badge. */
    private var seededAt: Long = 0L

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        lastRead.clear()
        prefs.getString(KEY, null)?.let { s ->
            runCatching {
                val o = JSONObject(s)
                for (k in o.keys()) lastRead[k] = o.getLong(k)
            }
        }
        if (!prefs.contains(SEED_KEY)) prefs.edit().putLong(SEED_KEY, System.currentTimeMillis()).apply()
        seededAt = prefs.getLong(SEED_KEY, 0L)
    }

    fun watermark(circleId: String): ULong = (lastRead[circleId] ?: seededAt).toULong()

    /** Advance a conversation's watermark to "now or the newest visible message, whichever is
     *  later". Taking the message time into account absorbs sender clock skew — a message stamped
     *  slightly in our future would otherwise stay "unread" forever. */
    fun markRead(circleId: String, newestMessageAt: ULong = 0UL) {
        val mark = maxOf(System.currentTimeMillis(), newestMessageAt.toLong())
        if (mark <= (lastRead[circleId] ?: 0L)) return
        lastRead[circleId] = mark
        persist()
        version.intValue++
        // A LOCAL read — nudge a debounced forced self-sync so the badge clears on my other
        // devices in seconds (applySyncedJson, the remote path, never lands here).
        HavenNet.selfSyncNudge()
    }

    /** The full map as `setting:dmLastRead` bytes (iOS-compatible JSON), or null when empty —
     *  never published empty, so a fresh device can't blank a sibling's map. */
    fun toJsonBytes(): ByteArray? {
        if (lastRead.isEmpty()) return null
        val o = JSONObject()
        for ((k, v) in lastRead) o.put(k, v)
        return o.toString().toByteArray(Charsets.UTF_8)
    }

    /** Merge watermarks synced from my other devices: per-key MAX (monotonic — always safe).
     *  Returns true if anything changed locally. */
    fun applySyncedJson(bytes: ByteArray): Boolean {
        val o = runCatching { JSONObject(String(bytes, Charsets.UTF_8)) }.getOrNull() ?: return false
        var changed = false
        for (k in o.keys()) {
            val v = runCatching { o.getLong(k) }.getOrNull() ?: continue
            if (v > (lastRead[k] ?: 0L)) { lastRead[k] = v; changed = true }
        }
        if (changed) { persist(); version.intValue++ }
        return changed
    }

    /** Factory-reset this store. */
    fun wipe() {
        lastRead.clear()
        prefs.edit().remove(KEY).remove(SEED_KEY).apply()
        seededAt = 0L
        version.intValue++
    }

    private fun persist() {
        val o = JSONObject()
        for ((k, v) in lastRead) o.put(k, v)
        prefs.edit().putString(KEY, o.toString()).apply()
    }
}
