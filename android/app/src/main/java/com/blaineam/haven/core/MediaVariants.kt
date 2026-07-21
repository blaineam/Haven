package com.blaineam.haven.core

/**
 * Wire markers for video posters and original companions — parity with Apple `MediaVariants`
 * and `haven_p2p::mediavariants`.
 */
object MediaVariants {
    fun posterMarker(video: String, poster: String) = "poster:$video:$poster"
    fun originalMarker(optimized: String, original: String) = "orig:$optimized:$original"

    fun parsePoster(ref: String): Pair<String, String>? {
        if (!ref.startsWith("poster:")) return null
        val rest = ref.removePrefix("poster:")
        val i = rest.lastIndexOf(':')
        if (i <= 0 || i >= rest.length - 1) return null
        return rest.substring(0, i) to rest.substring(i + 1)
    }

    fun parseOriginal(ref: String): Pair<String, String>? {
        if (!ref.startsWith("orig:")) return null
        val rest = ref.removePrefix("orig:")
        val i = rest.lastIndexOf(':')
        if (i <= 0 || i >= rest.length - 1) return null
        return rest.substring(0, i) to rest.substring(i + 1)
    }

    fun posterFor(video: String, media: List<String>): String? =
        media.mapNotNull { parsePoster(it) }.firstOrNull { it.first == video }?.second

    fun allOriginals(media: List<String>): List<String> =
        media.mapNotNull { parseOriginal(it)?.second }

    fun displayRefs(media: List<String>): List<String> {
        val originals = allOriginals(media).toSet()
        return media.filter {
            parsePoster(it) == null && parseOriginal(it) == null && it !in originals
        }
    }

    fun dataSaverPrefetchRefs(media: List<String>): List<String> {
        val display = displayRefs(media)
        val posters = media.mapNotNull { parsePoster(it)?.second }.toSet()
        val out = ArrayList<String>()
        for (r in display) {
            when {
                r in posters -> out.add(r)
                r.startsWith("img_") || r.startsWith("i:") ||
                    r.startsWith("aud_") || r.startsWith("a:") ||
                    r.startsWith("file_") -> out.add(r)
                else -> posterFor(r, media)?.let { out.add(it) }
            }
        }
        for (p in posters) if (p !in out) out.add(p)
        return out
    }

    fun composeVideoMedia(poster: String?, optimized: String, original: String?): List<String> {
        val out = ArrayList<String>()
        if (!poster.isNullOrEmpty()) {
            out.add(poster)
            out.add(posterMarker(optimized, poster))
        }
        out.add(optimized)
        if (!original.isNullOrEmpty() && original != optimized) {
            out.add(original)
            out.add(originalMarker(optimized, original))
        }
        return out
    }
}
