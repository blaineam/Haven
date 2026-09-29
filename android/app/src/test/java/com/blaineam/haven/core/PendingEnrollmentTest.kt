package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors apple/HavenLogicTests/ReachPolicyTests.swift `PendingEnrollmentTests` case for case. */
class PendingEnrollmentTest {
    private val relay = "c".repeat(64)
    private val t0 = 1_000_000L

    @Test fun refusalFromFreshTicketRelayRetriesSoon() {
        val p = PendingEnrollment()
        p.noteAdopted(relay, t0)
        assertEquals(PendingEnrollment.Decision.RetrySoon(PendingEnrollment.RETRY_GAP_MS),
            p.onFailure(relay.uppercase(), forbidden = true, nowMs = t0 + 30_000))
        assertTrue(PendingEnrollment.RETRY_GAP_MS <= 15_000)
    }

    @Test fun outageStillBacksOff() {
        val p = PendingEnrollment()
        p.noteAdopted(relay, t0)
        assertEquals(PendingEnrollment.Decision.BackOff, p.onFailure(relay, forbidden = false, nowMs = t0 + 1_000))
    }

    @Test fun windowExpiresToOrdinaryBackoff() {
        val p = PendingEnrollment()
        p.noteAdopted(relay, t0)
        assertEquals(PendingEnrollment.Decision.BackOff,
            p.onFailure(relay, forbidden = true, nowMs = t0 + PendingEnrollment.WINDOW_MS))
        assertFalse(p.anyPending(t0 + PendingEnrollment.WINDOW_MS))
    }

    @Test fun confirmedOrUnknownRelayBacksOff() {
        val p = PendingEnrollment()
        assertEquals(PendingEnrollment.Decision.BackOff, p.onFailure(relay, forbidden = true, nowMs = t0))
        p.noteAdopted(relay, t0)
        assertTrue(p.confirm(relay))
        assertFalse(p.confirm(relay))
        assertEquals(PendingEnrollment.Decision.BackOff, p.onFailure(relay, forbidden = true, nowMs = t0 + 1_000))
    }

    @Test fun grantReopensWindowOnlyForTrackedRelay() {
        val p = PendingEnrollment()
        p.noteAdopted(relay, t0)
        p.refresh(relay, t0 + 280_000)
        assertTrue(p.isPending(relay, t0 + 400_000))
        val other = "d".repeat(64)
        p.refresh(other, t0)
        assertFalse(p.isTracked(other))
    }

    @Test fun refusalHoldsRelayForTheFlatGap() {
        val p = PendingEnrollment()
        p.noteAdopted(relay, t0)
        assertTrue(p.mayAttempt(relay, t0 + 1_000))
        assertEquals(PendingEnrollment.Decision.RetrySoon(PendingEnrollment.RETRY_GAP_MS), p.noteRefusal(relay, t0 + 1_000))
        assertFalse(p.mayAttempt(relay.uppercase(), t0 + 1_001))
        assertFalse(p.mayAttempt(relay, t0 + 1_000 + PendingEnrollment.RETRY_GAP_MS - 1))
        p.noteRefusal(relay, t0 + 5_000)   // in-flight refusal must not push the hold out
        assertTrue(p.mayAttempt(relay, t0 + 1_000 + PendingEnrollment.RETRY_GAP_MS))
    }

    @Test fun grantOrSuccessLiftsTheHold() {
        val p = PendingEnrollment()
        p.noteAdopted(relay, t0)
        p.noteRefusal(relay, t0)
        p.releaseHold(relay)
        assertTrue(p.mayAttempt(relay, t0 + 1))
        p.noteRefusal(relay, t0 + 2)
        assertTrue(p.confirm(relay))
        assertTrue(p.mayAttempt(relay, t0 + 3))
    }

    @Test fun onlyPendingRelaysAreEverHeld() {
        val p = PendingEnrollment()
        assertEquals(PendingEnrollment.Decision.BackOff, p.noteRefusal(relay, t0))
        assertTrue(p.mayAttempt(relay, t0 + 1))
        p.noteAdopted(relay, t0)
        p.noteRefusal(relay, t0 + 1)
        assertTrue(p.mayAttempt(relay, t0 + PendingEnrollment.WINDOW_MS))
    }

    @Test fun ticketTracksEveryTicketRelayAndTheInvitersOwnRelay() {
        val inviter = "e".repeat(64)
        val known = listOf(relay, inviter.uppercase(), "f".repeat(64))
        assertEquals(listOf(relay, inviter),
            PendingEnrollment.relaysToTrack(listOf(relay.uppercase(), relay, "short"), inviter, known))
        assertEquals(listOf(relay), PendingEnrollment.relaysToTrack(listOf(relay), inviter, listOf(relay)))
    }
}
