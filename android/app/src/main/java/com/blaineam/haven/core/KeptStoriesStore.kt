package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableIntStateOf
import org.json.JSONArray
import org.json.JSONObject
import uniffi.haven_ffi.TrackRefFfi

/**
 * Stories you chose to KEEP — held on your profile after the 24h story window closes.
 *
 * A story is an ordinary post with a 24h retention, so the event itself is purged on schedule
 * everywhere, for everyone. Keeping one therefore can't mean "stop it expiring": it means holding
 * your OWN snapshot of it, which is why this stores the story's content rather than a reference to
 * an event that is about to stop existing.
 *
 * Keep deliberately does NOT re-publish. It used to turn the story into a permanent post, which put
 * it back in the circle feed as a new thing everyone saw again — a different act from wanting to
 * hold on to it yourself. A kept story stays yours, on your profile, and still leaves the circle's
 * story row when its 24 hours are up (the tray reads the LIVE feed; only profile surfaces revive
 * kept snapshots).
 *
 * Keeping also PINS the media. Without that the blobs are reclaimed by the cleanup sweeps once the
 * event is gone and a kept story becomes a row of "no longer available" placeholders — kept in name
 * only.
 *
 * Mirrors iOS `KeptStoriesStore`; the sync wire format is byte-compatible with it.
 */
object KeptStoriesStore {
    private const val PREFS = "haven.stories.kept"
    private const val KEY = "kept"              // JSON array of Kept
    private const val REMOVED_KEY = "removed"   // JSON {id: unkept-at unix-ms}
    private lateinit var appContext: Context

    /** Bumped on every change so composables showing Keep/Kept state recompose. */
    val version = mutableIntStateOf(0)

    /**
     * One kept story. Music is FLATTENED rather than holding a [TrackRefFfi]: that is generated FFI
     * glue, not a storage format, and pinning a persisted format to it would break on the next
     * binding regeneration.
     */
    data class Kept(
        val id: String,             // the original event id, so a story is kept at most once
        val body: String,
        val media: List<String>,
        val createdAt: Long,
        /** When I kept it — the LWW clock for merging this entry against a sibling's tombstone.
         *  Nullable so records written before syncing existed still decode. */
        val keptAt: Long?,
        val musicCatalogId: String?,
        val musicTitle: String?,
        val musicArtist: String?,
        val musicArtworkUrl: String?,
        val musicDurationMs: Long?,
    ) {
        /** Rebuild the FFI track ref for playback, or null if this story had no song. */
        fun music(): TrackRefFfi? = musicCatalogId?.let {
            TrackRefFfi(
                catalogId = it,
                title = musicTitle ?: "",
                artist = musicArtist ?: "",
                artworkUrl = musicArtworkUrl ?: "",
                durationMs = (musicDurationMs ?: 0L).toULong(),
            )
        }
    }

    private val kept = ArrayList<Kept>()

    /** Un-kept story ids and WHEN. Absence is NOT removal — a lesson this codebase already paid for
     *  once, when additive-only self-sync silently resurrected deleted things. Without a tombstone a
     *  sibling's stale copy would quietly re-add every story you un-kept. */
    private val removed = HashMap<String, Long>()

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun nowMs(): Long = System.currentTimeMillis()

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        kept.clear(); removed.clear()
        prefs.getString(KEY, null)?.let { s -> runCatching { kept.addAll(decodeList(JSONArray(s))) } }
        prefs.getString(REMOVED_KEY, null)?.let { s ->
            runCatching {
                val o = JSONObject(s)
                for (k in o.keys()) removed[k] = o.getLong(k)
            }
        }
    }

    /** Every kept story, newest first. */
    fun all(): List<Kept> = kept.sortedByDescending { it.createdAt }

    fun isKept(id: String): Boolean = kept.any { it.id == id }

    /** Lookup a kept snapshot by original event id (DM story reply / deep link). */
    fun get(id: String): Kept? = kept.firstOrNull { it.id == id }

    /** Snapshot list for retroactive story-reply matching. */
    fun all(): List<Kept> = kept.toList()

    /**
     * Keep a story: snapshot it and PIN its media, so the blobs survive the cleanup sweeps that
     * would otherwise reclaim them once the event is gone.
     */
    fun keep(id: String, body: String, media: List<String>, createdAt: Long, music: TrackRefFfi?) {
        if (isKept(id)) return
        kept.add(
            Kept(
                id = id, body = body, media = media, createdAt = createdAt, keptAt = nowMs(),
                musicCatalogId = music?.catalogId, musicTitle = music?.title,
                musicArtist = music?.artist, musicArtworkUrl = music?.artworkUrl,
                musicDurationMs = music?.durationMs?.toLong(),
            )
        )
        removed.remove(id)   // re-keeping clears the tombstone
        PinnedMediaStore.pin(media)
        save()
    }

    /** Stop keeping it — and release the pin, so the blobs are eligible for cleanup again. */
    fun unkeep(id: String) {
        val i = kept.indexOfFirst { it.id == id }
        if (i < 0) return
        val media = kept[i].media
        kept.removeAt(i)
        removed[id] = nowMs()   // tombstone, so a sibling doesn't re-add it on the next sync
        unpinIfUnused(media)
        save()
    }

    fun toggle(id: String, body: String, media: List<String>, createdAt: Long, music: TrackRefFfi?) {
        if (isKept(id)) unkeep(id) else keep(id, body, media, createdAt, music)
    }

    /** Release pins for blobs no OTHER kept story still needs (a story shared twice shares refs). */
    private fun unpinIfUnused(media: List<String>) {
        val stillNeeded = kept.flatMap { it.media }.toHashSet()
        PinnedMediaStore.unpin(media.filter { it !in stillNeeded })
    }

    // ---- Self-sync (per-entry LWW, tombstoned) -------------------------------------------

    /** What to publish to my other devices, or null when there is nothing at all to say (never
     *  published empty, so a fresh device can't blank a sibling's collection). */
    fun toJsonBytes(): ByteArray? {
        if (kept.isEmpty() && removed.isEmpty()) return null
        val root = JSONObject()
        root.put("kept", encodeList(kept))
        val rem = JSONObject()
        for ((k, v) in removed) rem.put(k, v)
        root.put("removed", rem)
        return root.toString().toByteArray(Charsets.UTF_8)
    }

    /**
     * Merge a sibling's state. Per ENTRY, not wholesale: keeping story A on my phone and story B on
     * my tablet must end with BOTH kept, which a last-writer-wins collection swap would not do.
     *
     * Merge rules — an entry applies unless a NEWER tombstone exists for it, and a tombstone applies
     * unless the local copy was kept more recently. So re-keeping something later still wins in both
     * directions. Newly-arrived entries PIN their media, so a story kept on one device survives the
     * other's cleanup sweeps too.
     */
    fun applySyncedJson(bytes: ByteArray): Boolean {
        val root = runCatching { JSONObject(String(bytes, Charsets.UTF_8)) }.getOrNull() ?: return false
        var changed = false
        root.optJSONObject("removed")?.let { rem ->
            for (k in rem.keys()) {
                val ts = runCatching { rem.getLong(k) }.getOrNull() ?: continue
                if ((removed[k] ?: 0L) < ts) { removed[k] = ts; changed = true }
            }
        }
        for (entry in decodeList(root.optJSONArray("kept") ?: JSONArray())) {
            val entryAt = entry.keptAt ?: entry.createdAt
            if ((removed[entry.id] ?: 0L) > entryAt) continue   // un-kept more recently than kept
            val i = kept.indexOfFirst { it.id == entry.id }
            if (i >= 0) {
                if ((kept[i].keptAt ?: 0L) < entryAt) { kept[i] = entry; changed = true }
            } else {
                kept.add(entry); PinnedMediaStore.pin(entry.media); changed = true
            }
        }
        // Apply tombstones newer than my own copy.
        for ((id, ts) in removed) {
            val i = kept.indexOfFirst { it.id == id }
            if (i >= 0 && (kept[i].keptAt ?: 0L) < ts) {
                val media = kept[i].media
                kept.removeAt(i); unpinIfUnused(media); changed = true
            }
        }
        if (changed) save()
        return changed
    }

    /** Factory-reset this store. */
    fun wipe() {
        kept.clear(); removed.clear()
        prefs.edit().remove(KEY).remove(REMOVED_KEY).apply()
        version.intValue++
    }

    // ---- JSON (field names match iOS Codable exactly — this wire crosses platforms) -------

    private fun encodeList(list: List<Kept>): JSONArray {
        val arr = JSONArray()
        for (k in list) {
            val o = JSONObject()
            o.put("id", k.id)
            o.put("body", k.body)
            o.put("media", JSONArray(k.media))
            o.put("createdAt", k.createdAt)
            // Optionals are OMITTED when absent, matching Swift's JSONEncoder, so a record written
            // here round-trips through an Apple device unchanged.
            k.keptAt?.let { o.put("keptAt", it) }
            k.musicCatalogId?.let { o.put("musicCatalogId", it) }
            k.musicTitle?.let { o.put("musicTitle", it) }
            k.musicArtist?.let { o.put("musicArtist", it) }
            k.musicArtworkUrl?.let { o.put("musicArtworkUrl", it) }
            k.musicDurationMs?.let { o.put("musicDurationMs", it) }
            arr.put(o)
        }
        return arr
    }

    private fun decodeList(arr: JSONArray): List<Kept> {
        val out = ArrayList<Kept>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val id = o.optString("id").takeIf { it.isNotEmpty() } ?: continue
            val mediaArr = o.optJSONArray("media") ?: JSONArray()
            val media = (0 until mediaArr.length()).mapNotNull { mediaArr.optString(it).takeIf { s -> s.isNotEmpty() } }
            out.add(
                Kept(
                    id = id,
                    body = o.optString("body", ""),
                    media = media,
                    createdAt = o.optLong("createdAt", 0L),
                    keptAt = if (o.has("keptAt")) o.optLong("keptAt") else null,
                    musicCatalogId = o.optString("musicCatalogId").takeIf { it.isNotEmpty() },
                    musicTitle = o.optString("musicTitle").takeIf { it.isNotEmpty() },
                    musicArtist = o.optString("musicArtist").takeIf { it.isNotEmpty() },
                    musicArtworkUrl = o.optString("musicArtworkUrl").takeIf { it.isNotEmpty() },
                    musicDurationMs = if (o.has("musicDurationMs")) o.optLong("musicDurationMs") else null,
                )
            )
        }
        return out
    }

    private fun save() {
        // BOUND the tombstones: they only need to outlive a sibling being offline, not forever.
        if (removed.size > 500) {
            val newest = removed.entries.sortedByDescending { it.value }.take(250)
            removed.clear()
            for (e in newest) removed[e.key] = e.value
        }
        val rem = JSONObject()
        for ((k, v) in removed) rem.put(k, v)
        prefs.edit()
            .putString(KEY, encodeList(kept).toString())
            .putString(REMOVED_KEY, rem.toString())
            .apply()
        version.intValue++
    }
}
