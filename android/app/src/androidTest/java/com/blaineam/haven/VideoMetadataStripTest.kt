package com.blaineam.haven

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.blaineam.haven.core.readVideoBytes
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Android shipped picked video bytes verbatim, so a clip recorded with location on carried its
 * capture coordinates to the whole circle. This proves [readVideoBytes] now removes them.
 *
 * Deliberately empirical: the iOS half of this fix looked correct by Apple's API contract
 * (`export.metadata = []`) and still leaked, because location lives in a container box the
 * documented knob doesn't govern. So assert against what the muxer actually wrote, not the docs.
 */
@RunWith(AndroidJUnit4::class)
class VideoMetadataStripTest {

    /** Record a tiny clip whose container carries a location, the way the camera would. */
    private fun makeGpsVideo(dst: File) {
        val w = 320
        val h = 240
        val format = android.media.MediaFormat.createVideoFormat("video/avc", w, h).apply {
            setInteger(android.media.MediaFormat.KEY_COLOR_FORMAT,
                android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(android.media.MediaFormat.KEY_BIT_RATE, 400_000)
            setInteger(android.media.MediaFormat.KEY_FRAME_RATE, 15)
            setInteger(android.media.MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val codec = android.media.MediaCodec.createEncoderByType("video/avc")
        codec.configure(format, null, null, android.media.MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        val muxer = android.media.MediaMuxer(dst.absolutePath, android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        muxer.setLocation(37.7749f, -122.4194f)   // <- the leak under test
        var track = -1
        var started = false
        val info = android.media.MediaCodec.BufferInfo()
        var frame = 0
        var done = false
        while (!done) {
            if (frame < 10) {
                val inIdx = codec.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val buf = codec.getInputBuffer(inIdx)!!
                    buf.clear()
                    val ySize = w * h
                    val data = ByteArray(ySize * 3 / 2) { (frame * 12).toByte() }
                    buf.put(data)
                    codec.queueInputBuffer(inIdx, 0, data.size, frame * 66_666L, 0)
                    frame++
                }
            } else {
                val inIdx = codec.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    codec.queueInputBuffer(inIdx, 0, 0, frame * 66_666L,
                        android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    frame++
                }
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

    /** The container's location string, or null if there is none. This is what leaks. */
    private fun locationOf(f: File): String? =
        android.media.MediaMetadataRetriever().use { r ->
            r.setDataSource(f.absolutePath)
            r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_LOCATION)
        }

    @Test
    fun pickedVideoLosesItsGpsBeforeWeShareIt() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val src = File(ctx.cacheDir, "gps-src.mp4")
        makeGpsVideo(src)

        // The source really does carry GPS — otherwise the test proves nothing.
        val before = locationOf(src)
        assertNotNull("fixture must carry GPS or this test is vacuous", before)
        assertTrue("fixture GPS should be the coords we set, got $before", before!!.contains("37.77"))

        // Read it the way the app does when you attach a video to a post.
        val out = readVideoBytes(ctx, android.net.Uri.fromFile(src))
        assertNotNull("readVideoBytes returned nothing", out)
        val dst = File(ctx.cacheDir, "gps-out.mp4").apply { writeBytes(out!!) }

        // The bytes we'd seal and send must have no location at all.
        val after = locationOf(dst)
        assertNull("shared video still carries location: $after", after)
        assertTrue("stripped video should still have real content", dst.length() > 0)

        src.delete(); dst.delete()
    }
}
