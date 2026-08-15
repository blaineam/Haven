package com.blaineam.haven.core

import android.graphics.Bitmap

/**
 * A 64-bit fingerprint of what a picture LOOKS like, rather than of its bytes. Port of
 * `apple/HavenApp/PerceptualHash.swift` — the two must agree, since both platforms deduplicate the
 * same circle.
 *
 * Haven identifies media by sha-256 of the plaintext, which is right for storage and useless for
 * "is this the same photo?": the importer re-encodes everything it stages and re-encoding is not
 * reproducible, so importing the same archive twice gives every picture a different content hash.
 *
 * dHash: reduce to 9x8 grey, then one bit per adjacent horizontal pair — "is this pixel brighter
 * than the one to its right". What survives is coarse structure, which is what re-encoding preserves
 * and what a different photo does not share. Not a cryptographic hash; never use it as one.
 */
object PerceptualHash {

    /**
     * Bits that may differ before two pictures are considered different.
     *
     * 0 would demand bit-identical downsamples, which re-encoding does not guarantee; past ~10 it
     * starts matching photos that merely share a composition. A re-encode typically lands at 0-2 and
     * different pictures are almost always past 20, so 6 of 64 has wide margin on both sides.
     */
    const val DUPLICATE_THRESHOLD = 6

    const val WIDTH = 9
    const val HEIGHT = 8

    /** The pure half, so it can be tested on the JVM: `gray` is WIDTH*HEIGHT luminance samples. */
    fun dHashFromGray(gray: IntArray): ULong? {
        if (gray.size < WIDTH * HEIGHT) return null
        var hash = 0uL
        var bit = 0
        for (y in 0 until HEIGHT) {
            for (x in 0 until WIDTH - 1) {
                if (gray[y * WIDTH + x] > gray[y * WIDTH + x + 1]) hash = hash or (1uL shl bit)
                bit++
            }
        }
        return hash
    }

    /** Null when the bitmap cannot be reduced — callers must treat that as "unknown", never a match. */
    fun dHash(bitmap: Bitmap): ULong? {
        val small = runCatching { bitmap.scale(WIDTH, HEIGHT) }.getOrNull() ?: return null
        val px = IntArray(WIDTH * HEIGHT)
        small.getPixels(px, 0, WIDTH, 0, 0, WIDTH, HEIGHT)
        val gray = IntArray(px.size) { i ->
            val c = px[i]
            // Rec. 601 luma, integer — matches what a grayscale CGContext produces closely enough
            // for a 9x8 comparison, and the threshold absorbs the rest.
            ((c shr 16 and 0xFF) * 299 + (c shr 8 and 0xFF) * 587 + (c and 0xFF) * 114) / 1000
        }
        return dHashFromGray(gray)
    }

    private fun Bitmap.scale(w: Int, h: Int): Bitmap = Bitmap.createScaledBitmap(this, w, h, true)

    /** Hamming distance — how many of the 64 bits differ. */
    fun distance(a: ULong, b: ULong): Int = java.lang.Long.bitCount((a xor b).toLong())

    fun looksLikeTheSamePicture(a: ULong, b: ULong): Boolean = distance(a, b) <= DUPLICATE_THRESHOLD
}
