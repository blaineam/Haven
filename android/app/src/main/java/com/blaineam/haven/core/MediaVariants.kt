package com.blaineam.haven.core

/**
 * Wire markers for video posters and original companions — parity with Apple `MediaVariants`
 * and `haven_p2p::mediavariants`.
 */
object MediaVariants {
    fun posterMarker(video: String, poster: String) = "poster:$video:$poster"
    fun originalMarker(optimized: String, original: String) = "orig:$optimized:$original"

    /** `thumb:<contentRef>:<thumbRef>` — a tiny (~256px, ≤32KB) preview companion for a photo.
     *  Joins the SIGNED media list at post time (same pattern as `poster:`), so old clients simply
     *  ignore it. The bare thumb ref is deliberately NOT listed — receivers learn it from the
     *  marker, so a legacy carousel never shows a duplicate tiny slide. Apple parity. */
    fun thumbMarker(content: String, thumb: String) = "thumb:$content:$thumb"

    fun parseThumb(ref: String): Pair<String, String>? {
        if (!ref.startsWith("thumb:")) return null
        val rest = ref.removePrefix("thumb:")
        val i = rest.lastIndexOf(':')
        if (i <= 0 || i >= rest.length - 1) return null
        return rest.substring(0, i) to rest.substring(i + 1)
    }

    /** Thumb companion for a content ref, if the post/DM declared one. */
    fun thumbFor(content: String, media: List<String>): String? =
        media.mapNotNull { parseThumb(it) }.firstOrNull { it.first == content }?.second

    /** Every thumb image ref declared in the list (prefetched everywhere — tiny by contract). */
    fun allThumbs(media: List<String>): List<String> =
        media.mapNotNull { parseThumb(it)?.second }

    /** The relay-upload order for a media list's fetchable refs: thumbs first (tiny, unblock the
     *  placeholder), then posters, then everything else in list order. Markers dropped. */
    fun uploadOrder(media: List<String>): List<String> {
        val thumbs = allThumbs(media).toSet()
        val posters = media.mapNotNull { parsePoster(it)?.second }.toSet()
        fun rank(r: String) = when {
            r in thumbs -> 0
            r in posters -> 1
            else -> 2
        }
        // Keep list order within a rank (stable sort) and skip markers — a ':' at index > 1 is a
        // synthetic scheme (mirror of LocalMedia.isSynthetic, inlined so this file stays test-only).
        return media.filter { r -> r.indexOf(':') <= 1 }.sortedBy { rank(it) }
    }

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

    /**
     * Refs to show in a carousel. Drops markers, original companions, and **poster stills that
     * belong to a video** — the poster rides with the video page as its still (super data saver
     * shows still + play until the user taps to download). A separate poster slide made the first
     * page a dead image: tap zoomed the still and never pulled the video.
     */
    fun displayRefs(media: List<String>): List<String> {
        val originals = allOriginals(media).toSet()
        val posterImages = media.mapNotNull { parsePoster(it)?.second }.toSet()
        val thumbImages = allThumbs(media).toSet()
        return media.filter {
            parsePoster(it) == null && parseOriginal(it) == null && parseThumb(it) == null &&
                it !in originals && it !in posterImages && it !in thumbImages
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
        // Thumbs are ≤32KB by contract — always worth fetching, data saver included.
        for (t in allThumbs(media)) if (t !in out) out.add(t)
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

    /**
     * Rewrite a media array after re-optimize (Apple/Rust parity).
     *
     * @param swap old content ref → new content ref (re-encoded stills/videos)
     * @param posters **old** video ref → poster image ref to attach or replace.
     *   Poster-only work uses this with an empty [swap] so already-compressed clips still get a
     *   published still for super data saver without a pointless re-encode.
     */
    fun rewriteMedia(
        media: List<String>,
        swap: Map<String, String>,
        posters: Map<String, String>,
    ): List<String> {
        val dropPosterImages = HashSet<String>()
        for (oldVideo in posters.keys) {
            posterFor(oldVideo, media)?.let { dropPosterImages.add(it) }
        }
        val out = ArrayList<String>()
        val emittedPosterFor = HashSet<String>()
        for (ref in media) {
            val posterPair = parsePoster(ref)
            if (posterPair != null) {
                val (v, p) = posterPair
                if (posters.containsKey(v)) continue
                out.add(posterMarker(swap[v] ?: v, swap[p] ?: p))
                continue
            }
            val origPair = parseOriginal(ref)
            if (origPair != null) {
                val (opt, orig) = origPair
                out.add(originalMarker(swap[opt] ?: opt, swap[orig] ?: orig))
                continue
            }
            if (ref in dropPosterImages) continue
            val newRef = swap[ref] ?: ref
            val posterImg = posters[ref]
            if (posterImg != null && emittedPosterFor.add(ref)) {
                if (posterImg !in out) out.add(posterImg)
                out.add(posterMarker(newRef, posterImg))
                out.add(newRef)
            } else {
                out.add(newRef)
            }
        }
        return out
    }
}
