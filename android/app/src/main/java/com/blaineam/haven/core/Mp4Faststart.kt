package com.blaineam.haven.core

import java.nio.ByteBuffer

/**
 * Move an MP4's `moov` atom in front of its media data — what Apple gets for free from
 * `AVAssetWriter.shouldOptimizeForNetworkUse` and what [android.media.MediaMuxer] has no API for.
 *
 * ## Why it matters here
 *
 * `moov` is the index: track tables, sample sizes, timing, and the byte offset of every chunk.
 * A player cannot start until it has read `moov`. `MediaMuxer` writes it LAST, because it does not
 * know the final sample tables until it has written every sample — so a Haven-transcoded clip has
 * its index at the very end of the file. Over a network that means a recipient streaming the blob
 * must fetch the whole thing before the first frame renders. Locally it is invisible; across a
 * relay it is the difference between "plays" and "spins".
 *
 * ## What this does
 *
 * Rewrites the top-level box order to `ftyp, moov, <everything else in original order>` and fixes
 * up the chunk-offset tables, which store ABSOLUTE file offsets and therefore all move by exactly
 * the size of the relocated `moov`.
 *
 * Deliberately pure JVM — no Android framework types — so it is covered by a real unit test in the
 * `testDebugUnitTest` gate rather than only by instrumentation. Byte surgery on a container format
 * is exactly the kind of code that should not first run on a user's video.
 *
 * Conservative by construction: ANY structure it does not fully understand makes it return null,
 * and the caller keeps the muxer's original bytes. A file that streams slightly worse is a
 * non-event; a corrupted one is unplayable media in someone's feed.
 */
object Mp4Faststart {

    /** Boxes whose payload is a sequence of child boxes, on the path from `moov` to `stco`/`co64`. */
    private val CONTAINERS = setOf("moov", "trak", "mdia", "minf", "stbl", "edts", "udta")

    private data class Box(val type: String, val start: Int, val size: Int) {
        val end get() = start + size
    }

    /**
     * @return the reordered file, or null if it is already faststart or cannot be safely rewritten.
     */
    fun relocate(src: ByteArray): ByteArray? = runCatching { rewrite(src) }.getOrNull()

    private fun rewrite(src: ByteArray): ByteArray? {
        val top = topLevelBoxes(src) ?: return null
        val moovIdx = top.indexOfFirst { it.type == "moov" }
        if (moovIdx < 0) return null
        val mdatIdx = top.indexOfFirst { it.type == "mdat" }
        if (mdatIdx < 0) return null
        // Already indexed-first: nothing to win, and rewriting would only risk breaking it.
        if (moovIdx < mdatIdx) return null

        val moov = top[moovIdx]
        // Only the ordinary shape is handled: moov sits AFTER the media data, so every chunk offset
        // moves forward by exactly the size of moov. An exotic layout (moov wedged between two mdats)
        // would need per-box deltas — bail rather than guess.
        if (top.any { it.type == "mdat" && it.start > moov.start }) return null

        val moovBytes = src.copyOfRange(moov.start, moov.end)
        if (!shiftChunkOffsets(moovBytes, moov.size)) return null

        val out = ByteArray(src.size)
        var w = 0
        // ftyp must stay first if present — it declares the brand before anything else is parsed.
        top.firstOrNull { it.type == "ftyp" }?.let {
            src.copyInto(out, w, it.start, it.end); w += it.size
        }
        moovBytes.copyInto(out, w); w += moovBytes.size
        for (b in top) {
            if (b.type == "ftyp" || b.type == "moov") continue
            src.copyInto(out, w, b.start, b.end); w += b.size
        }
        // Total length must be preserved exactly; anything else means a box was dropped or doubled.
        return if (w == src.size) out else null
    }

    /** Flat walk of the top-level boxes. Null if the file is truncated or a size is nonsensical. */
    private fun topLevelBoxes(src: ByteArray): List<Box>? {
        val boxes = ArrayList<Box>()
        var p = 0
        while (p + 8 <= src.size) {
            var size = readU32(src, p).toInt()
            val type = String(src, p + 4, 4, Charsets.US_ASCII)
            when {
                // size==1 → the real size is a 64-bit largesize after the type.
                size == 1 -> {
                    if (p + 16 > src.size) return null
                    val large = readU64(src, p + 8)
                    if (large > Int.MAX_VALUE.toLong()) return null   // >2 GB: not our media
                    size = large.toInt()
                }
                // size==0 → box runs to end of file.
                size == 0 -> size = src.size - p
            }
            if (size < 8 || p + size > src.size) return null
            boxes.add(Box(type, p, size))
            p += size
        }
        return if (p == src.size && boxes.isNotEmpty()) boxes else null
    }

    /**
     * Add [delta] to every entry of every `stco`/`co64` inside [moov], walking the container tree
     * rather than scanning for the four-char codes — a blind scan would happily "patch" four bytes
     * of sample data that happened to spell `stco`.
     *
     * @return false if anything is malformed, in which case the caller must abandon the rewrite.
     */
    private fun shiftChunkOffsets(moov: ByteArray, delta: Int): Boolean {
        var ok = true
        fun walk(from: Int, to: Int) {
            var p = from
            while (p + 8 <= to) {
                var size = readU32(moov, p).toInt()
                val type = String(moov, p + 4, 4, Charsets.US_ASCII)
                var header = 8
                if (size == 1) {
                    if (p + 16 > to) { ok = false; return }
                    val large = readU64(moov, p + 8)
                    if (large > Int.MAX_VALUE.toLong()) { ok = false; return }
                    size = large.toInt(); header = 16
                } else if (size == 0) {
                    size = to - p
                }
                if (size < header || p + size > to) { ok = false; return }
                when {
                    type in CONTAINERS -> walk(p + header, p + size)
                    type == "stco" || type == "co64" -> {
                        // FullBox: version(1) + flags(3), then entry_count(4), then the entries.
                        val base = p + header + 4
                        if (base + 4 > p + size) { ok = false; return }
                        val count = readU32(moov, base).toInt()
                        val wide = type == "co64"
                        val stride = if (wide) 8 else 4
                        val first = base + 4
                        if (count < 0 || first + count.toLong() * stride > (p + size).toLong()) { ok = false; return }
                        for (i in 0 until count) {
                            val at = first + i * stride
                            if (wide) {
                                writeU64(moov, at, readU64(moov, at) + delta)
                            } else {
                                val v = readU32(moov, at) + delta
                                // A 32-bit table that would overflow needs promotion to co64, which is a
                                // structural change (box grows, every offset shifts again). Refuse.
                                if (v > 0xFFFF_FFFFL) { ok = false; return }
                                writeU32(moov, at, v)
                            }
                        }
                    }
                }
                p += size
            }
        }
        // Start inside moov's own header.
        walk(8, moov.size)
        return ok
    }

    private fun readU32(b: ByteArray, p: Int): Long =
        ((b[p].toLong() and 0xFF) shl 24) or ((b[p + 1].toLong() and 0xFF) shl 16) or
            ((b[p + 2].toLong() and 0xFF) shl 8) or (b[p + 3].toLong() and 0xFF)

    private fun readU64(b: ByteArray, p: Int): Long = ByteBuffer.wrap(b, p, 8).long

    private fun writeU32(b: ByteArray, p: Int, v: Long) {
        b[p] = ((v shr 24) and 0xFF).toByte(); b[p + 1] = ((v shr 16) and 0xFF).toByte()
        b[p + 2] = ((v shr 8) and 0xFF).toByte(); b[p + 3] = (v and 0xFF).toByte()
    }

    private fun writeU64(b: ByteArray, p: Int, v: Long) {
        ByteBuffer.wrap(b, p, 8).putLong(v)
    }
}
