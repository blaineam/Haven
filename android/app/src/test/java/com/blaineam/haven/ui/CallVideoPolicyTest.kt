package com.blaineam.haven.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallVideoPolicyTest {
    @Test fun `my preview is live only with the camera on and a local track`() {
        assertTrue(CallVideoPolicy.localPreviewActive(cameraOn = true, hasLocalTrack = true))
        assertFalse("camera off must not leave the last frame up", CallVideoPolicy.localPreviewActive(cameraOn = false, hasLocalTrack = true))
        assertFalse(CallVideoPolicy.localPreviewActive(cameraOn = true, hasLocalTrack = false))
        assertFalse(CallVideoPolicy.localPreviewActive(cameraOn = false, hasLocalTrack = false))
    }

    @Test fun `a remote tile goes dark when that peer turns their camera off`() {
        assertTrue(CallVideoPolicy.remoteTileActive(remoteCameraOff = false, hasTrack = true))
        assertFalse(CallVideoPolicy.remoteTileActive(remoteCameraOff = true, hasTrack = true))
        assertFalse(CallVideoPolicy.remoteTileActive(remoteCameraOff = false, hasTrack = false))
    }

    /** Source guard: the three places that draw call video must pass the policy, not a bare tile. */
    @Test fun `the self preview and the minimised tile use the policy`() {
        val src = listOf("src/main/java/com/blaineam/haven/ui/CallUI.kt", "app/src/main/java/com/blaineam/haven/ui/CallUI.kt")
            .map(::File).first { it.exists() }.readText()
        assertTrue("self preview", src.contains("CallVideoPolicy.localPreviewActive("))
        assertTrue("minimised remote tile", src.contains("CallVideoPolicy.remoteTileActive("))
        assertTrue("the tile clears the stale frame", src.contains("clearImage()"))
        assertEquals("one tile implementation", 1, Regex("fun CallVideoTile\\(").findAll(src).count())
    }
}
