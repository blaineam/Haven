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
}
