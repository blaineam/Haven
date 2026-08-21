package com.blaineam.haven.core

import android.graphics.Bitmap
import com.radzivon.bartoshyk.avif.coder.HeifCoder
import com.radzivon.bartoshyk.avif.coder.PreferredColorConfig

/**
 * The 512px AVIF preview tier (`docs/PREVIEW-TIER-DESIGN.md`). Mirrors iOS `PreviewCodec.swift`.
 *
 * This is the only media small enough to cross a satellite link: about 6 KB, under two Haven text
 * messages, where the existing `thumb:` companion is ≤32 KB and a full photo is megabytes.
 *
 * **Why AVIF and not JPEG.** Measured on real device photographs at 512px: JPEG cannot reach the
 * budget at all — its floor is ~12 KB even at the lowest quality, and it looks worse there than AVIF
 * does at half the size. AVIF hits ~6 KB at the same measured quality (~30 dB PSNR).
 *
 * **Why the target is BYTES, not quality.** The three platforms' encoders take different quality
 * scales that do not line up — ImageIO takes 0–1, `ravif` takes 0–100, avif-coder takes 0–100, and
 * the same nominal number produces materially different sizes. A quality constant would silently
 * mean three different things. So every platform is specified the same way: 512px longest edge,
 * under [MAX_BYTES], quality walked down until it fits.
 *
 * AVIF is bundled (`io.github.awxkee:avif-coder`) rather than taken from the platform: Android has
 * AVIF natively only from API 31 and `minSdk` is 29, and there is **no public AVIF encoder API at
 * any level**. Every client must be able to WRITE previews, not just read them, because any device
 * can be the sender.
 */
object PreviewCodec {
    /** Longest edge of a preview, in pixels. */
    const val MAX_DIMENSION = 512

    /** Hard ceiling for a preview. ~2 Haven text messages. */
    const val MAX_BYTES = 8 * 1024

    /**
     * Quality ladder, walked highest-first until the result fits [MAX_BYTES]. Starting high and
     * stepping down costs a few extra encodes on complex images and gives the best-looking preview
     * that fits, rather than a uniformly ugly one sized for the worst case.
     */
    private val QUALITY_LADDER = intArrayOf(60, 50, 42, 35, 28, 22, 16, 10)

    private val coder by lazy { HeifCoder() }

    /**
     * Encode a preview, or null if even the lowest quality will not fit (a pathological image, or
     * the codec is unavailable). A null must be treated as "no preview for this item" — never as a
     * reason to send the full media over a constrained link.
     */
    fun encode(source: Bitmap): ByteArray? {
        val scaled = downscale(source) ?: return null
        for (q in QUALITY_LADDER) {
            val bytes = runCatching { coder.encodeAvif(scaled, q) }.getOrNull() ?: continue
            if (bytes.size <= MAX_BYTES) return bytes
        }
        return null
    }

    /** Decode a preview. Works on every supported API level because the codec is bundled. */
    fun decode(bytes: ByteArray): Bitmap? =
        runCatching { coder.decode(bytes, PreferredColorConfig.RGBA_8888) }.getOrNull()

    /** True when these bytes are an AVIF preview rather than some other blob. */
    fun isPreview(bytes: ByteArray): Boolean = runCatching { coder.isAvif(bytes) }.getOrDefault(false)

    /** Fit to [MAX_DIMENSION] on the longest edge, preserving aspect. Never upscales. */
    private fun downscale(src: Bitmap): Bitmap? {
        val longest = maxOf(src.width, src.height)
        if (longest <= 0) return null
        if (longest <= MAX_DIMENSION) return src
        val scale = MAX_DIMENSION.toDouble() / longest
        val w = (src.width * scale).toInt().coerceAtLeast(1)
        val h = (src.height * scale).toInt().coerceAtLeast(1)
        return runCatching { Bitmap.createScaledBitmap(src, w, h, true) }.getOrNull()
    }
}
