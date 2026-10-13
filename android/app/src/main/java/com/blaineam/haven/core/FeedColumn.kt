package com.blaineam.haven.core

/**
 * Width cap for the main post feed's single column (Apple `FeedColumnWidth` parity). The feed stays
 * ONE column - centered-post video autoplay depends on it - but on wide canvases (tablets, foldables
 * unfolded, desktop windows) a full-width post makes every photo/video huge. Above [MAX_DP] the column
 * is capped and centered; at or below it nothing changes, so phones are untouched.
 */
object FeedColumn {
    const val MAX_DP = 600

    /** Horizontal padding for a feed list in an area [availableDp] wide, [basePaddingDp] on narrow screens. */
    fun horizontalPaddingDp(availableDp: Float, basePaddingDp: Float = 16f): Float =
        if (availableDp.isFinite() && availableDp > MAX_DP) (availableDp - MAX_DP) / 2f else basePaddingDp
}
