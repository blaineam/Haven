package com.blaineam.haven.core

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URLEncoder
import java.net.URL

/**
 * Song search + preview resolution via the free, unauthenticated iTunes Search API. Used to pick a
 * song in the composer AND to resolve a received post's song (by title+artist) to a 30s preview +
 * artwork on THIS device — so a song posted from iPhone still plays a preview on Android, with no
 * account, no SDK, no server. (Apple's terms: show the preview next to an Apple Music link.)
 */
object MusicSearch {
    data class Track(
        val title: String,
        val artist: String,
        val artworkUrl: String,
        val previewUrl: String,
        val storeUrl: String,
        val durationMs: Long,
    )

    /**
     * Resolved lookups, including MISSES (a null value) so an unresolvable song is asked about once
     * and not once per glance.
     *
     * Bounded and synchronized on purpose. The key is `title|artist` straight off a received post,
     * so its contents are peer-controlled: an unbounded map here grows with every distinct song any
     * member ever attaches, and the story viewer now resolves on every story watched. A 256-entry
     * LRU is far more than a session touches while making the ceiling explicit. Access is from IO
     * threads, so a bare HashMap was also a data race waiting to happen.
     */
    private const val CACHE_MAX = 256
    private val previewCache = object : LinkedHashMap<String, Track?>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: Map.Entry<String, Track?>) = size > CACHE_MAX
    }

    /** Search songs by free text. Returns up to [limit] results (blocking — call off-main). */
    fun search(query: String, limit: Int = 12): List<Track> {
        if (query.isBlank()) return emptyList()
        val term = URLEncoder.encode(query.trim(), "UTF-8")
        val url = "https://itunes.apple.com/search?term=$term&media=music&entity=song&limit=$limit"
        return parse(httpGet(url))
    }

    /** Resolve a song (e.g. from a received post) to a playable preview by title+artist. Cached. */
    fun resolve(title: String, artist: String): Track? {
        val key = "$title|$artist"
        synchronized(previewCache) { if (previewCache.containsKey(key)) return previewCache[key] }
        val q = listOf(title, artist).filter { it.isNotBlank() }.joinToString(" ")
        // Deliberately outside the lock: this is a network round trip, and holding the cache while
        // it runs would serialize every other resolver behind the slowest one.
        val t = search(q, limit = 1).firstOrNull()
        synchronized(previewCache) { previewCache[key] = t }
        return t
    }

    private fun parse(json: String?): List<Track> {
        json ?: return emptyList()
        return runCatching {
            val results = JSONObject(json).optJSONArray("results") ?: return emptyList()
            (0 until results.length()).mapNotNull { i ->
                val o = results.getJSONObject(i)
                val preview = o.optString("previewUrl")
                if (preview.isBlank()) return@mapNotNull null
                Track(
                    title = o.optString("trackName"),
                    artist = o.optString("artistName"),
                    // Bump the 100px artwork to a crisp 300px.
                    artworkUrl = o.optString("artworkUrl100").replace("100x100", "300x300"),
                    previewUrl = preview,
                    storeUrl = o.optString("trackViewUrl"),
                    durationMs = o.optLong("trackTimeMillis", 0),
                )
            }
        }.getOrDefault(emptyList())
    }

    private fun httpGet(url: String): String? = runCatching {
        val c = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 8000; readTimeout = 8000
            setRequestProperty("User-Agent", "Haven")
        }
        if (c.responseCode in 200..299) c.inputStream.use { it.readBytes().toString(Charsets.UTF_8) } else null
    }.getOrNull()
}
