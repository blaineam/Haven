package com.blaineam.haven.core

/**
 * THE Android media compression targets — one place, so the three platforms can be compared at a
 * glance.
 *
 * Counterparts: Apple `MediaOptimizationTarget` + `VideoEncoder` (apple/HavenApp/), desktop
 * `MEDIA_TARGETS` (desktop/ui/app.js). The numbers below are deliberately IDENTICAL to Apple's;
 * where a platform genuinely cannot hit one, the divergence is named here rather than left to be
 * discovered from a file size.
 *
 * ## Why explicit numbers at all
 *
 * The old Android path computed its video bitrate as "≈4 bits/pixel, clamped to 2–8 Mbps". At
 * 1920×1080 that arithmetic is 1920*1080*4 = 8.3 Mbps, which clamps to the ceiling: **every
 * optimized 1080p clip was encoded at 8 Mbps**, nearly double Apple's target, and the "adaptive"
 * formula was in practice a constant stuck at its maximum. Apple had the same disease in a
 * different costume — `AVAssetExportSession` presets cap DIMENSIONS and then pick their own rate
 * (~8 Mbps at 1080p). Both were archival settings applied to something meant to cross a network,
 * and together they are why a real device was holding 53 items / 1.3 GB with single videos at
 * 320 MB.
 *
 * A bitrate is the only knob that actually targets a SIZE. Dimensions alone do not.
 *
 * ## Divergences from Apple, stated plainly
 *
 * - **Rotation is NOT baked into the pixels on Android.** Apple bakes it because `AVAssetWriter`
 *   emits a transform tag that some Android decode paths ignore, so a portrait iPhone clip arrived
 *   sideways. The reverse is not true: [android.media.MediaMuxer.setOrientationHint] writes the
 *   standard MP4 `tkhd` display matrix, which AVFoundation, ExoPlayer and Chrome all honour. Baking
 *   it here would mean replacing the decoder→encoder-surface path with an EGL/SurfaceTexture render
 *   pass (~250 lines) to fix a bug Android does not have. See the note in [MEDIA.md]; the cheap
 *   route if it is ever needed is `Mp4Composer.rotation()` from the mp4compose dependency this app
 *   already ships for story filters.
 * - **Audio inside a video is copied through, not re-encoded to 128 kbps.** Apple re-encodes. On
 *   Android the source track is virtually always already AAC from the camera, and re-encoding costs
 *   a second decode/encode pair plus a class of interleaving bug for a few hundred KB. Named here
 *   so it is a decision, not an oversight.
 */
object MediaTargets {

    // ---- Video ------------------------------------------------------------------------------
    /** Long edge of the encoded video. Short edge is [VIDEO_SHORT_EDGE]; aspect is preserved. */
    const val VIDEO_LONG_EDGE = 1920
    const val VIDEO_SHORT_EDGE = 1080

    /**
     * The whole point of this file: an EXPLICIT rate, not a quality preset and not a
     * pixels-times-a-constant formula that pins itself to its own ceiling.
     *
     * 1080p at 4.5 Mbps is visually fine in a phone feed and roughly a third of what the old path
     * emitted. Measured on Apple against real library videos: 305.7 MB → 37.7, 191.5 → 47.0,
     * 179.9 → 22.4.
     */
    const val VIDEO_BITRATE = 4_500_000

    /** Never inflate a source that was already leaner than the target — see `transcodeVideo`. */
    const val VIDEO_I_FRAME_INTERVAL_SEC = 2
    const val VIDEO_FPS_DEFAULT = 30
    const val VIDEO_FPS_MIN = 1
    const val VIDEO_FPS_MAX = 60

    /** Audio bitrate Apple uses for the track inside a video. See the divergence note above. */
    const val VIDEO_AUDIO_BITRATE = 128_000

    // ---- Stills -----------------------------------------------------------------------------
    /**
     * 1600px @ q62 (was 2048 @ q70). A feed photo, not an archive master.
     * `optimize` OFF keeps the old generous ceiling — that mode's entire promise is "as I shot it".
     */
    const val STILL_LONG_EDGE = 1600
    const val STILL_JPEG_QUALITY = 62
    const val STILL_LONG_EDGE_UNOPTIMIZED = 4096
    const val STILL_JPEG_QUALITY_UNOPTIMIZED = 95

    /** Rides the signed profile card to every circle member, so it stays small on purpose. */
    const val AVATAR_LONG_EDGE = 192
    const val AVATAR_JPEG_QUALITY = 70

    // ---- Standalone audio -------------------------------------------------------------------
    /**
     * Ceiling for an audio FILE shared in (WAV/AIFF/ALAC are uncompressed — tens of MB of speech).
     *
     * Android has no audio-file import path today: every `aud_` ref comes from the in-app recorder,
     * which already writes mono AAC at [VOICE_NOTE_BITRATE] — comfortably under this. The constant
     * exists so that when an import path lands it has a target to hit rather than inventing one.
     */
    const val STANDALONE_AUDIO_BITRATE = 96_000
    const val AUDIO_SAMPLE_RATE = 44_100
    /** Channel count is PRESERVED, capped at stereo — never upmix a mono voice note. */
    const val AUDIO_MAX_CHANNELS = 2

    /** The recorder is mono speech; 64k is already below the import ceiling, so it is not raised. */
    const val VOICE_NOTE_BITRATE = 64_000

    // ---- Limits -----------------------------------------------------------------------------
    /**
     * Longest video Haven will accept. Not a technical limit — a product one: without it a person
     * can hand their circle a feature film, and every member's device pays to store and move it.
     * Refused at IMPORT, before any ref is minted.
     */
    const val MAX_VIDEO_SECONDS = 15 * 60

    /** Attachment ceiling, applied AFTER transcode (a shrunk clip is checked at its final size). */
    const val MAX_VIDEO_BYTES = 60 * 1024 * 1024
}
