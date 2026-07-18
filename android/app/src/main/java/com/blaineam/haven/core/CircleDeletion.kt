package com.blaineam.haven.core

import android.content.Context
import org.json.JSONObject

/**
 * LAST-WRITER-WINS deletion tombstone for whole circles / DM threads. Self-sync re-creates any circle
 * present in another device's slot (the `circle:` apply calls createCircle), so deleting a DM or circle
 * never stuck on a multi-device account — the sibling's copy resurrected it every sync. These timestamps
 * (keyed by circle id) make a deletion a real decision: [deletedAt] (when you deleted it) vs
 * [recreatedAt] (when it was explicitly re-made / re-opened); the newest wins. A circle is currently
 * deleted iff its deletion is newer than any re-creation. Published as `circle-deleted:` /
 * `circle-recreated:` (8-byte LE ms). Mirrors iOS `CircleDeletionStore`.
 */
object CircleDeletion {
    private const val PREFS = "haven.circleDeletion"
    private const val KEY_DELETED_AT = "deletedAt"
    private const val KEY_RECREATED_AT = "recreatedAt"
    private lateinit var appContext: Context

    private val deletedAt = HashMap<String, Long>()
    private val recreatedAt = HashMap<String, Long>()
    @Volatile private var loaded = false

    fun init(ctx: Context) { appContext = ctx.applicationContext; load() }
    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun nowMs() = System.currentTimeMillis()

    @Synchronized private fun load() {
        if (loaded) return
        readMap(KEY_DELETED_AT, deletedAt)
        readMap(KEY_RECREATED_AT, recreatedAt)
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
            .putString(KEY_DELETED_AT, JSONObject(deletedAt as Map<*, *>).toString())
            .putString(KEY_RECREATED_AT, JSONObject(recreatedAt as Map<*, *>).toString())
            .apply()
    }

    /** Currently deleted? (deletion newer than any re-creation) — the self-sync `circle:` apply skips these. */
    @Synchronized fun isDeleted(id: String): Boolean {
        load(); return (deletedAt[id] ?: 0L) > (recreatedAt[id] ?: 0L)
    }

    /** The user deleted this circle/DM NOW. */
    @Synchronized fun markDeleted(id: String) {
        if (id.isBlank()) return
        load(); deletedAt[id] = nowMs(); persist()
    }
    /** The circle/DM was explicitly (re-)created or re-opened NOW — lifts the deletion. */
    @Synchronized fun markRecreated(id: String) {
        if (id.isBlank()) return
        load(); recreatedAt[id] = nowMs(); persist()
    }

    @Synchronized fun deletedAtMap(): Map<String, Long> { load(); return HashMap(deletedAt) }
    @Synchronized fun recreatedAtMap(): Map<String, Long> { load(); return HashMap(recreatedAt) }

    /** Merge a remote deletion/recreation timestamp (self-sync LWW), keeping the newer per id. Returns the
     *  post-merge verdict (true = currently deleted). */
    @Synchronized fun mergeDeletedAt(id: String, ms: Long): Boolean {
        load()
        if (ms > (deletedAt[id] ?: 0L)) { deletedAt[id] = ms; persist() }
        return (deletedAt[id] ?: 0L) > (recreatedAt[id] ?: 0L)
    }
    @Synchronized fun mergeRecreatedAt(id: String, ms: Long): Boolean {
        load()
        if (ms > (recreatedAt[id] ?: 0L)) { recreatedAt[id] = ms; persist() }
        return (deletedAt[id] ?: 0L) > (recreatedAt[id] ?: 0L)
    }

    @Synchronized fun clear() {
        deletedAt.clear(); recreatedAt.clear(); loaded = true
        runCatching { prefs.edit().clear().apply() }
    }
}
