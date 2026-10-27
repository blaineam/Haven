package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors apple/HavenLogicTests/ReachPolicyTests.swift `RelayIntroductionTests` case for case. */
class RelayIntroductionTest {
    private val ra = "a".repeat(64)
    private val rb = "b".repeat(64)

    @Test fun joinSchedulesOnceAndCoalesces() {
        val p = RelayIntroduction()
        assertTrue(p.noteJoined("cS", ra, 1_000))
        assertFalse(p.noteJoined("cA", ra, 1_100))   // already scheduled
        assertEquals(listOf("cA", "cS"), p.drain(listOf("default", "cA", "cS")))
        assertTrue(p.pendingCircles.isEmpty())
    }

    @Test fun samePairIsRateLimited() {
        val p = RelayIntroduction()
        assertTrue(p.noteJoined("cS", ra, 0))
        p.drain(listOf("cS"))
        assertFalse(p.noteJoined("cS", ra.uppercase(), 10_000))
        assertTrue(p.noteJoined("cS", rb, 10_000))   // a different relay is news
        p.drain(listOf("cS"))
        assertTrue(p.noteJoined("cS", ra, RelayIntroduction.REINTRODUCE_GAP_MS + 1))
    }

    @Test fun defaultExpandsAndS3Ignored() {
        val p = RelayIntroduction()
        assertFalse(p.noteJoined("cS", "s3:bucket", 0))
        assertFalse(p.noteJoined("cS", "abc", 0))
        assertTrue(p.noteJoined(RelayIntroduction.ALL_CIRCLES, ra, 0))
        assertEquals(listOf("default", "cS"), p.drain(listOf("default", "cS")))
    }

    @Test fun enrollGateOpensForANewRelay() {
        val enrolled = setOf(rb)
        assertFalse(RelayIntroduction.enrollDue(60_000, 0, enrolled, listOf(rb), force = false))
        assertTrue(RelayIntroduction.enrollDue(60_000, 0, enrolled, listOf(rb, ra), force = false))
        assertTrue(RelayIntroduction.enrollDue(RelayIntroduction.ENROLL_GAP_MS, 0, enrolled, listOf(rb), force = false))
        assertTrue(RelayIntroduction.enrollDue(1, null, emptySet(), listOf(rb), force = false))
        assertTrue(RelayIntroduction.enrollDue(1, 0, enrolled, listOf(rb), force = true))
    }

    // --- Track R: a member that joined without an approval, and a LOST enroll, must not wait 10 minutes ---

    @Test fun aNewMemberSetReopensTheGateWithoutWaitingTenMinutes() {
        val enrolled = setOf(ra)
        // Steady state: nothing changed, 1 minute later → not due.
        assertFalse(RelayIntroduction.enrollDue(60_000, 0, enrolled, listOf(ra), force = false))
        // The same minute, but the relay has not heard the current member set (a linked device or a
        // contact added from another device joined) → due now.
        assertTrue(RelayIntroduction.enrollDue(60_000, 0, enrolled, listOf(ra), force = false, membersChanged = true))
    }

    @Test fun aFailedEnrollRetriesInAMinuteNotTen() {
        val enrolled = setOf(ra)
        val last = 1_000L
        // The attempt did not land (relay down / dial failed / refused): too soon to hammer it…
        assertFalse(RelayIntroduction.enrollDue(last + 30_000, last, enrolled, listOf(ra), force = false, lastLanded = false))
        // …but a minute later it is due, far inside the 10-minute steady-state gate.
        assertTrue(RelayIntroduction.enrollDue(last + RelayIntroduction.ENROLL_RETRY_GAP_MS, last, enrolled, listOf(ra), force = false, lastLanded = false))
        assertTrue(RelayIntroduction.ENROLL_RETRY_GAP_MS < RelayIntroduction.ENROLL_GAP_MS)
    }

    @Test fun aRelayThatNeverAnswersTheVerbIsNotRedialedEveryTick() {
        // After a failed attempt even a CHANGED member set waits the retry gap (an older relay answers
        // `ERR verb` forever; the sync tick is 20 s).
        val enrolled = setOf(ra)
        assertFalse(RelayIntroduction.enrollDue(21_000, 1_000, enrolled, listOf(ra), force = false,
            membersChanged = true, lastLanded = false))
    }

    @Test fun forceAndNewRelayStillWinOverEverything() {
        val enrolled = setOf(ra)
        assertTrue(RelayIntroduction.enrollDue(2_000, 1_000, enrolled, listOf(ra), force = true, lastLanded = false))
        assertTrue(RelayIntroduction.enrollDue(2_000, 1_000, enrolled, listOf(ra, rb), force = false, lastLanded = false))
        assertTrue(RelayIntroduction.enrollDue(0, null, emptySet(), listOf(ra), force = false))
    }
}
