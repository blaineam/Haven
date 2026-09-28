package com.blaineam.haven.core

import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Pure (Android-free) decisions for call screen sharing, kept apart from WebRTC so they are
 * unit-testable on the JVM.
 *
 * Cross-platform contract: the screen share is a SECOND video track with track id [TRACK_ID]
 * published under stream id [STREAM_ID] — Apple (`WebRTCCall.startScreenShare`) and Android both
 * send it that way. The camera rides a different stream ("haven" on Android, "stream0" on Apple).
 */
object ScreenSharePolicy {
    /** Diagnostics tag — `adb logcat -s HavenScreenShare` shows the whole share lifecycle. */
    const val LOG_TAG = "HavenScreenShare"

    const val TRACK_ID = "screen0"
    const val STREAM_ID = "screen"

    /** Longest captured side. A phone's native panel (e.g. 1440x3120) is far past what the
     *  hardware H.264 encoders on many devices will initialise at, and it would not fit the bitrate
     *  budget anyway; 1280 keeps text legible on the far end. */
    const val MAX_LONG_SIDE = 1280
    /** Encoders want macroblock-aligned frames; some HW H.264 encoders refuse anything else. */
    const val ALIGN = 16
    const val FPS = 15
    /** Matches Apple's screen sender (`tuneVideoSender(… 2_500_000)`). */
    const val MAX_BITRATE_BPS = 2_500_000

    /**
     * The capture size for a [width]x[height] display: aspect kept, long side capped at [maxLong],
     * both sides rounded to a multiple of [align] (never below [align], never above the cap).
     * Orientation is preserved (a portrait display yields a portrait size).
     */
    fun captureSize(
        width: Int,
        height: Int,
        maxLong: Int = MAX_LONG_SIDE,
        align: Int = ALIGN,
    ): Pair<Int, Int> {
        val cap = (maxLong / align) * align
        if (width <= 0 || height <= 0) return (cap * 9 / 16 / align * align) to cap
        val scale = minOf(1.0, maxLong.toDouble() / max(width, height))
        fun fit(v: Int): Int {
            val scaled = ((v * scale) / align).roundToInt() * align
            return scaled.coerceIn(align, cap)
        }
        return fit(width) to fit(height)
    }

    /**
     * Is an incoming video track the peer's screen share (vs their camera)?
     *
     * The STREAM id is authoritative: it is carried in the SDP `a=msid` on every (re)negotiation,
     * while a Unified-Plan receiver's track id is fixed when its transceiver is first created and
     * need not equal the sender's id (a recycled or locally-created transceiver keeps its own).
     * Routing by track id alone let a screen track land in the CAMERA slot, where the renderer kept
     * showing the last camera frame — the "video froze and the share never appeared" report.
     * The track id is only consulted when the sender announced no stream at all.
     */
    fun isScreenTrack(trackId: String?, streamIds: Collection<String>): Boolean {
        if (streamIds.isNotEmpty()) return STREAM_ID in streamIds
        return trackId == TRACK_ID
    }
}
