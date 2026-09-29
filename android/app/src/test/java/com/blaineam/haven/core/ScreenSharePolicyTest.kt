package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenSharePolicyTest {

    private fun assertAligned(size: Pair<Int, Int>) {
        assertEquals("width aligned", 0, size.first % ScreenSharePolicy.ALIGN)
        assertEquals("height aligned", 0, size.second % ScreenSharePolicy.ALIGN)
    }

    @Test fun tallPhonePanelIsCappedAndAligned() {
        // Pixel-class 1440x3120 portrait: the raw size that HW H.264 encoders refused.
        val s = ScreenSharePolicy.captureSize(1440, 3120)
        assertEquals(592 to 1280, s)
        assertAligned(s)
    }

    @Test fun landscapeKeepsOrientation() {
        val s = ScreenSharePolicy.captureSize(3120, 1440)
        assertEquals(1280 to 592, s)
    }

    @Test fun commonPanelsStayWithinCapAndKeepAspect() {
        listOf(1080 to 2400, 1080 to 2340, 720 to 1600, 1600 to 2560, 2208 to 1840, 1179 to 2556).forEach { (w, h) ->
            val s = ScreenSharePolicy.captureSize(w, h)
            assertAligned(s)
            assertTrue("long side capped for ${w}x$h: $s", maxOf(s.first, s.second) <= ScreenSharePolicy.MAX_LONG_SIDE)
            val want = w.toDouble() / h
            val got = s.first.toDouble() / s.second
            assertEquals("aspect for ${w}x$h: $s", want, got, 0.03)
        }
    }

    @Test fun smallDisplayIsNotUpscaled() {
        assertEquals(480 to 800, ScreenSharePolicy.captureSize(480, 800))
    }

    @Test fun oddDimensionsBecomeAligned() {
        val s = ScreenSharePolicy.captureSize(721, 1283)
        assertAligned(s)
        assertEquals(1280, s.second)
    }

    @Test fun unknownDisplayFallsBackToPortrait720p() {
        assertEquals(720 to 1280, ScreenSharePolicy.captureSize(0, 0))
    }

    @Test fun streamIdRoutesScreenEvenWhenTrackIdDiffers() {
        // Unified-Plan receiver ids need not match the sender's — the stream id must win.
        assertTrue(ScreenSharePolicy.isScreenTrack("7f3a-random-receiver-id", listOf("screen")))
    }

    @Test fun cameraStreamIsNeverTheScreen() {
        assertFalse(ScreenSharePolicy.isScreenTrack("haven-video", listOf("haven")))    // Android camera
        assertFalse(ScreenSharePolicy.isScreenTrack("video0", listOf("stream0")))       // Apple camera
        // A recycled receiver that kept the old screen id but now carries the camera stream.
        assertFalse(ScreenSharePolicy.isScreenTrack("screen0", listOf("stream0")))
    }

    @Test fun trackIdIsTheFallbackWithoutStreams() {
        assertTrue(ScreenSharePolicy.isScreenTrack("screen0", emptyList()))
        assertFalse(ScreenSharePolicy.isScreenTrack("video0", emptyList()))
        assertFalse(ScreenSharePolicy.isScreenTrack(null, emptyList()))
    }

    @Test fun consentIsGrantedOnlyForOkWithData() {
        assertEquals(ScreenSharePolicy.CONSENT_GRANTED, ScreenSharePolicy.consentOutcome(-1, true))
        assertEquals("denied(-1)", ScreenSharePolicy.consentOutcome(-1, false))
        assertEquals("denied(0)", ScreenSharePolicy.consentOutcome(0, true))
        assertEquals("denied(0)", ScreenSharePolicy.consentOutcome(0, false))
    }
}
