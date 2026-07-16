package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableIntStateOf
import org.json.JSONObject

/**
 * Refs whose LOCAL blob was deliberately removed (a "Manage media" selection of a still-referenced
 * item, or the age/size limit sweep) while the EVENT still lives. The missing-media sweep must NOT
 * auto-refetch these — that would silently undo the space the user just freed — so they render as an
 * explicit "Download X MB" placeholder and re-download only on tap. Keyed by on-disk key / ref →
 * last-known bytes (for the placeholder label). DEVICE-LOCAL, persisted as JSON. Mirrors iOS
 * `EvictedMediaStore`.
 *
 * CRITICAL: [contains] MUST be checked in HavenNet.requestMissingMedia (skip evicted refs) or cleanup
 * is silently undone by auto-refetch.
 */
object EvictedMediaStore {
    private const val PREFS = "haven.mediaevicted"
    private const val KEY = "sizes"
    private lateinit var appContext: Context

    private val sizes = HashMap<String, Long>()

    /** Bumped on every mark/clear so a @Composable placeholder recomposes when its state changes. */
    val version = mutableIntStateOf(0)

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        sizes.clear()
        runCatching {
            val json = prefs.getString(KEY, null) ?: return@runCatching
            val o = JSONObject(json)
            for (k in o.keys()) sizes[k] = o.getLong(k)
        }
    }

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun persist() {
        val o = JSONObject()
        for ((k, v) in sizes) o.put(k, v)
        prefs.edit().putString(KEY, o.toString()).apply()
        version.intValue += 1
    }

    /** Matches on the ref itself AND its bare hash, so an event ref (`img_<hash>`) resolves an eviction
     *  recorded under a bare-hash on-disk key (cross-platform files) and vice-versa. */
    @Synchronized fun contains(ref: String): Boolean =
        sizes.containsKey(ref) || sizes.containsKey(LocalMedia.bareId(ref))

    @Synchronized fun size(ref: String): Long? = sizes[ref] ?: sizes[LocalMedia.bareId(ref)]

    @Synchronized fun mark(ref: String, bytes: Long) {
        sizes[ref] = bytes
        // Bound the map: drop the oldest half by iteration order if it grows unreasonably large.
        if (sizes.size > 8000) {
            val keep = sizes.entries.take(4000).associate { it.key to it.value }
            sizes.clear(); sizes.putAll(keep)
        }
        persist()
    }

    @Synchronized fun clear(ref: String) {
        var changed = sizes.remove(ref) != null
        if (sizes.remove(LocalMedia.bareId(ref)) != null) changed = true
        if (changed) persist()
    }
}
