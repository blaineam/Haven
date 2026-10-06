package com.blaineam.haven.core

import com.blaineam.haven.core.BitmapSizing.Fit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BitmapSizingTest {

    private fun size(w: Int, h: Int, bw: Int, bh: Int, fit: Fit, cap: Int = 1280) =
        BitmapSizing.scaled(w, h, BitmapSizing.scale(w, h, bw, bh, fit, cap))

    @Test fun a_small_crop_tile_decodes_to_the_tile_not_to_1280() {
        // A 4032×3024 photo in a 154px square (56dp ring at xxhdpi): cover the square, nothing more.
        assertEquals(205 to 154, size(4032, 3024, 154, 154, Fit.CROP))
    }

    @Test fun fill_width_uses_the_width_when_the_height_is_unbounded() {
        // Feed card: LazyColumn gives a bounded width and an unbounded height.
        assertEquals(1080 to 810, size(4032, 3024, 1080, 0, Fit.FILL_WIDTH))
    }

    @Test fun fit_keeps_the_whole_picture_inside_the_box() {
        val (w, h) = size(3024, 4032, 1080, 1080, Fit.FIT)
        assertEquals(1080, h); assertTrue(w <= 1080)
    }

    @Test fun never_upscales_and_respects_the_cap() {
        assertEquals(400 to 300, size(400, 300, 2000, 2000, Fit.CROP))
        assertEquals(1280 to 960, size(4032, 3024, 4000, 4000, Fit.CROP))
        // An unmeasured box falls back to the cap alone (the old behaviour).
        assertEquals(1280 to 960, size(4032, 3024, 0, 0, Fit.FIT))
    }

    @Test fun sample_size_never_undersamples() {
        assertEquals(1, BitmapSizing.sampleSize(1f))
        assertEquals(1, BitmapSizing.sampleSize(0.6f))
        assertEquals(2, BitmapSizing.sampleSize(0.5f))
        assertEquals(2, BitmapSizing.sampleSize(0.3f))
        // 154/4032 ≈ 0.038 → 16 (1/16 = 0.0625 ≥ 0.038; 1/32 would be too small).
        assertEquals(16, BitmapSizing.sampleSize(154f / 4032f))
        for (s in listOf(0.9f, 0.51f, 0.26f, 0.1f, 0.013f)) {
            assertTrue("1/${BitmapSizing.sampleSize(s)} >= $s", 1f / BitmapSizing.sampleSize(s) >= s)
        }
    }
}
