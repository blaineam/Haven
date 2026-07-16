package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableStateListOf

/**
 * DEVICE-LOCAL "keep on this device" set: media the user asked to retain here, exempt from EVERY
 * cleanup path — the orphan sweep, the age/size limit sweep, AND the "Manage media" screen marks it
 * ineligible for selection. It is NOT synced to other devices and NOT hoisted anywhere in the feed —
 * purely a local retention exemption. Refs are stored verbatim; callers union each ref's on-disk
 * storage keys into the sweep keep-set via [inUseKeys]. Mirrors iOS `PinnedMediaStore`.
 *
 * CRITICAL: [inUseKeys] MUST be unioned into BOTH the orphan-sweep in-use set (HavenNet.mediaInUseKeys)
 * AND the limit-sweep skip-set (LocalMedia.performLimitSweep pinnedKeys) — a pin a sweep ignores is a
 * data-loss bug.
 */
object PinnedMediaStore {
    private const val PREFS = "haven.mediapin"
    private const val KEY = "refs"
    private lateinit var appContext: Context

    /** Observable pinned refs — read from a @Composable (pinned count, row "Kept" state) to recompose. */
    val refs = mutableStateListOf<String>()

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        refs.clear()
        refs.addAll(prefs.getStringSet(KEY, emptySet()) ?: emptySet())
    }

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun persist() { prefs.edit().putStringSet(KEY, refs.toSet()).apply() }

    val count: Int get() = refs.size
    fun isPinned(ref: String): Boolean = refs.contains(ref)
    fun anyPinned(rs: List<String>): Boolean = rs.any { refs.contains(it) }

    fun pin(rs: List<String>) {
        var changed = false
        for (r in rs) if (!LocalMedia.isSynthetic(r) && !refs.contains(r)) { refs.add(r); changed = true }
        if (changed) persist()
    }

    fun unpin(rs: List<String>) {
        var changed = false
        for (r in rs) if (refs.remove(r)) changed = true
        if (changed) persist()
    }

    fun togglePin(rs: List<String>) { if (anyPinned(rs)) unpin(rs) else pin(rs) }

    /** On-disk storage keys of every pinned ref — unioned into the orphan-sweep and limit-sweep
     *  keep-sets so a pinned blob is never deleted, whatever its age/referencedness. */
    fun inUseKeys(): Set<String> {
        val s = HashSet<String>()
        for (r in refs) s.addAll(LocalMedia.normalizedKeys(r))
        return s
    }
}
