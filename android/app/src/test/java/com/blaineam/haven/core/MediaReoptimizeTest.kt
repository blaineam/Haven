package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The DECISIONS behind "Re-optimize media I already shared", tested without a device.
 *
 * Everything here is a pure function on purpose (see the two-layer note in
 * [MediaOptimizationTarget]): these are the parts that govern how much CPU the feature burns, whether
 * it can loop forever, and whether it can make a file bigger. The MediaCodec pipeline they drive is
 * covered on a real device by `VideoTranscodeTargetTest`.
 *
 * The single most important case in this file is [ourOwnEncoderOutputReadsAtTarget]. If that ever
 * goes red, the scan stops converging and the button re-encodes the same clips on every tap forever.
 */
class MediaReoptimizeTest {

    private val mb = 1024L * 1024

    // ---- Video: the codec tell ------------------------------------------------------------------

    @Test fun hevcIsAboveTargetEvenWhenSmallAndLean() {
        // 720p HEVC at ~1.2 Mbps: under every dimension and bitrate threshold, and still a rewrite
        // candidate — the optimized path emits H.264 and nothing else, so hvc1 is proof this file
        // came from the passthrough remux or the raw-copy fallback.
        val s = MediaOptimizationTarget.judgeVideo(
            bytes = 3 * mb, width = 1280, height = 720, trackMime = "video/hevc", seconds = 20.0)
        assertNotNull(s)
        assertTrue(s!!.aboveTarget)
        assertTrue(s.aboveTargetReason!!.contains("not H.264"))
    }

    @Test fun ourOwnEncoderOutputReadsAtTarget() {
        // THE LOOP GUARD. 1080p H.264 at the real measured output rate (~4.7 Mbps overall, video +
        // passthrough audio) must judge as ALREADY AT TARGET, or every scan re-offers what the last
        // run just produced.
        val seconds = 60.0
        val bytes = (4_700_000L * seconds / 8).toLong()
        val s = MediaOptimizationTarget.judgeVideo(bytes, 1920, 1080, "video/avc", seconds)
        assertNotNull(s)
        assertNull("encoder output must re-probe as at target: ${s!!.aboveTargetReason}", s.aboveTargetReason)
        assertFalse(s.aboveTarget)
    }

    @Test fun theOldEightMbpsAndroidPathIsAboveTarget() {
        // The exact disease MediaTargets was written to cure: the old "4 bits/pixel clamped to 2–8
        // Mbps" formula pinned every optimized 1080p clip to its 8 Mbps ceiling.
        val seconds = 60.0
        val bytes = (8_000_000L * seconds / 8).toLong()
        val s = MediaOptimizationTarget.judgeVideo(bytes, 1920, 1080, "video/avc", seconds)!!
        assertTrue(s.aboveTarget)
        assertTrue(s.aboveTargetReason!!.contains("kbps"))
    }

    @Test fun oversizedDimensionsAreAboveTargetEvenAtALowRate() {
        // 4K at a modest rate: bitrate alone would wave this through, but every member is storing
        // four times the pixels they can use in a phone feed.
        val s = MediaOptimizationTarget.judgeVideo(50 * mb, 3840, 2160, "video/avc", 120.0)!!
        assertTrue(s.aboveTarget)
        assertTrue(s.aboveTargetReason!!.contains("3840px"))
    }

    @Test fun dimensionSlackToleratesEncoderRounding() {
        // 1920x1088 is what several encoders emit for "1080p" (macroblock rounding). The 2% slack
        // exists so our own output is not perpetually flagged on a rounding artifact.
        val seconds = 60.0
        val bytes = (4_500_000L * seconds / 8).toLong()
        val s = MediaOptimizationTarget.judgeVideo(bytes, 1920, 1088, "video/avc", seconds)!!
        assertFalse("1088px is inside the rounding slack: ${s.aboveTargetReason}", s.aboveTarget)
    }

    @Test fun smallFilesAreNeverCandidates() {
        // Below the interest floor nothing is worth winning, and a re-share costs every member an
        // edit event plus a re-download. Even 4K HEVC.
        val s = MediaOptimizationTarget.judgeVideo(150_000, 3840, 2160, "video/hevc", 3.0)!!
        assertFalse(s.aboveTarget)
    }

    @Test fun unreadableVideoFactsFailClosed() {
        // A file we cannot judge is NOT a candidate — never guess and re-encode.
        assertNull(MediaOptimizationTarget.judgeVideo(5 * mb, 0, 0, "video/avc", 10.0))
        assertNull(MediaOptimizationTarget.judgeVideo(5 * mb, 1920, 1080, "video/avc", 0.0))
        assertNull(MediaOptimizationTarget.judgeVideo(0, 1920, 1080, "video/avc", 10.0))
        assertNull(MediaOptimizationTarget.judgeVideo(5 * mb, 1920, 1080, "video/avc", Double.NaN))
    }

    // ---- Stills ---------------------------------------------------------------------------------

    @Test fun cameraOriginalIsAboveTargetOnDimensions() {
        val s = MediaOptimizationTarget.judgeImage(4 * mb, 4032, 3024, "image/jpeg")!!
        assertTrue(s.aboveTarget)
        assertTrue(s.aboveTargetReason!!.contains("4032px"))
    }

    @Test fun nonJpegIsAboveTargetWhateverItsSize() {
        // A PNG screenshot: the pixel count says nothing, and the optimized path always writes JPEG.
        val s = MediaOptimizationTarget.judgeImage(900_000, 1170, 1000, "image/png")!!
        assertTrue(s.aboveTarget)
        assertTrue(s.aboveTargetReason!!.contains("not a JPEG"))
    }

    @Test fun denseJpegIsAboveTargetOnBytesPerPixel() {
        // 1600px wide but written at q95 (auto-optimize off) — only the density gives it away.
        val bytes = (1600L * 1200 * 0.6).toLong()
        val s = MediaOptimizationTarget.judgeImage(bytes, 1600, 1200, "image/jpeg")!!
        assertTrue(s.aboveTarget)
        assertTrue(s.aboveTargetReason!!.contains("bytes/pixel"))
    }

    @Test fun optimizedStillReadsAtTarget() {
        // The still half of the loop guard: 1600px q62 measures well under 0.40 bytes/pixel.
        val bytes = (1600L * 1200 * 0.20).toLong()
        val s = MediaOptimizationTarget.judgeImage(bytes, 1600, 1200, "image/jpeg")!!
        assertFalse("optimized still must re-probe at target: ${s.aboveTargetReason}", s.aboveTarget)
    }

    // ---- Audio ----------------------------------------------------------------------------------

    @Test fun audioIsNeverACandidate() {
        // Android has no audio-file import path, so every aud_ ref this device authored came from the
        // recorder at 64 kbps mono AAC — provably at target. A candidate the encoder would only have
        // to refuse would burn a batch slot and a skip-set slot on every scan.
        assertFalse(MediaOptimizationTarget.judgeAudio(40 * mb).aboveTarget)
    }

    // ---- Never keep a re-encode that isn't smaller -----------------------------------------------

    @Test fun inflationIsRejected() {
        // The real Android regression: a 720p fixture went 0.48 MB in, 0.59 MB out, because
        // VIDEO_BITRATE is a target and not a ceiling on the source.
        assertFalse(MediaOptimizationTarget.keepsNewEncode(503_316, 618_659))
    }

    @Test fun aMarginalWinIsRejected() {
        // 5% is not worth making every member in the circle re-download the clip.
        assertFalse(MediaOptimizationTarget.keepsNewEncode(100 * mb, 95 * mb))
    }

    @Test fun aRealWinIsAdopted() {
        // The measured case this feature exists for: 305.7 MB → 37.7 MB.
        assertTrue(MediaOptimizationTarget.keepsNewEncode(320_567_296, 39_530_496))
    }

    @Test fun degenerateSizesAreRejected() {
        assertFalse(MediaOptimizationTarget.keepsNewEncode(0, 100))
        assertFalse(MediaOptimizationTarget.keepsNewEncode(100 * mb, 0))
    }

    // ---- Age is reported, never enforced --------------------------------------------------------

    @Test fun legacyByAgeSplitsOnTheEncoderCutoff() {
        assertTrue(MediaOptimizationTarget.isLegacyByAge(MediaOptimizationTarget.LEGACY_CUTOFF_MS - 1))
        assertFalse(MediaOptimizationTarget.isLegacyByAge(MediaOptimizationTarget.LEGACY_CUTOFF_MS))
        assertFalse(MediaOptimizationTarget.isLegacyByAge(MediaOptimizationTarget.LEGACY_CUTOFF_MS + 86_400_000))
    }

    // ---- The batch mechanics --------------------------------------------------------------------

    @Test fun rewriteMediaPreservesOrderAndPassesEverythingElseThrough() {
        // A post's media array carries synthetic refs (geo: location pins) that have no bytes, plus
        // attachments this batch did not touch. Reordering or dropping either would corrupt a post
        // the user never edited.
        val media = listOf("img_aaa", "geo:37.77,-122.41", "vid_bbb", "img_ccc")
        val swap = mapOf("img_aaa" to "img_zzz", "vid_bbb" to "vid_yyy")
        assertEquals(
            listOf("img_zzz", "geo:37.77,-122.41", "vid_yyy", "img_ccc"),
            MediaReoptimizer.rewriteMedia(media, swap),
        )
    }

    @Test fun rewriteMediaIsANoOpWhenNothingMatches() {
        val media = listOf("img_aaa", "img_bbb")
        assertEquals(media, MediaReoptimizer.rewriteMedia(media, mapOf("vid_zzz" to "vid_yyy")))
    }

    @Test fun aSwapOnlyAppliesInTheCircleItsBlobWasSealedTo() {
        // Android seals media per circle and keeps ONE file per ref, so a blob re-encoded while
        // walking circle A opens with A's key alone. Rewriting circle B's post to the same new ref
        // would put a blob this device cannot open where the user's own photo used to be. B keeps
        // the OLD ref, which still exists and still works. (This models the filter in run().)
        val swap = mapOf("img_a" to "img_new", "vid_b" to "vid_new")
        val sealedTo = mapOf("img_a" to "circleA", "vid_b" to "circleA")

        val inA = swap.filterKeys { sealedTo[it] == "circleA" }
        assertEquals(listOf("img_new", "geo:1,2"),
            MediaReoptimizer.rewriteMedia(listOf("img_a", "geo:1,2"), inA))

        val inB = swap.filterKeys { sealedTo[it] == "circleB" }
        assertTrue("nothing may be swapped in a circle the blob was not sealed to", inB.isEmpty())
        assertEquals(listOf("img_a", "geo:1,2"),
            MediaReoptimizer.rewriteMedia(listOf("img_a", "geo:1,2"), inB))
    }

    @Test fun candidatesAreOrderedBiggestFirst() {
        // The win is dominated by a handful of videos, so a user who runs ONE batch of 25 and stops
        // should still have captured most of the saving.
        val c = listOf(shaped("a", 5 * mb), shaped("b", 300 * mb), shaped("c", 40 * mb))
        assertEquals(listOf("b", "c", "a"), MediaReoptimizer.ordered(c).map { it.ref })
    }

    @Test fun theSkipSetIsBoundedAndKeepsTheMostRecent() {
        var set: Set<String> = emptySet()
        for (i in 1..600) set = MediaReoptimizer.boundSkipSet(set, "ref$i", cap = 500)
        assertEquals(500, set.size)
        assertFalse("oldest entries must be evicted", set.contains("ref1"))
        assertFalse(set.contains("ref100"))
        assertTrue("newest entries must survive", set.contains("ref600"))
        assertTrue(set.contains("ref101"))
    }

    @Test fun skippingTheSameRefTwiceDoesNotGrowTheSet() {
        var set: Set<String> = emptySet()
        set = MediaReoptimizer.boundSkipSet(set, "vid_x")
        set = MediaReoptimizer.boundSkipSet(set, "vid_x")
        assertEquals(1, set.size)
    }

    // ---- Disk headroom --------------------------------------------------------------------------

    @Test fun aTightDiskRefusesTheItem() {
        // Room is needed for the decrypt (~source size), the encoded output, and a margin. Filling
        // the disk in a loop is the other way a job like this ruins someone's day.
        assertFalse(MediaReoptimizer.hasDiskHeadroom(freeBytes = 300 * mb, bytes = 300 * mb))
        assertFalse(MediaReoptimizer.hasDiskHeadroom(freeBytes = 600 * mb, bytes = 300 * mb))
    }

    @Test fun aRoomyDiskAllowsTheItem() {
        assertTrue(MediaReoptimizer.hasDiskHeadroom(freeBytes = 4096 * mb, bytes = 300 * mb))
    }

    @Test fun unknownFreeSpaceDoesNotBlock() {
        // usableSpace returning 0 means "could not determine" here — failing closed would make the
        // button permanently dead on devices where the query fails.
        assertTrue(MediaReoptimizer.hasDiskHeadroom(freeBytes = 0, bytes = 300 * mb))
    }

    // ---- Reporting ------------------------------------------------------------------------------

    @Test fun percentSavedIsTheRealNumber() {
        assertEquals(89, MediaReoptimizer.pct(320_000_000, 38_000_000))
        assertEquals(0, MediaReoptimizer.pct(0, 0))
        assertEquals(0, MediaReoptimizer.pct(100, 250))   // never reports a negative saving
    }

    @Test fun rewriteMediaAddsPosterOnlyWithoutTouchingVideo() {
        val media = listOf("vid_old", "img_still")
        val out = MediaReoptimizer.rewriteMedia(
            media, emptyMap(), mapOf("vid_old" to "img_poster"),
        )
        assertEquals(
            listOf("img_poster", "poster:vid_old:img_poster", "vid_old", "img_still"),
            out,
        )
    }

    @Test fun rewriteMediaReencodeReplacesPosterAndVideo() {
        val media = MediaVariants.composeVideoMedia("img_oldp", "vid_a", null)
        val out = MediaReoptimizer.rewriteMedia(
            media, mapOf("vid_a" to "vid_b"), mapOf("vid_a" to "img_newp"),
        )
        assertEquals(listOf("img_newp", "poster:vid_b:img_newp", "vid_b"), out)
        assertFalse(out.contains("img_oldp"))
        assertFalse(out.contains("vid_a"))
    }

    private fun shaped(ref: String, bytes: Long) = MediaReoptimizer.Candidate(
        ref = ref, circleId = "c", work = MediaReoptimizer.Work.REENCODE,
        shape = MediaOptimizationTarget.Shape(bytes, 1920, "video/avc", 8_000_000, 10.0, "test"),
        firstSharedMs = 0, legacyByAge = true,
    )
}
