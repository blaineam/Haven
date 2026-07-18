package com.blaineam.haven.core

import android.content.Context
import org.json.JSONObject

/**
 * LAST-WRITER-WINS contact-removal tombstone. Contacts sync ADDITIVE-ONLY (so a freshly-restored device
 * can't wipe the account), which means a delete never stuck on a multi-device account — a sibling's
 * `contact:` record silently re-added them every sync. These timestamps (keyed by account idHex) make a
 * removal a real, newest-wins decision: [removedAt] (when you removed them) vs [readdedAt] (when you
 * deliberately added them back); the newest wins. Published as `contact-removed:` / `contact-readd:`
 * (8-byte LE ms). Mirrors iOS `ContactsStore` contactRemovedAt/contactReaddedAt.
 */
object ContactRemovals {
    private const val PREFS = "haven.contactRemovals"
    private const val KEY_REMOVED_AT = "removedAt"
    private const val KEY_READDED_AT = "readdedAt"
    private lateinit var appContext: Context

    private val removedAt = HashMap<String, Long>()
    private val readdedAt = HashMap<String, Long>()
    @Volatile private var loaded = false

    fun init(ctx: Context) { appContext = ctx.applicationContext; load() }
    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun nowMs() = System.currentTimeMillis()

    @Synchronized private fun load() {
        if (loaded) return
        readMap(KEY_REMOVED_AT, removedAt)
        readMap(KEY_READDED_AT, readdedAt)
        loaded = true
    }

    private fun readMap(prefKey: String, into: HashMap<String, Long>) {
        into.clear()
        val raw = prefs.getString(prefKey, null) ?: return
        runCatching {
            val o = JSONObject(raw)
            for (k in o.keys()) into[k] = o.getLong(k)
        }
    }

    @Synchronized private fun persist() {
        prefs.edit()
            .putString(KEY_REMOVED_AT, JSONObject(removedAt as Map<*, *>).toString())
            .putString(KEY_READDED_AT, JSONObject(readdedAt as Map<*, *>).toString())
            .apply()
    }

    /** A contact currently removed (removal newer than any re-add) — must not be re-added by sync. */
    @Synchronized fun isRemoved(hex: String): Boolean {
        load(); return (removedAt[hex] ?: 0L) > (readdedAt[hex] ?: 0L)
    }

    /** The user removed this contact NOW (LWW). */
    @Synchronized fun markRemoved(hex: String) {
        if (hex.isBlank()) return
        load(); removedAt[hex] = nowMs(); persist()
    }
    /** A deliberate (re-)add lifts any removal NOW (LWW). */
    @Synchronized fun markReadded(hex: String) {
        if (hex.isBlank()) return
        load(); readdedAt[hex] = nowMs(); persist()
    }

    @Synchronized fun removedAtMap(): Map<String, Long> { load(); return HashMap(removedAt) }
    @Synchronized fun readdedAtMap(): Map<String, Long> { load(); return HashMap(readdedAt) }

    /** Apply a REMOTE removal/re-add timestamp (self-sync LWW), keeping the newer per hex. Returns the
     *  post-merge verdict (true = currently removed). */
    @Synchronized fun mergeRemovedAt(hex: String, ms: Long): Boolean {
        load()
        if (ms > (removedAt[hex] ?: 0L)) { removedAt[hex] = ms; persist() }
        return (removedAt[hex] ?: 0L) > (readdedAt[hex] ?: 0L)
    }
    @Synchronized fun mergeReaddedAt(hex: String, ms: Long): Boolean {
        load()
        if (ms > (readdedAt[hex] ?: 0L)) { readdedAt[hex] = ms; persist() }
        return (removedAt[hex] ?: 0L) > (readdedAt[hex] ?: 0L)
    }

    @Synchronized fun clear() {
        removedAt.clear(); readdedAt.clear(); loaded = true
        runCatching { prefs.edit().clear().apply() }
    }
}
