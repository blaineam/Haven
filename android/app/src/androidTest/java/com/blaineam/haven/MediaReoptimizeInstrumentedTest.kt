package com.blaineam.haven

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.blaineam.haven.core.MediaOptimizationTarget
import com.blaineam.haven.core.MediaTargets
import com.blaineam.haven.core.downscaleJpeg
import com.blaineam.haven.core.readVideoBytes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * The re-optimize PROBE, run against bytes a real codec produced.
 *
 * `MediaReoptimizeTest` (JVM) proves the decision arithmetic. It cannot prove the arithmetic is
 * pointed at the right numbers: whether `MediaExtractor` reports the track MIME this code expects,
 * whether `MediaMetadataRetriever` reports a duration at all, and — the one that matters most —
 * whether the encoder's OWN output actually lands under the ceiling on real hardware.
 *
 * That last one is [transcodeOutputProbesAtTargetSoTheScanConverges]. If it goes red, the button
 * offers the same clips forever and re-encodes a user's library on every tap. It is the reason this
 * file exists.
 */
@RunWith(AndroidJUnit4::class)
class MediaReoptimizeInstrumentedTest {

    private val ctx get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun log(msg: String) = android.util.Log.i("ReoptimizeProbe", msg)

    // ---- Video ----------------------------------------------------------------------------------

    @Test
    fun aFatOriginalProbesAboveTarget() {
        // The shape of the problem: a 12 Mbps 1080p camera original, the kind of thing that made one
        // device hold 53 items / 1.3 GB.
        val src = File(ctx.cacheDir, "ro-fat.mp4")
        TestVideoFixture.make(src, 1920, 1080, frames = 120, srcBitrate = 12_000_000, rotation = 0)
        val shape = MediaOptimizationTarget.probeVideoFile(src)
        assertNotNull("probe must read a real MP4 — MediaExtractor/MMR wiring", shape)
        log("FAT ${shape!!.bytes / 1_048_576.0} MB · ${shape.codec} · ${shape.maxDimension}px · " +
            "${shape.bitrate / 1000} kbps · reason=${shape.aboveTargetReason}")
        assertEquals("video/avc", shape.codec)
        assertTrue("a 12 Mbps original must be a candidate, probe said: ${shape.aboveTargetReason}",
            shape.aboveTarget)
        src.delete()
    }

    @Test
    fun transcodeOutputProbesAtTargetSoTheScanConverges() {
        // THE CONVERGENCE PROOF, on real bytes. Encode through the same entry point the re-optimize
        // pass uses (forceOptimize = true), then hand the result straight back to the probe. It must
        // come back AT TARGET, or every scan re-offers what the last run just produced.
        val src = File(ctx.cacheDir, "ro-conv-src.mp4")
        TestVideoFixture.make(src, 1920, 1080, frames = 120, srcBitrate = 12_000_000, rotation = 0)
        val before = MediaOptimizationTarget.probeVideoFile(src)!!
        assertTrue("fixture must start above target or this test is vacuous", before.aboveTarget)

        val out = readVideoBytes(ctx, android.net.Uri.fromFile(src),
            MediaTargets.MAX_VIDEO_BYTES, forceOptimize = true)
        assertNotNull("the re-optimize encode path returned nothing", out)
        val dst = File(ctx.cacheDir, "ro-conv-out.mp4").apply { writeBytes(out!!) }

        val after = MediaOptimizationTarget.probeVideoFile(dst)
        assertNotNull(after)
        log("CONVERGE before=${before.bitrate / 1000} kbps/${before.maxDimension}px " +
            "after=${after!!.bitrate / 1000} kbps/${after.maxDimension}px " +
            "ceiling=${MediaOptimizationTarget.videoBitrateCeiling / 1000} kbps " +
            "reason=${after.aboveTargetReason}")
        assertNull("re-encoded output must probe AT TARGET or the scan never converges — " +
            "reason was: ${after.aboveTargetReason}", after.aboveTargetReason)
        assertFalse(after.aboveTarget)

        // And it must have been worth doing at all.
        assertTrue("a 12 Mbps original should shrink enough to adopt: ${before.bytes} -> ${after.bytes}",
            MediaOptimizationTarget.keepsNewEncode(before.bytes, after.bytes))
        src.delete(); dst.delete()
    }

    @Test
    fun anAlreadyLeanClipIsNotAdoptedEvenIfItProbesAboveTarget() {
        // The anti-inflation rule, end to end. A 1.5 Mbps 720p clip is already leaner than the
        // target; whatever comes back, it must not be kept unless it is genuinely smaller. This is
        // the case that made a 0.48 MB fixture come out at 0.59 MB.
        val src = File(ctx.cacheDir, "ro-lean.mp4")
        TestVideoFixture.make(src, 1280, 720, frames = 60, srcBitrate = 1_500_000, rotation = 0)
        val before = MediaOptimizationTarget.probeVideoFile(src)!!
        val out = readVideoBytes(ctx, android.net.Uri.fromFile(src),
            MediaTargets.MAX_VIDEO_BYTES, forceOptimize = true)!!
        log("LEAN ${before.bytes} B in -> ${out.size} B out; adopt=" +
            "${MediaOptimizationTarget.keepsNewEncode(before.bytes, out.size.toLong())}")
        if (out.size >= before.bytes * MediaOptimizationTarget.REQUIRED_SHRINK_FACTOR) {
            assertFalse("must refuse to adopt a re-encode that is not clearly smaller",
                MediaOptimizationTarget.keepsNewEncode(before.bytes, out.size.toLong()))
        }
        src.delete()
    }

    @Test
    fun aTinyClipIsNeverACandidate() {
        // The interest floor, on a real file rather than a made-up byte count.
        val src = File(ctx.cacheDir, "ro-tiny.mp4")
        TestVideoFixture.make(src, 320, 240, frames = 10, srcBitrate = 200_000, rotation = 0)
        val shape = MediaOptimizationTarget.probeVideoFile(src)!!
        log("TINY ${shape.bytes} B · reason=${shape.aboveTargetReason}")
        if (shape.bytes < MediaOptimizationTarget.MINIMUM_INTERESTING_BYTES) {
            assertFalse("below the interest floor nothing should be offered", shape.aboveTarget)
        }
        src.delete()
    }

    @Test
    fun anUnreadableFileFailsClosed() {
        // A blob we cannot judge must NOT become a re-encode candidate.
        val junk = File(ctx.cacheDir, "ro-junk.mp4").apply { writeBytes(ByteArray(4096) { 0x5A }) }
        assertNull(MediaOptimizationTarget.probeVideoFile(junk))
        junk.delete()
    }

    // ---- The driver itself ----------------------------------------------------------------------

    @Test
    fun scanIsSafeAndInertBeforeTheEngineIsUp() = kotlinx.coroutines.runBlocking {
        // Boot order, and the BOUNDING promise. `MediaReoptimizer.init` is wired into HavenNet's
        // startup purely to read the persisted skip set; it must not touch the engine, must not
        // throw when nothing else is initialised, and above all must not start any work of its own.
        // A scan against a not-yet-ready HavenNet has to come back cleanly with nothing to do.
        com.blaineam.haven.core.MediaReoptimizer.init(ctx)
        assertFalse("init must not start a run", com.blaineam.haven.core.MediaReoptimizer.running.value)
        assertFalse("init must not start a scan", com.blaineam.haven.core.MediaReoptimizer.scanning.value)

        com.blaineam.haven.core.MediaReoptimizer.scan()

        assertTrue("a completed scan must say so, even when it found nothing",
            com.blaineam.haven.core.MediaReoptimizer.hasScanned.value)
        assertTrue(com.blaineam.haven.core.MediaReoptimizer.candidates.value.isEmpty())
        assertFalse(com.blaineam.haven.core.MediaReoptimizer.scanning.value)
        assertEquals(0L, com.blaineam.haven.core.MediaReoptimizer.pendingBytes)

        // And run() with nothing queued is a no-op rather than a crash.
        com.blaineam.haven.core.MediaReoptimizer.run()
        assertFalse(com.blaineam.haven.core.MediaReoptimizer.running.value)
    }

    // ---- Stills ---------------------------------------------------------------------------------

    /** A noisy JPEG at [dim]x[dim] and [quality] — noise so the encoder actually spends its budget. */
    private fun makeJpeg(dim: Int, quality: Int): ByteArray {
        val bmp = android.graphics.Bitmap.createBitmap(dim, dim, android.graphics.Bitmap.Config.ARGB_8888)
        val rnd = kotlin.random.Random(7)
        val row = IntArray(dim)
        for (y in 0 until dim) {
            for (x in 0 until dim) {
                val g = (x + y) and 0xFF
                val n = rnd.nextInt(40)
                row[x] = (0xFF shl 24) or (((g + n) and 0xFF) shl 16) or
                    ((((g / 2) + n) and 0xFF) shl 8) or ((g / 3 + n) and 0xFF)
            }
            bmp.setPixels(row, 0, dim, 0, y, dim, 1)
        }
        return ByteArrayOutputStream()
            .also { bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, quality, it) }
            .toByteArray()
    }

    @Test
    fun aCameraOriginalStillProbesAboveTargetAndConvergesAfterRewriting() {
        // The stills half of the convergence proof, same structure: a 3000px q95 original must read
        // as a candidate, and what downscaleJpeg produces from it must read as at-target.
        val original = makeJpeg(3000, 95)
        val before = MediaOptimizationTarget.probeImageBytes(original)
        assertNotNull("image probe must read real JPEG bytes", before)
        log("STILL BEFORE ${before!!.bytes} B · ${before.codec} · ${before.maxDimension}px · " +
            "reason=${before.aboveTargetReason}")
        assertEquals("image/jpeg", before.codec)
        assertTrue("a 3000px q95 original must be a candidate", before.aboveTarget)

        val rewritten = downscaleJpeg(original, MediaTargets.STILL_LONG_EDGE,
            MediaTargets.STILL_JPEG_QUALITY)
        assertNotNull("the re-optimize still encoder returned nothing", rewritten)
        val after = MediaOptimizationTarget.probeImageBytes(rewritten!!)!!
        log("STILL AFTER  ${after.bytes} B · ${after.maxDimension}px · reason=${after.aboveTargetReason}")
        assertNull("rewritten still must probe AT TARGET or the scan never converges — " +
            "reason was: ${after.aboveTargetReason}", after.aboveTargetReason)
        assertTrue("and it must actually be smaller",
            MediaOptimizationTarget.keepsNewEncode(before.bytes, after.bytes))
    }

    @Test
    fun aPngProbesAboveTargetWhateverItsDensity() {
        // The optimized path always writes JPEG, so a PNG is proof the file came in verbatim.
        val bmp = android.graphics.Bitmap.createBitmap(900, 900, android.graphics.Bitmap.Config.ARGB_8888)
        for (y in 0 until 900) for (x in 0 until 900) bmp.setPixel(x, y, (0xFF shl 24) or ((x * y) and 0xFFFFFF))
        val png = ByteArrayOutputStream()
            .also { bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        val shape = MediaOptimizationTarget.probeImageBytes(png)!!
        log("PNG ${shape.bytes} B · ${shape.codec} · reason=${shape.aboveTargetReason}")
        assertTrue("a PNG must be a candidate: ${shape.codec}", shape.aboveTarget)
        assertTrue(shape.aboveTargetReason!!.contains("not a JPEG"))
    }
}
