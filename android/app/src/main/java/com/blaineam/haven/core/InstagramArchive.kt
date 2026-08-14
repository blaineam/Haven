package com.blaineam.haven.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.zip.ZipFile

/**
 * Reads an Instagram "Download your information" export (JSON format) and turns it into the list of
 * posts Haven should author. Parsing only — no staging, no publishing, no side effects — so the
 * import preview can show exactly what is about to be published before anything happens.
 *
 * Apple parity: `InstagramArchive.swift`. The traps encoded here were found against a real 1.28 GB
 * export and cost a debugging cycle each, so they are worth restating rather than discovering twice.
 *
 * Unlike Apple, this needs no ZIP reader of its own — `java.util.zip.ZipFile` is random-access
 * already, so an entry is read by seeking to it rather than by holding the archive in memory.
 */
object InstagramArchive {

    enum class Kind { POST, REEL, STORY }

    data class Item(
        val kind: Kind,
        /** Original capture time in MILLISECONDS (Instagram exports seconds — converted here). */
        val createdAt: Long,
        val body: String,
        /** Zip entry names, in album order. A carousel keeps all its photos in ONE item. */
        val mediaNames: List<String>,
        /** The only music signal an export carries — a genre list, and only on some videos. */
        val musicGenre: String?,
    )

    data class Summary(
        val items: List<Item>,
        val mediaCount: Int,
        val totalBytes: Long,
        val missing: List<String>,
    ) {
        fun count(k: Kind) = items.count { it.kind == k }
        val earliest: Long? get() = items.minOfOrNull { it.createdAt }
        val latest: Long? get() = items.maxOfOrNull { it.createdAt }
    }

    class Failure(val kind: Reason) : Exception() {
        enum class Reason { UNREADABLE, HTML_EXPORT, NO_CONTENT }
    }

    // ---- Entry point ---------------------------------------------------------------------------

    fun read(file: File): Summary {
        val zip = runCatching { ZipFile(file) }.getOrNull() ?: throw Failure(Failure.Reason.UNREADABLE)
        zip.use { z ->
            val names = z.entries().asSequence().map { it.name }.toSet()
            // An HTML export contains no `your_instagram_activity/media/*.json` at all. Detecting it
            // by its own shape gives the user the one instruction that actually fixes it.
            val hasJson = names.any { it.startsWith("your_instagram_activity/") && it.endsWith(".json") }
            if (!hasJson) {
                throw Failure(if (names.any { it.endsWith(".html") }) Failure.Reason.HTML_EXPORT
                              else Failure.Reason.UNREADABLE)
            }

            val items = (posts(z) + stories(z) + reels(z))
                .filter { it.createdAt > 0 }
                // Deterministic, not merely sorted: a resumed import skips by INDEX, so two runs
                // over one archive must produce the same sequence. The media name breaks ties.
                .sortedWith(compareBy({ it.createdAt }, { it.mediaNames.firstOrNull() ?: "" }))
            if (items.isEmpty()) throw Failure(Failure.Reason.NO_CONTENT)

            val sizes = z.entries().asSequence().associate { it.name to it.size }
            val missing = mutableListOf<String>()
            var bytes = 0L
            var count = 0
            for (i in items) for (n in i.mediaNames) {
                count++
                val s = sizes[n]
                if (s == null) missing.add(n) else bytes += s
            }
            return Summary(items, count, bytes, missing)
        }
    }

    // ---- Sources -------------------------------------------------------------------------------

    /**
     * `posts.json` is AUTHORITATIVE — deliberately not `posts_1.json`.
     *
     * `posts_1.json` is the easier parse and a strict SUBSET: on the validation archive it carried
     * 851 media names against posts.json's 979, so reading it silently drops 128 photos. posts.json
     * also carries the `Draft` flag, the only way to avoid republishing something never published.
     */
    private fun posts(z: ZipFile): List<Item> {
        val arr = readJsonArray(z, "your_instagram_activity/media/posts.json") ?: return emptyList()
        val out = mutableListOf<Item>()
        for (i in 0 until arr.length()) {
            val entry = arr.optJSONObject(i) ?: continue
            var draft = false
            entry.optJSONArray("label_values")?.let { lvs ->
                for (j in 0 until lvs.length()) {
                    val lv = lvs.optJSONObject(j) ?: continue
                    if (lv.optString("label") == "Draft" &&
                        lv.optString("value").equals("true", ignoreCase = true)) draft = true
                }
            }
            if (draft) continue

            // Album members are NESTED. Only the carousel COVER sits under the top-level "Media"
            // label; photos 2..N hang off a nested dict chain, so taking the label alone truncates
            // every carousel to one image (372 media instead of 1129 on the validation archive).
            val media = collectMedia(entry)
            if (media.isEmpty()) continue
            val created = entry.optLong("timestamp").takeIf { it > 0 }
                ?: media.first().optLong("creation_timestamp")
            val body = igText(entry.optString("title")).ifBlank { igText(media.first().optString("title")) }
            out.add(Item(Kind.POST, created * 1000, body,
                         media.mapNotNull { it.optString("uri").takeIf { u -> u.isNotBlank() } },
                         media.firstNotNullOfOrNull { genre(it) }))
        }
        return out
    }

    private fun stories(z: ZipFile): List<Item> {
        val obj = readJsonObject(z, "your_instagram_activity/media/stories.json") ?: return emptyList()
        val arr = obj.optJSONArray("ig_stories") ?: return emptyList()
        return (0 until arr.length()).mapNotNull { i ->
            val m = arr.optJSONObject(i) ?: return@mapNotNull null
            val uri = m.optString("uri").takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val ts = m.optLong("creation_timestamp").takeIf { it > 0 } ?: return@mapNotNull null
            Item(Kind.STORY, ts * 1000, igText(m.optString("title")), listOf(uri), genre(m))
        }
    }

    private fun reels(z: ZipFile): List<Item> {
        val obj = readJsonObject(z, "your_instagram_activity/media/reels.json") ?: return emptyList()
        val arr = obj.optJSONArray("ig_reels_media") ?: return emptyList()
        val out = mutableListOf<Item>()
        for (i in 0 until arr.length()) {
            val media = arr.optJSONObject(i)?.optJSONArray("media") ?: continue
            for (j in 0 until media.length()) {
                val m = media.optJSONObject(j) ?: continue
                val uri = m.optString("uri").takeIf { it.isNotBlank() } ?: continue
                val ts = m.optLong("creation_timestamp").takeIf { it > 0 } ?: continue
                out.add(Item(Kind.REEL, ts * 1000, igText(m.optString("title")), listOf(uri), genre(m)))
            }
        }
        return out
    }

    // ---- Shape helpers -------------------------------------------------------------------------

    /**
     * Recursively gather every media object under an entry, in first-seen order, deduped by uri.
     * Subtitle sidecars (.srt/.vtt) are companions of a video, not post media.
     */
    private fun collectMedia(root: Any?): List<JSONObject> {
        val out = mutableListOf<JSONObject>()
        val seen = mutableSetOf<String>()
        fun walk(o: Any?) {
            when (o) {
                is JSONObject -> {
                    val uri = o.optString("uri")
                    if (uri.isNotBlank() && !uri.endsWith(".srt") && !uri.endsWith(".vtt") && seen.add(uri)) {
                        out.add(o)
                    }
                    for (k in o.keys()) walk(o.opt(k))
                }
                is JSONArray -> for (i in 0 until o.length()) walk(o.opt(i))
            }
        }
        walk(root)
        return out
    }

    private fun genre(m: JSONObject): String? =
        m.optJSONObject("media_metadata")?.optJSONObject("video_metadata")
            ?.optString("music_genre")?.takeIf { it.isNotBlank() }

    /**
     * Instagram double-encodes captions: real UTF-8 bytes re-emitted as latin-1, so "Peña" arrives
     * as "PeÃ±a". Round-tripping through latin-1 restores it; anything already clean is unchanged.
     */
    fun igText(s: String?): String {
        if (s.isNullOrEmpty()) return ""
        return runCatching {
            String(s.toByteArray(Charsets.ISO_8859_1), Charsets.UTF_8)
        }.getOrDefault(s)
    }

    private fun readJsonArray(z: ZipFile, name: String): JSONArray? =
        readText(z, name)?.let { runCatching { JSONArray(it) }.getOrNull() }

    private fun readJsonObject(z: ZipFile, name: String): JSONObject? =
        readText(z, name)?.let { runCatching { JSONObject(it) }.getOrNull() }

    private fun readText(z: ZipFile, name: String): String? {
        val entry = z.getEntry(name) ?: return null
        return runCatching { z.getInputStream(entry).bufferedReader().use { it.readText() } }.getOrNull()
    }
}
