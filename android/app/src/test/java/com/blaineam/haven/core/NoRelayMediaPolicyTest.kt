package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NoRelayMediaPolicyTest {
    @Test fun aFetchThatAskedNoRelayDoesNotClaimTheRelaysAnsweredEmpty() {
        assertFalse(NoRelayMediaPolicy.relaysAnsweredEmpty(0))
        assertTrue(NoRelayMediaPolicy.relaysAnsweredEmpty(1))
        assertTrue(NoRelayMediaPolicy.relaysAnsweredEmpty(3))
    }

    @Test fun aHintWeCanActOnIsNeverReAsked() {
        assertFalse(NoRelayMediaPolicy.reAskAfterUnusableHint(hasRelay = true, priorReasks = 0, lastReaskMs = null, nowMs = 10_000))
    }

    @Test fun theFirstUnusableHintIsReAskedImmediately() {
        assertTrue(NoRelayMediaPolicy.reAskAfterUnusableHint(hasRelay = false, priorReasks = 0, lastReaskMs = null, nowMs = 10_000))
    }

    @Test fun reAsksAreSpacedAndCappedAtTheAuthorsHintBudget() {
        val t0 = 100_000L
        // Too soon after the last one.
        assertFalse(NoRelayMediaPolicy.reAskAfterUnusableHint(false, 1, t0, t0 + NoRelayMediaPolicy.REASK_SPACING_MS - 1))
        // Spaced out → allowed, up to the budget.
        assertTrue(NoRelayMediaPolicy.reAskAfterUnusableHint(false, 1, t0, t0 + NoRelayMediaPolicy.REASK_SPACING_MS))
        assertTrue(NoRelayMediaPolicy.reAskAfterUnusableHint(false, NoRelayMediaPolicy.MAX_REASKS_PER_REF - 1, t0, t0 + 60_000))
        // Budget spent: the author streams on the next ask (hints exhausted) — never an endless loop.
        assertFalse(NoRelayMediaPolicy.reAskAfterUnusableHint(false, NoRelayMediaPolicy.MAX_REASKS_PER_REF, t0, t0 + 60_000))
    }

    @Test fun theReAskBudgetMatchesTheAuthorsHintBudget() {
        assertEquals(HeavyWorkPolicy.MAX_RELAY_HINTS, NoRelayMediaPolicy.MAX_REASKS_PER_REF)
    }

    @Test fun theIntroNudgeIsRateLimitedAndOnlyForRelaylessCircles() {
        val now = 1_000_000L
        assertFalse(NoRelayMediaPolicy.introNudgeDue(hasRelay = true, lastNudgeMs = null, nowMs = now))
        assertTrue(NoRelayMediaPolicy.introNudgeDue(hasRelay = false, lastNudgeMs = null, nowMs = now))
        assertFalse(NoRelayMediaPolicy.introNudgeDue(false, now - 1_000, now))
        assertTrue(NoRelayMediaPolicy.introNudgeDue(false, now - NoRelayMediaPolicy.INTRO_NUDGE_EVERY_MS, now))
    }
}
