package com.blaineam.haven

import java.io.File
import kotlin.random.Random

/**
 * Builds real MP4s for the on-device media tests.
 *
 * Shared by [VideoTranscodeTargetTest] (does the encoder hit its target?) and
 * [MediaReoptimizeInstrumentedTest] (does the PROBE agree, on the same bytes?). Those two questions
 * are only meaningfully connected if they are asked of identical fixtures — a probe tuned against a
 * different generator than the encoder is tested with would let the two drift apart silently, and the
 * thing that drift breaks is convergence: the scan would re-offer output the encoder just produced.
 */
object TestVideoFixture {

    /**
     * A "camera original": [w]x[h] at a deliberately fat [srcBitrate].
     *
     * The content is video-LIKE, which is a narrower target than it sounds. The first version of this
     * fixture was pure `rnd.nextBytes`. Incompressible noise defeats rate control entirely — the
     * emulator's software encoder emitted 255 Mbps against a 12 Mbps request, and the transcode came
     * out at 105 Mbps against a 4.5 Mbps target. That measures the pathology of the input, not the
     * encoder settings. Real footage is mostly smooth with detail on top, so: moving gradients and
     * bands (compressible structure, real motion) plus a small noise floor (stops it being trivially
     * cheap). Rate control can work on this. Flat frames would be just as useless in the other
     * direction — they compress to nothing at any bitrate, so a before/after ratio built on them
     * would prove only that solid colours are cheap.
     */
    fun make(dst: File, w: Int, h: Int, frames: Int, srcBitrate: Int, rotation: Int) {
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
}
