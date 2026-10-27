package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaRestorePlanTest {
    @Test fun freshFullSizeMediaOutranksTheBacklogAndEverythingElseDoesNot() {
        assertEquals(MediaRestorePlan.Lane.PRIORITY, MediaRestorePlan.fullSizeLane(fresh = true))
        assertEquals(MediaRestorePlan.Lane.BACKLOG, MediaRestorePlan.fullSizeLane(fresh = false))
    }

    @Test fun theNewestPostsThumbsRideThePriorityLaneUpToTheCap() {
        assertEquals(MediaRestorePlan.Lane.PRIORITY, MediaRestorePlan.thumbLane(0, backfill = false))
        assertEquals(MediaRestorePlan.Lane.PRIORITY, MediaRestorePlan.thumbLane(MediaRestorePlan.PRIORITY_THUMB_CAP - 1, backfill = false))
        // Past the cap a huge feed's thumbs queue behind the backlog instead of starving fresh media.
        assertEquals(MediaRestorePlan.Lane.BACKLOG, MediaRestorePlan.thumbLane(MediaRestorePlan.PRIORITY_THUMB_CAP, backfill = false))
    }

    @Test fun aBackfilledPostsThumbNeverRidesThePriorityLaneEvenWhenItIsRankedNewest() {
        assertEquals(MediaRestorePlan.Lane.BACKLOG, MediaRestorePlan.thumbLane(0, backfill = true))
    }

    @Test fun interleaveRoundRobinsCirclesAndKeepsEachCirclesOrder() {
        val out = MediaRestorePlan.interleave(listOf(listOf("d1", "d2", "d3", "d4"), listOf("m1", "m2")))
        assertEquals(listOf("d1", "m1", "d2", "m2", "d3", "d4"), out)
    }

    @Test fun aStuckCirclesBacklogCannotPushAnotherCirclesFirstRefBack() {
        val doomed = (1..500).map { "old$it" }
        val out = MediaRestorePlan.interleave(listOf(doomed, listOf("dm1", "dm2")))
        assertEquals(1, out.indexOf("dm1"))
        assertEquals(3, out.indexOf("dm2"))
        assertEquals(502, out.size)
    }

    @Test fun interleaveOfNothingIsEmpty() {
        assertTrue(MediaRestorePlan.interleave(emptyList<List<String>>()).isEmpty())
        assertTrue(MediaRestorePlan.interleave(listOf(emptyList<String>(), emptyList())).isEmpty())
    }

    @Test fun theCoreFeedIsOldestFirstSoTheScanMustWalkItReversedToGetNewestFirst() {
        // build_feed documents "oldest-first"; requestMissingMedia reverses it. This pins the
        // contract the planner's callers rely on: after reversal the newest post's ref leads.
        val feedOldestFirst = listOf("week-old", "yesterday", "just-now")
        val newestFirst = feedOldestFirst.asReversed()
        assertEquals("just-now", MediaRestorePlan.interleave(listOf(newestFirst)).first())
    }

    @Test fun aLivenessProofCoversMissesForTheTtlAndExpiresAfterwards() {
        var now = 1_000L
        val cache = AliveProbeCache(ttlMs = 60_000L, clock = { now })
        assertFalse(cache.recentlyAlive("https://relay.example/"))
        cache.noteAlive("https://relay.example/")
        assertTrue(cache.recentlyAlive("https://relay.example"))      // trailing slash is the same base
        now += 59_999L
        assertTrue(cache.recentlyAlive("https://relay.example/"))
        now += 2L
        assertFalse(cache.recentlyAlive("https://relay.example/"))
    }

    @Test fun aBaseThatFailsAProbeIsForgottenSoTheNextMissReprobesIt() {
        val cache = AliveProbeCache(ttlMs = 60_000L, clock = { 5L })
        cache.noteAlive("https://a.example")
        cache.forget("https://a.example/")
        assertFalse(cache.recentlyAlive("https://a.example"))
    }
}
