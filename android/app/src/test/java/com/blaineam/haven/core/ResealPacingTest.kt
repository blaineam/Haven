package com.blaineam.haven.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ResealPacingTest {
    @Test fun aBurstIsCappedAtTheWindowBudget() {
        val p = ResealPacing(perWindow = 6, windowMs = 60_000)
        repeat(6) { assertTrue("ask $it", p.tryAcquire(1_000L + it)) }
        assertFalse(p.tryAcquire(2_000))
    }

    @Test fun theBudgetRefillsAsTheWindowSlides() {
        val p = ResealPacing(perWindow = 2, windowMs = 60_000)
        assertTrue(p.tryAcquire(0)); assertTrue(p.tryAcquire(10_000))
        assertFalse(p.tryAcquire(59_999))
        assertTrue(p.tryAcquire(60_000))      // the first stamp aged out
        assertFalse(p.tryAcquire(60_001))     // the second is still inside the window
        assertTrue(p.tryAcquire(70_000))
    }

    @Test fun aDeniedAskDoesNotConsumeTheBudget() {
        val p = ResealPacing(perWindow = 1, windowMs = 10_000)
        assertTrue(p.tryAcquire(0))
        repeat(5) { assertFalse(p.tryAcquire(1_000L + it)) }
        assertTrue(p.tryAcquire(10_000))      // exactly one window after the only accepted ask
    }

    @Test fun theDefaultPaceIsATrickleNotAStampede() {
        // 734 live puts in two minutes were ~180 asks; the default allows 6 a minute.
        val p = ResealPacing()
        var granted = 0
        for (i in 0 until 180) if (p.tryAcquire(i * 600L)) granted++   // 180 asks over 108 s
        assertTrue("granted $granted", granted <= 12)
    }
}
