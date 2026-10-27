package com.blaineam.haven.core

/**
 * Runtime permissions for calls. Before this, ONLY the outgoing "start a call" path asked for
 * CAMERA + RECORD_AUDIO. A call that was ANSWERED (in-app Accept, the notification's Answer button,
 * a car's answer key) never asked at all, and the in-call camera button never asked either — so on a
 * device that only ever received calls both permissions stayed denied: the mic captured nothing and
 * the camera button flipped to "on" while publishing a permanent black tile, with no message.
 *
 * Pure (strings + booleans) so the decisions are unit-testable; [com.blaineam.haven.MainActivity]
 * owns the launcher and the toasts.
 */
object CallPermissionPolicy {
    const val CAMERA = "android.permission.CAMERA"
    const val RECORD_AUDIO = "android.permission.RECORD_AUDIO"

    enum class Step { PROCEED, REQUEST, OPEN_SETTINGS }

    /**
     * What to ask for when ANSWERING a call. The mic is required for the call to be useful and the
     * camera is asked alongside it (same prompt as the outgoing path) but never blocks answering —
     * the call proceeds either way and the camera button asks again when it is tapped.
     */
    fun answerRequest(micGranted: Boolean, cameraGranted: Boolean): List<String> = buildList {
        if (!micGranted) add(RECORD_AUDIO)
        if (!cameraGranted) add(CAMERA)
    }

    /**
     * The camera button was tapped. [askedBefore] = we have already shown the system prompt once;
     * [rationale] = the system would still show it. Denied twice with "don't ask again" (asked,
     * no rationale) means the prompt can no longer appear, so the only way forward is app Settings.
     */
    fun cameraToggleStep(granted: Boolean, askedBefore: Boolean, rationale: Boolean): Step = when {
        granted -> Step.PROCEED
        !askedBefore || rationale -> Step.REQUEST
        else -> Step.OPEN_SETTINGS
    }

    /** Which toast (if any) a permission result deserves. */
    fun deniedMessages(grants: Map<String, Boolean>): List<String> = buildList {
        if (grants[RECORD_AUDIO] == false) add(RECORD_AUDIO)
        if (grants[CAMERA] == false) add(CAMERA)
    }
}
