package com.blaineam.haven.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MultiCircleTest {
    private val all = listOf(PostTarget("a", "Family"), PostTarget("dm:x", "Sam"), PostTarget("b", "Work"),
        PostTarget("c", "Club"), PostTarget("a", "Family dup"))

    @Test fun dmsAndDuplicatesExcluded() {
        assertEquals(listOf("a", "b", "c"), MultiCircle.targets(all).map { it.id })
    }

    @Test fun currentPreChecked() {
        val t = MultiCircle.targets(all)
        assertEquals(setOf("b"), MultiCircle.initialSelection("b", t))
        assertEquals(emptySet<String>(), MultiCircle.initialSelection("dm:x", t))
    }

    @Test fun toggleAndOrdering() {
        val t = MultiCircle.targets(all)
        var sel = MultiCircle.initialSelection("b", t)
        sel = MultiCircle.toggle(sel, "c", "b", false)
        sel = MultiCircle.toggle(sel, "a", "b", false)
        assertEquals(listOf("b", "a", "c"), MultiCircle.orderedForPosting(sel, t, "b"))
        sel = MultiCircle.toggle(sel, "b", "b", false)
        assertEquals(listOf("a", "c"), MultiCircle.orderedForPosting(sel, t, "b"))
        assertEquals(listOf("a"), MultiCircle.orderedForPosting(setOf("a", "dm:x", "zzz"), t, "b"))
    }

    @Test fun blobMediaLimitsToActive() {
        assertTrue(MultiCircle.isSelectable("b", "b", true))
        assertFalse(MultiCircle.isSelectable("a", "b", true))
        assertEquals(setOf("b"), MultiCircle.toggle(setOf("b"), "a", "b", true))
    }

    @Test fun hintOnlyForTwoPlusCirclesOnceAfterFewPosts() {
        assertFalse(MultiCircle.shouldShowHint(1, 10, false))
        assertFalse(MultiCircle.shouldShowHint(3, 2, false))
        assertTrue(MultiCircle.shouldShowHint(2, 3, false))
        assertFalse(MultiCircle.shouldShowHint(2, 9, true))
    }
}
