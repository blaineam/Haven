package com.blaineam.haven.core

import android.content.Context
import org.json.JSONObject

/**
 * Members the user has EXPLICITLY removed from a circle. Recorded so the removal (a) propagates to the
 * user's OTHER devices via self-sync as intentional records — NOT inferred from a peer's absence — and
 * (b) survives an additive re-sync: [SelfSyncCoordinator] will not re-add anyone currently removed here
 * (anti-reinflation), and their posts/calls in that circle are filtered out.
 *
 * A removal is LAST-WRITER-WINS per entry (keyed "circleId|hex"): [removedAt] is when the member was
 * removed, [readdedAt] when they were deliberately re-added; a member is currently removed iff their
 * removal is NEWER than any re-add. Timestamps (unix ms) are the fix for the two ways this broke — a
 * fresh removal now always beats a stale "re-added elsewhere" record (removals sync + stick), and a
 * fresh re-add beats an old removal (a sibling's stale removal can't re-sever a friend you just
 * re-added). Published as `circle-removed:` / `circle-readd:` (8-byte LE ms), with the legacy
 * `removal:` = 1/0 kept for older peers. Mirrors iOS `ConnectionsStore` removedAt/readdedAt.
 */
object CircleRemovals {
    private const val PREFS = "haven.circleRemovals"
    private const val KEY_REMOVED_AT = "removedAt" // JSON: {"circleId|hex": ms}
    private const val KEY_READDED_AT = "readdedAt" // JSON: {"circleId|hex": ms}
    // Legacy grow-only sets (pre-LWW), read once to migrate.
    private const val KEY_LEGACY = "removed"
    private const val KEY_LEGACY_CLEARED = "cleared"
    private lateinit var appContext: Context

    private val removedAt = HashMap<String, Long>()
    private val readdedAt = HashMap<String, Long>()
    @Volatile private var loaded = false

    fun init(ctx: Context) { appContext = ctx.applicationContext; load() }
    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun nowMs() = System.currentTimeMillis()
    private fun key(circleId: String, hex: String) = "$circleId|${hex.lowercase()}"

    @Synchronized private fun load() {
        if (loaded) return
        readMap(KEY_REMOVED_AT, removedAt)
        readMap(KEY_READDED_AT, readdedAt)
        // One-time migration from the legacy bare sets → LWW timestamps. Old removals/clears carry no
        // time, so they land at ts=1 ("long ago") and any real, later action supersedes them.
        if (removedAt.isEmpty() && readdedAt.isEmpty()) {
            prefs.getStringSet(KEY_LEGACY, emptySet())?.forEach { removedAt[it] = 1L }
            prefs.getStringSet(KEY_LEGACY_CLEARED, emptySet())?.forEach { readdedAt[it] = 1L }
            if (removedAt.isNotEmpty() || readdedAt.isNotEmpty()) persist()
        }
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

    private fun isRemoved(k: String): Boolean = (removedAt[k] ?: 0L) > (readdedAt[k] ?: 0L)

    /** Every entry currently REMOVED (removal newer than any re-add), as "circleId|hex". */
    @Synchronized fun all(): Set<String> {
        load()
        return (removedAt.keys + readdedAt.keys).filter { isRemoved(it) }.toSet()
    }

    /** Every entry currently RE-ADDED (re-add newer than any removal), as "circleId|hex". Published as
     *  the legacy `removal:` = 0 compat record for pre-LWW peers. */
    @Synchronized fun allCleared(): Set<String> {
        load()
        return (removedAt.keys + readdedAt.keys).filter { !isRemoved(it) }.toSet()
    }

    /** Raw LWW timestamp maps for the self-sync export (`circle-removed:` / `circle-readd:`). */
    @Synchronized fun removedAtMap(): Map<String, Long> { load(); return HashMap(removedAt) }
    @Synchronized fun readdedAtMap(): Map<String, Long> { load(); return HashMap(readdedAt) }

    /** Mark a member REMOVED from a circle NOW (LWW — supersedes any older re-add). */
    @Synchronized fun add(circleId: String, hex: String) {
        if (hex.isBlank()) return
        load(); removedAt[key(circleId, hex)] = nowMs(); persist()
    }

    /** Currently removed from this circle? (removal newer than any re-add) */
    @Synchronized fun contains(circleId: String, hex: String): Boolean {
        load(); return isRemoved(key(circleId, hex))
    }

    /** Re-allow a member into a circle NOW (LWW — supersedes any older removal). ONLY on a deliberate
     *  re-add. Mirrors iOS `ConnectionsStore.clearCircleRemoval`. */
    @Synchronized fun remove(circleId: String, hex: String) {
        if (hex.isBlank()) return
        load(); readdedAt[key(circleId, hex)] = nowMs(); persist()
    }

    /** Apply a REMOTE removal timestamp (self-sync LWW), keeping the newer per key. Returns the post-merge
     *  verdict (true = currently removed). */
    @Synchronized fun mergeRemovedAt(k: String, ms: Long): Boolean {
        load()
        if (ms > (removedAt[k] ?: 0L)) { removedAt[k] = ms; persist() }
        return isRemoved(k)
    }
    @Synchronized fun mergeReaddedAt(k: String, ms: Long): Boolean {
        load()
        if (ms > (readdedAt[k] ?: 0L)) { readdedAt[k] = ms; persist() }
        return isRemoved(k)
    }

    /** The removed member hexes for one circle. */
    @Synchronized fun forCircle(circleId: String): Set<String> {
        load()
        val prefix = "$circleId|"
        return (removedAt.keys + readdedAt.keys)
            .asSequence()
            .filter { it.startsWith(prefix) && isRemoved(it) }
            .map { it.substringAfter("|") }
            .toSet()
    }

    /** True if [hex] is removed from ANY circle (used to hide their posts feed-wide). */
    @Synchronized fun isRemovedAnywhere(hex: String): Boolean {
        load()
        val suffix = "|${hex.lowercase()}"
        return (removedAt.keys + readdedAt.keys).any { it.endsWith(suffix) && isRemoved(it) }
    }

    @Synchronized fun clear() {
        removedAt.clear(); readdedAt.clear(); loaded = true
        runCatching { prefs.edit().clear().commit() }
    }
}
