package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Test

class FeedColumnTest {
    @Test fun phonesKeepTheirPadding() {
        for (w in listOf(320f, 360f, 393f, 412f, 480f, 600f)) assertEquals(16f, FeedColumn.horizontalPaddingDp(w), 0f)
    }

    @Test fun wideCanvasesCenterAColumnOfMaxWidth() {
        // Pixel Tablet, Fold inner, 10" tablet landscape, desktop window.
        for (w in listOf(700f, 841f, 1280f, 1600f)) {
            val pad = FeedColumn.horizontalPaddingDp(w)
            assertEquals(FeedColumn.MAX_DP.toFloat(), w - 2 * pad, 0.001f)
        }
    }

    @Test fun degenerateInputFallsBackToBase() {
        assertEquals(16f, FeedColumn.horizontalPaddingDp(Float.POSITIVE_INFINITY), 0f)
    }
}
