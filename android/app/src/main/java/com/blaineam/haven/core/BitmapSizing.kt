package com.blaineam.haven.core

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * How big to decode a picture for the box it will be drawn in — the arithmetic behind
 * [LocalMedia.displayBitmap], kept free of Android types so it can be unit-tested.
 *
 * Play's "bitmap image optimization" finding is about exactly this: every feed/profile/story tile
 * used to decode to a fixed 1280px long edge whatever it was drawn at, so a 44dp attachment chip or
 * a 56dp story ring held a ~1000px, ~3-4 MB bitmap. Decoding to the box instead costs what is
 * actually on screen.
 */
object BitmapSizing {

    /** How the bitmap will be fitted into its box (mirrors the Compose ContentScale in use). */
    enum class Fit {
        /** ContentScale.Crop — the bitmap must COVER the box. */
        CROP,
        /** ContentScale.FillWidth — the box's width decides; its height follows the picture. */
        FILL_WIDTH,
        /** ContentScale.Fit — the whole picture fits INSIDE the box. */
        FIT,
    }

    /**
     * Scale (≤ 1, never an upscale) to apply to a [srcW]×[srcH] picture so it fills a [boxW]×[boxH]
     * box under [fit] without the renderer having to magnify it. A box dimension ≤ 0 is unbounded
     * (e.g. a LazyColumn's height) and is ignored. [cap] bounds the decoded long edge regardless of
     * the box — the memory ceiling for a full-screen viewer on a big tablet.
     */
    fun scale(srcW: Int, srcH: Int, boxW: Int, boxH: Int, fit: Fit, cap: Int): Float {
        if (srcW <= 0 || srcH <= 0) return 1f
        val sw = if (boxW > 0) boxW.toFloat() / srcW else null
        val sh = if (boxH > 0) boxH.toFloat() / srcH else null
        val forBox = when (fit) {
            Fit.CROP -> listOfNotNull(sw, sh).maxOrNull()
            Fit.FILL_WIDTH -> sw ?: sh
            Fit.FIT -> listOfNotNull(sw, sh).minOrNull()
        } ?: 1f
        val forCap = if (cap > 0) cap.toFloat() / max(srcW, srcH) else 1f
        return min(1f, min(forBox, forCap))
    }

    /** The decoded size for [scale] — at least 1×1. */
    fun scaled(srcW: Int, srcH: Int, scale: Float): Pair<Int, Int> =
        max(1, (srcW * scale).roundToInt()) to max(1, (srcH * scale).roundToInt())

    /**
     * The largest power-of-two BitmapFactory `inSampleSize` that still decodes AT LEAST [scale] of
     * the source — sampling is the cheap, allocation-free part of the shrink; the remainder is a
     * filtered resize. Never under-samples (a too-small decode would be blurry on screen).
     */
    fun sampleSize(scale: Float): Int {
        if (scale >= 1f || scale <= 0f) return 1
        var sample = 1
        while (1f / (sample * 2) >= scale) sample *= 2
        return sample
    }
}
