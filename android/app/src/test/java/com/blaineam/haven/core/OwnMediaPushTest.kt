package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The own-device push obeys the satellite gate, and what it holds back goes on the next pass. */
class OwnMediaPushTest {
    private val refs = listOf("img_full", "img_prev", "img_other")
    private val satelliteSafe = setOf("img_prev")

    @Test fun ultra_constrained_pushes_only_satellite_safe_media() {
        val pushed = mutableSetOf<String>()
        val picked = OwnMediaPush.pick(refs, pushed, budget = 10, eligible = { true },
            mayMoveOverLink = { HeavyWorkPolicy.mayMoveOverLink(ultraConstrained = true, satelliteSafe = it in satelliteSafe) })
        assertEquals(listOf("img_prev"), picked)
        assertFalse("a held ref must not be marked pushed", "img_full" in pushed)
    }

    @Test fun held_media_goes_out_once_the_link_improves() {
        val pushed = mutableSetOf<String>()
        OwnMediaPush.pick(refs, pushed, 10, { true }) { it in satelliteSafe }
        val later = OwnMediaPush.pick(refs, pushed, 10, { true }) { true }
        assertEquals(listOf("img_full", "img_other"), later)
        assertTrue(pushed.containsAll(refs))
    }

    @Test fun budget_counts_only_sent_refs_and_ineligible_refs_are_skipped() {
        val pushed = mutableSetOf("img_full")
        val picked = OwnMediaPush.pick(listOf("img_full", "img_gone", "a", "b", "c"), pushed, budget = 2,
            eligible = { it != "img_gone" }) { true }
        assertEquals(listOf("a", "b"), picked)
    }
}
