package com.blaineam.haven.core

import java.io.File

/**
 * What "already optimized" looks like on Android, and how to tell by LOOKING at a file.
 *
 * The Android counterpart of Apple `MediaOptimizationTarget` (apple/HavenApp/). It is the predicate
 * [MediaReoptimizer] uses to decide which of my ALREADY-SHARED blobs are worth re-encoding: the
 * compression rewrite in [MediaTargets] only ever applied to the next thing posted, so everything
 * already out there — on my device AND on every member's — stayed exactly as big as it was.
 *
 * ## Two layers, on purpose
 *
 * The DECISION is pure: [judgeVideo] / [judgeImage] take facts (bytes, pixels, codec, duration) and
 * return a verdict. The GATHERING is not: it decrypts and reads headers ([probeVideoFile],
 * [probeImageBytes]). They are split so the decision — the part that governs how much CPU the whole
 * feature burns and whether it can loop forever — is testable on the JVM without a device, an
 * emulator, or a real video. See `MediaOptimizationTargetTest`.
 *
 * ## Idempotence is the safety property
 *
 * A shape-only gate is only sound if the encoder's OWN output re-probes as AT target. Otherwise the
 * button offers the same clip on every scan and re-encodes it forever. That is why the ceilings below
 * carry headroom over [MediaTargets]' nominal rates rather than sitting exactly on them:
 * `AVVideoAverageBitRateKey`'s Android equivalent, `MediaFormat.KEY_BIT_RATE`, is a target the encoder
 * averages towards, not a ceiling, and the container adds its own overhead on top.
 *
 * The second half of the loop guard lives in [MediaReoptimizer]: anything that fails, or comes back
 * no smaller, is added to a persisted skip set and never offered again. That is what stops a clip
 * whose re-encode legitimately can't win (already lean, but HEVC, so it reads "above target"
 * forever) from being retried on every tap.
 *
 * ## Divergences from Apple, stated plainly
 *
 * - **Audio is never a candidate.** See [judgeAudio]. Apple re-encodes standalone audio through
 *   `addAudio`; Android has no audio-file IMPORT path at all, so every `aud_` ref this device
 *   authored came from the in-app recorder, which already writes mono AAC at
 *   [MediaTargets.VOICE_NOTE_BITRATE] — provably at target. Building an AAC transcoder to re-encode
 *   files that cannot exist would be inventing work.
 * - **The video bitrate ceiling still budgets [MediaTargets.VIDEO_AUDIO_BITRATE]** even though the
 *   Android transcode COPIES the source audio track through rather than re-encoding it (see the
 *   divergence note in [MediaTargets]). Passthrough camera AAC is ordinarily 128–256 kbps, which sits
 *   comfortably inside the 1.5 Mbps of headroom the 1.30 factor leaves above the 4.5 Mbps video
 *   target. Keeping the arithmetic identical to Apple's matters more than shaving it.
 */
object MediaOptimizationTarget {

    // ---- Tolerances ---------------------------------------------------------------------------

    /**
     * Overall bits/second above which a video is worth rewriting. 30% of headroom over the nominal
     * video+audio target, for the reason in the class doc: our own output must land UNDER this or
     * the scan never converges. Measured on Apple against real encoder output: 4.5–5.0 Mbps out
     * against this 6.0 Mbps trigger.
     */
    val videoBitrateCeiling: Int =
        ((MediaTargets.VIDEO_BITRATE + MediaTargets.VIDEO_AUDIO_BITRATE) * 1.30).toInt()

    /** JPEG q62 at 1600px measures well under this. A denser still came in at a higher quality. */
    const val IMAGE_BYTES_PER_PIXEL_CEILING: Double = 0.40

    /** 2% slack purely for the even-number rounding both encoders do on output dimensions. */
    const val DIMENSION_SLACK: Double = 1.02

    /**
     * Below this there is nothing worth winning, and a re-share costs every member in the circle an
     * edit event plus a re-download. Small files are left exactly as they are.
     */
    const val MINIMUM_INTERESTING_BYTES: Long = 200_000

    /**
     * A re-encode that doesn't clearly win is worse than no re-encode: the whole circle re-downloads
     * for nothing. New bytes must be at least this much smaller to be adopted.
     */
    const val REQUIRED_SHRINK_FACTOR: Double = 0.90

    /**
     * The moment the bitrate-controlled encoder landed in Android's posting path
     * (2026-07-20 08:00 America/Los_Angeles, the same instant Apple pins). Media shared before this
     * CANNOT have come from it.
     *
     * REPORTED, never enforced — see [MediaReoptimizer.scan]. Age would wrongly exclude media shared
     * after the cutoff with auto-optimize off (half the population this button exists for) and
     * wrongly include media that is already at target. Asking the file beats asking the calendar.
     * It is kept because it explains a row to the user ("shared before Haven learned to compress").
     */
    const val LEGACY_CUTOFF_MS: Long = 1_784_559_600_000L

    fun isLegacyByAge(createdAtMs: Long): Boolean = createdAtMs < LEGACY_CUTOFF_MS

    // ---- The verdict --------------------------------------------------------------------------

    /** What a probe found. [aboveTargetReason] is null when the file already reads as at-target. */
    data class Shape(
        val bytes: Long,
        /** Longest edge in pixels; 0 for audio. */
        val maxDimension: Int,
        /** Codec/container tell — a track MIME ("video/avc") or an image MIME ("image/jpeg"). */
        val codec: String,
        /** Overall bits/second; 0 for stills. */
        val bitrate: Int,
        val seconds: Double,
        val aboveTargetReason: String?,
    ) {
        val aboveTarget: Boolean get() = aboveTargetReason != null
    }

    /**
     * CODEC is the strongest tell there is: the optimized path emits H.264 and nothing else (see
     * `transcodeVideo` — `video/avc` is hard-coded, because iOS-shot HEVC cannot be relied on to
     * decode everywhere). So a `video/hevc` track is positive proof the file came from the
     * passthrough strip-remux or the raw-copy fallback, i.e. auto-optimize was off or the transcode
     * failed. Dimensions and bitrate then catch H.264 files that came from the OLD Android path,
     * whose "adaptive" 4-bits-per-pixel formula pinned every 1080p clip to its own 8 Mbps ceiling.
     *
     * Bitrate is computed from FILE BYTES ÷ DURATION rather than any declared rate, because that is
     * the number that actually costs the circle storage and transfer, container overhead and all.
     */
    fun judgeVideo(bytes: Long, width: Int, height: Int, trackMime: String, seconds: Double): Shape? {
        if (bytes <= 0 || width <= 0 || height <= 0 || !seconds.isFinite() || seconds <= 0.0) return null
        val maxDim = maxOf(width, height)
        val bitrate = (bytes * 8.0 / seconds).toInt()
        val reason = when {
            bytes < MINIMUM_INTERESTING_BYTES -> null
            !trackMime.equals("video/avc", ignoreCase = true) -> "$trackMime, not H.264"
            maxDim > MediaTargets.VIDEO_LONG_EDGE * DIMENSION_SLACK ->
                "${maxDim}px, target ${MediaTargets.VIDEO_LONG_EDGE}px"
            bitrate > videoBitrateCeiling ->
                "${bitrate / 1000} kbps, target ≤ ${videoBitrateCeiling / 1000} kbps"
            else -> null
        }
        return Shape(bytes, maxDim, trackMime, bitrate, seconds, reason)
    }

    /**
     * Two tells, and both matter. DIMENSIONS catch the obvious case — a 4032px camera original that
     * never went through the downscale. BYTES-PER-PIXEL catch the subtler one: a photo that IS
     * 1600px but was written at q95 (auto-optimize off) or arrived as a PNG/WebP screenshot, where
     * the pixel count says nothing and only the density gives it away.
     */
    fun judgeImage(bytes: Long, width: Int, height: Int, mime: String): Shape? {
        if (bytes <= 0 || width <= 0 || height <= 0) return null
        val maxDim = maxOf(width, height)
        val bpp = bytes.toDouble() / (width.toDouble() * height.toDouble())
        val reason = when {
            bytes < MINIMUM_INTERESTING_BYTES -> null
            // The optimized path ALWAYS writes JPEG. Anything else here came in verbatim.
            !mime.equals("image/jpeg", ignoreCase = true) -> "not a JPEG ($mime)"
            maxDim > MediaTargets.STILL_LONG_EDGE * DIMENSION_SLACK ->
                "${maxDim}px, target ${MediaTargets.STILL_LONG_EDGE}px"
            bpp > IMAGE_BYTES_PER_PIXEL_CEILING ->
                String.format("%.2f bytes/pixel, target ≤ %.2f", bpp, IMAGE_BYTES_PER_PIXEL_CEILING)
            else -> null
        }
        return Shape(bytes, maxDim, mime, 0, 0.0, reason)
    }

    /**
     * Always at target. Not an oversight and not a stub — see the divergence note in the class doc:
     * on Android there is no import path that can mint a non-conforming `aud_` blob, so an audio
     * candidate cannot exist, and a "candidate" the encoder would have to refuse is worse than none
     * (it would burn a slot in the batch and a slot in the skip set on every scan).
     */
    fun judgeAudio(bytes: Long): Shape = Shape(bytes, 0, "audio", 0, 0.0, null)

    /**
     * Whether a fresh encode is worth adopting. Applied to the REAL output size against the REAL
     * source size, never to a declared rate: [MediaTargets.VIDEO_BITRATE] is a target, not a ceiling
     * on the source, so an already-lean clip is re-encoded UP and grows. Android hit exactly this on
     * a 720p fixture (0.48 MB in, 0.59 MB out) — caught by measurement, not by review.
     */
    fun keepsNewEncode(sourceBytes: Long, newBytes: Long): Boolean =
        newBytes > 0 && sourceBytes > 0 && newBytes < sourceBytes * REQUIRED_SHRINK_FACTOR

    // ---- Gathering the facts (device-only) ----------------------------------------------------

    /**
     * Probe a DECRYPTED video file. Returns null when it cannot be read or judged at all — the caller
     * leaves such blobs alone rather than guessing (fail closed: an unreadable file is not a
     * re-encode candidate).
     */
    fun probeVideoFile(file: File): Shape? {
        val bytes = file.length()
        if (bytes <= 0) return null
        var extractor: android.media.MediaExtractor? = null
        return try {
            extractor = android.media.MediaExtractor().apply { setDataSource(file.absolutePath) }
            var mime: String? = null
            var w = 0
            var h = 0
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val m = f.getString(android.media.MediaFormat.KEY_MIME) ?: continue
                if (!m.startsWith("video/")) continue
                mime = m
                w = f.getInteger(android.media.MediaFormat.KEY_WIDTH)
                h = f.getInteger(android.media.MediaFormat.KEY_HEIGHT)
                break
            }
            if (mime == null) return null
            val seconds = android.media.MediaMetadataRetriever().use { r ->
                r.setDataSource(file.absolutePath)
                r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull()?.let { it / 1000.0 }
            } ?: return null
            judgeVideo(bytes, w, h, mime, seconds)
        } catch (t: Throwable) {
            android.util.Log.w("Reoptimize", "video probe failed: ${t.message}")
            null
        } finally {
            runCatching { extractor?.release() }
        }
    }

    /** Probe DECRYPTED image bytes. Header-only decode — no full bitmap is ever allocated. */
    fun probeImageBytes(bytes: ByteArray): Shape? = runCatching {
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        judgeImage(bytes.size.toLong(), bounds.outWidth, bounds.outHeight, bounds.outMimeType ?: "unknown")
    }.getOrNull()
}
