package com.blaineam.haven

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.blaineam.haven.core.MediaTargets
import com.blaineam.haven.core.readVideoBytes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.random.Random

/**
 * Runs the REAL transcode against a REAL file and reports what it produced.
 *
 * This test exists because of a specific failure: Apple's rewritten encoder was wired into the
 * posting path without ever being executed, and it deadlocked on every clip with an audio track.
 * Recording and attaching video were completely broken until someone noticed. "It compiles" and
 * "the constants look right" are not evidence about a codec pipeline.
 *
 * The fixture is deliberately NOISY. Flat or slowly-varying frames compress to almost nothing no
 * matter what bitrate you ask for, so a before/after comparison built on them would show a
 * spectacular ratio that proves only that solid colours are cheap. Noise forces the encoder to
 * actually spend its budget, which is the only way the 8 Mbps → 4.5 Mbps change shows up as bytes.
 *
 * Numbers are printed, not just asserted, so the actual measurement is visible in the log.
 */
@RunWith(AndroidJUnit4::class)
class VideoTranscodeTargetTest {

    private val ctx get() = InstrumentationRegistry.getInstrumentation().targetContext

    /**
     * A "camera original": 1080p at a deliberately fat [srcBitrate], noisy enough that the encoder
     * cannot cheat its way under it.
     */
    private fun makeSourceVideo(dst: File, w: Int, h: Int, frames: Int, srcBitrate: Int, rotation: Int) {
        val format = android.media.MediaFormat.createVideoFormat("video/avc", w, h).apply {
            setInteger(android.media.MediaFormat.KEY_COLOR_FORMAT,
                android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(android.media.MediaFormat.KEY_BIT_RATE, srcBitrate)
            setInteger(android.media.MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(android.media.MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val codec = android.media.MediaCodec.createEncoderByType("video/avc")
        codec.configure(format, null, null, android.media.MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        val muxer = android.media.MediaMuxer(dst.absolutePath,
            android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        if (rotation != 0) muxer.setOrientationHint(rotation)

        val rnd = Random(42)                       // seeded: same fixture every run
        val ySize = w * h
        val frameBytes = ByteArray(ySize * 3 / 2)
        var track = -1
        var started = false
        val info = android.media.MediaCodec.BufferInfo()
        var frame = 0
        var done = false
        while (!done) {
            val inIdx = codec.dequeueInputBuffer(10_000)
            if (inIdx >= 0) {
                val buf = codec.getInputBuffer(inIdx)!!
                buf.clear()
                if (frame < frames) {
                    // Video-LIKE content, which is a narrower target than it sounds.
                    //
                    // The first version of this fixture was pure `rnd.nextBytes`. Incompressible
                    // noise defeats rate control entirely — the emulator's software encoder emitted
                    // 255 Mbps against a 12 Mbps request, and the transcode came out at 105 Mbps
                    // against a 4.5 Mbps target. That measures the pathology of the input, not the
                    // encoder settings. Real footage is mostly smooth with detail on top, so:
                    // moving gradients and bands (compressible structure, real motion) plus a small
                    // noise floor (stops it being trivially cheap). Rate control can work on this.
                    for (y in 0 until h) {
                        val row = y * w
                        for (x in 0 until w) {
                            val band = ((x + frame * 6) shr 4) and 0x0F
                            val grad = (x + y + frame * 3) and 0xFF
                            val v = (grad / 2 + band * 8 + rnd.nextInt(12)) and 0xFF
                            frameBytes[row + x] = v.toByte()
                        }
                    }
                    // Chroma: slowly drifting, near-neutral — like a real scene, not confetti.
                    for (i in ySize until frameBytes.size) {
                        frameBytes[i] = (128 + ((frame * 2 + i) and 0x0F) - 8).toByte()
                    }
                    buf.put(frameBytes)
                    codec.queueInputBuffer(inIdx, 0, frameBytes.size, frame * 33_333L, 0)
                } else {
                    codec.queueInputBuffer(inIdx, 0, 0, frame * 33_333L,
                        android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                }
                frame++
            }
            val outIdx = codec.dequeueOutputBuffer(info, 10_000)
            when {
                outIdx == android.media.MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    track = muxer.addTrack(codec.outputFormat); muxer.start(); started = true
                }
                outIdx >= 0 -> {
                    val out = codec.getOutputBuffer(outIdx)!!
                    if (info.size > 0 && started &&
                        info.flags and android.media.MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        muxer.writeSampleData(track, out, info)
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if (info.flags and android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) done = true
                }
            }
        }
        muxer.stop(); muxer.release(); codec.stop(); codec.release()
    }

    private class Shape(val bytes: Long, val w: Int, val h: Int, val ms: Long, val rotation: Int, val mime: String) {
        val bitrate get() = if (ms > 0) (bytes * 8 * 1000 / ms).toInt() else 0
        override fun toString() =
            "%.2f MB · %dx%d · %.2fs · %d kbps · rot %d · %s"
                .format(bytes / 1_048_576.0, w, h, ms / 1000.0, bitrate / 1000, rotation, mime)
    }

    private fun shapeOf(f: File): Shape =
        android.media.MediaMetadataRetriever().use { r ->
            r.setDataSource(f.absolutePath)
            fun meta(k: Int) = r.extractMetadata(k)
            var mime = "?"
            val ex = android.media.MediaExtractor().apply { setDataSource(f.absolutePath) }
            for (i in 0 until ex.trackCount) {
                val m = ex.getTrackFormat(i).getString(android.media.MediaFormat.KEY_MIME) ?: continue
                if (m.startsWith("video/")) { mime = m; break }
            }
            ex.release()
            Shape(
                bytes = f.length(),
                w = meta(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0,
                h = meta(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0,
                ms = meta(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0,
                rotation = meta(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0,
                mime = mime,
            )
        }

    /** True if `moov` precedes `mdat` — i.e. a streaming player can start before the last byte. */
    private fun isFaststart(f: File): Boolean {
        val b = f.readBytes()
        var p = 0
        var moovAt = -1
        var mdatAt = -1
        while (p + 8 <= b.size) {
            var size = ((b[p].toLong() and 0xFF) shl 24 or ((b[p + 1].toLong() and 0xFF) shl 16) or
                ((b[p + 2].toLong() and 0xFF) shl 8) or (b[p + 3].toLong() and 0xFF)).toInt()
            val type = String(b, p + 4, 4, Charsets.US_ASCII)
            if (size == 1) size = java.nio.ByteBuffer.wrap(b, p + 8, 8).long.toInt()
            if (size == 0) size = b.size - p
            if (size < 8) break
            if (type == "moov" && moovAt < 0) moovAt = p
            if (type == "mdat" && mdatAt < 0) mdatAt = p
            p += size
        }
        return moovAt in 0 until (if (mdatAt < 0) Int.MAX_VALUE else mdatAt)
    }

    /** Top-level box order as text, e.g. "ftyp(32) mdat(120344) moov(4102)". Evidence, not inference. */
    private fun boxOrder(f: File): String {
        val b = f.readBytes()
        val sb = StringBuilder()
        var p = 0
        while (p + 8 <= b.size) {
            var size = ((b[p].toLong() and 0xFF) shl 24 or ((b[p + 1].toLong() and 0xFF) shl 16) or
                ((b[p + 2].toLong() and 0xFF) shl 8) or (b[p + 3].toLong() and 0xFF)).toInt()
            val type = String(b, p + 4, 4, Charsets.US_ASCII)
            if (size == 1) size = java.nio.ByteBuffer.wrap(b, p + 8, 8).long.toInt()
            if (size == 0) size = b.size - p
            if (size < 8) { sb.append("<bad size $size at $p>"); break }
            sb.append(type).append('(').append(size).append(") ")
            p += size
        }
        return sb.toString().trim()
    }

    private fun log(msg: String) = android.util.Log.i("TranscodeTarget", msg)

    /**
     * The headline: a fat 1080p original goes through the real posting path and comes out at the
     * target. Every number below is measured from the bytes the app would actually seal and send.
     */
    @Test
    fun a1080pOriginalIsReencodedToTheExplicitBitrate() {
        val src = File(ctx.cacheDir, "tt-src.mp4")
        // 4 seconds of noisy 1080p asking for 12 Mbps — the shape of a phone camera original.
        makeSourceVideo(src, 1920, 1080, frames = 120, srcBitrate = 12_000_000, rotation = 0)
        val before = shapeOf(src)
        log("BEFORE  $before")
        assertTrue("fixture must be substantial or the comparison is vacuous, was $before",
            before.bytes > 1_000_000)

        val out = readVideoBytes(ctx, android.net.Uri.fromFile(src))
        assertNotNull("readVideoBytes returned nothing — the transcode path failed outright", out)
        val dst = File(ctx.cacheDir, "tt-out.mp4").apply { writeBytes(out!!) }
        val after = shapeOf(dst)
        log("AFTER   $after")
        log("RATIO   %.2f MB -> %.2f MB (%.0f%% of original)".format(
            before.bytes / 1_048_576.0, after.bytes / 1_048_576.0,
            100.0 * after.bytes / before.bytes))
        log("FASTSTART src=${isFaststart(src)} out=${isFaststart(dst)}")

        assertEquals("must be H.264 — Android-decodable everywhere", "video/avc", after.mime)
        assertTrue("must not exceed the 1080p box, was ${after.w}x${after.h}",
            maxOf(after.w, after.h) <= MediaTargets.VIDEO_LONG_EDGE &&
                minOf(after.w, after.h) <= MediaTargets.VIDEO_SHORT_EDGE)
        assertTrue("duration must survive: ${before.ms}ms -> ${after.ms}ms",
            kotlin.math.abs(before.ms - after.ms) < 500)
        assertTrue("output must be smaller than a 12 Mbps original, got $after",
            after.bytes < before.bytes)
        // The encoder averages TOWARDS the target and the container adds overhead, so allow real
        // headroom rather than asserting the nominal rate. The old path pinned itself at 8 Mbps;
        // anything comfortably under that is the change working.
        assertTrue("overall rate ${after.bitrate / 1000} kbps should be near the " +
            "${MediaTargets.VIDEO_BITRATE / 1000} kbps target, well under the old 8000",
            after.bitrate < MediaTargets.VIDEO_BITRATE * 1.6)
        assertTrue("transcoded output must be faststart (moov before mdat)", isFaststart(dst))

        src.delete(); dst.delete()
    }

    /**
     * The faststart relocation running on genuine MediaMuxer output, not the synthetic boxes the
     * JVM unit test builds. MediaMuxer always writes moov last, so the source proves the problem is
     * real and the output proves we fixed it.
     */
    @Test
    fun muxerOutputIsRewrittenIndexFirst() {
        val src = File(ctx.cacheDir, "fs-src.mp4")
        makeSourceVideo(src, 640, 480, frames = 30, srcBitrate = 2_000_000, rotation = 0)
        log("MediaMuxer source boxes: ${boxOrder(src)}")
        log("MediaMuxer source faststart? ${isFaststart(src)}")

        val out = readVideoBytes(ctx, android.net.Uri.fromFile(src))!!
        val dst = File(ctx.cacheDir, "fs-out.mp4").apply { writeBytes(out) }
        log("transcoded output boxes: ${boxOrder(dst)}")
        log("transcoded output faststart? ${isFaststart(dst)}")

        // The REQUIREMENT is the postcondition, not the mechanism: whatever the platform's muxer
        // does, the bytes we seal and send must be index-first. If MediaMuxer already emits them
        // that way, Mp4Faststart correctly no-ops and this still holds.
        assertTrue("output must be index-first (moov before mdat)", isFaststart(dst))
        assertEquals("and still decodable", "video/avc", shapeOf(dst).mime)
        src.delete(); dst.delete()
    }

    /**
     * Portrait clips must still play upright. Android does NOT bake rotation into pixels (see
     * MediaTargets) — it carries the standard MP4 display matrix — so the assertion is that the
     * hint SURVIVES the transcode. If it were dropped, every portrait video would arrive sideways.
     */
    @Test
    fun portraitRotationSurvivesTheTranscode() {
        val src = File(ctx.cacheDir, "rot-src.mp4")
        makeSourceVideo(src, 1280, 720, frames = 30, srcBitrate = 4_000_000, rotation = 90)
        val before = shapeOf(src)
        log("ROT BEFORE $before")
        assertEquals("fixture must carry a rotation or the test is vacuous", 90, before.rotation)

        val out = readVideoBytes(ctx, android.net.Uri.fromFile(src))!!
        val dst = File(ctx.cacheDir, "rot-out.mp4").apply { writeBytes(out) }
        val after = shapeOf(dst)
        log("ROT AFTER  $after")
        assertEquals("rotation hint must survive — otherwise portrait plays sideways",
            90, after.rotation)
        src.delete(); dst.delete()
    }

    /**
     * "Optimize" must never make a file bigger.
     *
     * [MediaTargets.VIDEO_BITRATE] is a target, not a ceiling on the source. A clip that is already
     * leaner than 4.5 Mbps would otherwise be re-encoded UP to it — paying bytes AND a generation of
     * quality for the privilege. This was caught by measuring, not by reading the code: the rotation
     * fixture went in at 0.48 MB and came out at 0.59 MB.
     */
    @Test
    fun anAlreadyLeanClipIsNotInflatedByOptimizing() {
        val src = File(ctx.cacheDir, "lean-src.mp4")
        // 720p asking for 1.5 Mbps — comfortably under the 4.5 Mbps target.
        makeSourceVideo(src, 1280, 720, frames = 60, srcBitrate = 1_500_000, rotation = 0)
        val before = shapeOf(src)
        log("LEAN BEFORE $before")
        assertTrue("fixture must actually be leaner than the target, was ${before.bitrate / 1000} kbps",
            before.bitrate < MediaTargets.VIDEO_BITRATE)

        val out = readVideoBytes(ctx, android.net.Uri.fromFile(src))!!
        val dst = File(ctx.cacheDir, "lean-out.mp4").apply { writeBytes(out) }
        val after = shapeOf(dst)
        log("LEAN AFTER  $after")
        log("LEAN ratio %.0f%% of original".format(100.0 * after.bytes / before.bytes))

        assertTrue("optimizing must not inflate: ${before.bytes} -> ${after.bytes} bytes",
            after.bytes <= before.bytes)
        assertTrue("and the clip must survive intact",
            kotlin.math.abs(before.ms - after.ms) < 500 && after.w > 0)
        src.delete(); dst.delete()
    }

    /**
     * The duration probe that gates the 15-minute refusal has to actually work on a real file.
     * The threshold itself is arithmetic; this proves the input to it is real, and that an ordinary
     * short clip is NOT refused (a cap that rejects everything would "pass" a naive test).
     */
    @Test
    fun theDurationProbeThatGatesTheCapReadsRealFiles() {
        val src = File(ctx.cacheDir, "dur-src.mp4")
        makeSourceVideo(src, 640, 480, frames = 60, srcBitrate = 2_000_000, rotation = 0)
        val seconds = shapeOf(src).ms / 1000.0
        log("duration probe read ${"%.2f".format(seconds)}s (cap ${MediaTargets.MAX_VIDEO_SECONDS}s)")
        assertTrue("probe must read a plausible duration, got $seconds", seconds > 1.0 && seconds < 10.0)
        assertTrue("a 2s clip must be far under the cap", seconds < MediaTargets.MAX_VIDEO_SECONDS)
        assertNotNull("and must therefore NOT be refused",
            readVideoBytes(ctx, android.net.Uri.fromFile(src)))
        src.delete()
    }
}
