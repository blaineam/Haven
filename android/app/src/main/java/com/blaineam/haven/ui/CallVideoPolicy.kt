package com.blaineam.haven.ui

/**
 * When a call tile may SHOW video. A WebRTC sink keeps the LAST frame it was handed — a track that is
 * disabled, or whose capturer stopped, delivers nothing more, so the surface just sat on the final
 * frame. Field report: "the android unsharing the video leaves the last frame shown to the android
 * user instead of it being disabled" (the self-preview), and the minimised tile did the same when the
 * other side switched their camera off. A tile that must not show video is cleared and hidden, never
 * left holding the stale frame.
 */
object CallVideoPolicy {
    /** My own corner preview: live only while my camera is on AND there is a local track. */
    fun localPreviewActive(cameraOn: Boolean, hasLocalTrack: Boolean): Boolean = cameraOn && hasLocalTrack

    /** A remote participant's tile: live only while they have not told us their camera is off. */
    fun remoteTileActive(remoteCameraOff: Boolean, hasTrack: Boolean): Boolean = !remoteCameraOff && hasTrack
}
