package com.blaineam.haven.core

import com.blaineam.haven.core.CallPermissionPolicy.CAMERA
import com.blaineam.haven.core.CallPermissionPolicy.RECORD_AUDIO
import com.blaineam.haven.core.CallPermissionPolicy.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * A device that only ever RECEIVED calls never held CAMERA or RECORD_AUDIO: only the outgoing
 * starter asked. These pin the decisions that now run on Answer and on the camera button.
 */
class CallPermissionPolicyTest {
    @Test fun answeringAsksForTheMicAndCameraThatAreMissing() {
        assertEquals(listOf(RECORD_AUDIO, CAMERA), CallPermissionPolicy.answerRequest(micGranted = false, cameraGranted = false))
        assertEquals(listOf(CAMERA), CallPermissionPolicy.answerRequest(micGranted = true, cameraGranted = false))
        assertEquals(listOf(RECORD_AUDIO), CallPermissionPolicy.answerRequest(micGranted = false, cameraGranted = true))
    }

    @Test fun answeringAsksForNothingWhenBothAreGranted() {
        assertTrue(CallPermissionPolicy.answerRequest(micGranted = true, cameraGranted = true).isEmpty())
    }

    @Test fun grantedCameraTogglesStraightAway() {
        assertEquals(Step.PROCEED, CallPermissionPolicy.cameraToggleStep(granted = true, askedBefore = true, rationale = false))
        assertEquals(Step.PROCEED, CallPermissionPolicy.cameraToggleStep(granted = true, askedBefore = false, rationale = false))
    }

    @Test fun neverAskedCameraRequestsThePrompt() {
        assertEquals(Step.REQUEST, CallPermissionPolicy.cameraToggleStep(granted = false, askedBefore = false, rationale = false))
    }

    @Test fun deniedOnceWithRationaleAsksAgain() {
        assertEquals(Step.REQUEST, CallPermissionPolicy.cameraToggleStep(granted = false, askedBefore = true, rationale = true))
    }

    @Test fun deniedForeverCanOnlyBeFixedInSettings() {
        // asked before + the system will not show the prompt again = "don't ask again"
        assertEquals(Step.OPEN_SETTINGS, CallPermissionPolicy.cameraToggleStep(granted = false, askedBefore = true, rationale = false))
    }

    @Test fun deniedResultsNameExactlyTheDeniedPermissions() {
        assertEquals(listOf(RECORD_AUDIO, CAMERA), CallPermissionPolicy.deniedMessages(mapOf(RECORD_AUDIO to false, CAMERA to false)))
        assertEquals(listOf(CAMERA), CallPermissionPolicy.deniedMessages(mapOf(RECORD_AUDIO to true, CAMERA to false)))
        assertTrue(CallPermissionPolicy.deniedMessages(mapOf(RECORD_AUDIO to true, CAMERA to true)).isEmpty())
        assertTrue(CallPermissionPolicy.deniedMessages(emptyMap()).isEmpty())
    }

    // ── manifest guard ──────────────────────────────────────────────────────────────────────────

    private fun repoRoot(): File {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/main").isDirectory) { d = d.parentFile ?: error("no repo root") }
        return d
    }
    private val ns = "http://schemas.android.com/apk/res/android"
    private fun manifest(): Element =
        DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(File(repoRoot(), "android/app/src/main/AndroidManifest.xml")).documentElement
    private fun all(e: Element, tag: String) =
        (0 until e.getElementsByTagName(tag).length).map { e.getElementsByTagName(tag).item(it) as Element }

    @Test fun manifestDeclaresBothCallPermissions() {
        val perms = all(manifest(), "uses-permission").map { it.getAttributeNS(ns, "name") }
        assertTrue(CAMERA in perms)
        assertTrue(RECORD_AUDIO in perms)
    }

    /**
     * The call service must NOT claim the `camera` foreground-service type: on Android 14+ starting a
     * foreground service of that type throws SecurityException when CAMERA is not yet granted — which
     * is exactly the state of a device on its first received call. Camera capture instead rides the
     * visible call activity ("while in use"). If this ever flips, the type needs a runtime guard.
     */
    @Test fun callServiceDoesNotClaimTheCameraForegroundType() {
        val svc = all(manifest(), "service").single { it.getAttributeNS(ns, "name") == ".core.ConnectionService" }
        val types = svc.getAttributeNS(ns, "foregroundServiceType").split("|")
        assertFalse("camera" in types)
        assertTrue("microphone" in types)
    }
}
