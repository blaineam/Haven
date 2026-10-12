package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The re-optimize driver's observable state: pre-engine scan, totals, and the persisted don't-retry set. */
class MediaReoptimizerStateTest {
    private lateinit var ctx: FakeContext
    private val R = MediaReoptimizer

    @Before fun setUp() {
        ctx = FakeContext()
        R.init(ctx)
        R.engineReady = { false }
        R.candidates.value = emptyList(); R.hasScanned.value = false
    }
    @After fun tearDown() { R.engineReady = { HavenNet.isReady }; R.candidates.value = emptyList() }

    private fun shape(bytes: Long) = MediaOptimizationTarget.Shape(bytes, 1080, "video", 8_000_000, 10.0, "too big")
    private fun cand(ref: String, work: MediaReoptimizer.Work, bytes: Long) =
        MediaReoptimizer.Candidate(ref, "circ", work, shape(bytes), 0L, false)

    @Test fun scanning_before_the_engine_is_up_is_measured_and_empty() {
        R.candidates.value = listOf(cand("vid_old", MediaReoptimizer.Work.REENCODE, 5))
        runBlocking { R.scan() }
        assertTrue(R.candidates.value.isEmpty())
        assertTrue("an empty result is distinguishable from a button that did nothing", R.hasScanned.value)
        assertFalse(R.scanning.value)
        assertEquals(null, R.lastWarning.value)
    }

    @Test fun a_second_scan_is_allowed_once_the_first_finishes() {
        runBlocking { R.scan(); R.scan() }
        assertFalse(R.scanning.value)
    }

    @Test fun totals_count_only_reencodes_for_bytes_and_only_posters_for_the_poster_count() {
        R.candidates.value = listOf(
            cand("vid_a", MediaReoptimizer.Work.REENCODE, 300), cand("vid_b", MediaReoptimizer.Work.REENCODE, 200),
            cand("vid_c", MediaReoptimizer.Work.POSTER_ONLY, 1_000_000))
        assertEquals(500L, R.pendingBytes)
        assertEquals(1, R.posterOnlyCount)
    }

    @Test fun running_with_nothing_to_do_returns_at_once() {
        runBlocking { R.run() }
        assertFalse(R.running.value)
    }

    @Test fun cancel_only_sets_a_latch_the_next_scan_clears() {
        R.cancel()
        runBlocking { R.scan() }   // would abort immediately if the latch survived a scan
        assertTrue(R.hasScanned.value)
    }

    @Test fun the_dont_retry_set_survives_a_restart_and_stays_bounded() {
        val skip = MediaReoptimizer::class.java.getDeclaredMethod("skip", String::class.java).apply { isAccessible = true }
        repeat(MediaReoptimizer.SKIP_CAP + 20) { skip.invoke(R, "ref$it") }
        val saved = ctx.prefs("haven.reoptimize").getStringSet("skip", mutableSetOf())!!
        assertEquals(MediaReoptimizer.SKIP_CAP, saved.size)
        assertTrue("the most recent survive", "ref${MediaReoptimizer.SKIP_CAP + 19}" in saved)
        assertFalse("the oldest are dropped", "ref0" in saved)
        R.init(FakeContext(ctx.allPrefs))   // restart
        val reloaded = MediaReoptimizer::class.java.getDeclaredField("skipped").apply { isAccessible = true }.get(R) as Set<*>
        assertEquals(MediaReoptimizer.SKIP_CAP, reloaded.size)
    }

    @Test fun percent_saved_never_goes_negative_and_survives_a_zero_original() {
        assertEquals(50, R.pct(200, 100)); assertEquals(0, R.pct(0, 0)); assertEquals(0, R.pct(100, 150))
    }
}
