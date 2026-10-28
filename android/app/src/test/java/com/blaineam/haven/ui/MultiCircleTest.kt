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
        sel = MultiCircle.toggle(sel, "c")
        sel = MultiCircle.toggle(sel, "a")
        assertEquals(listOf("b", "a", "c"), MultiCircle.orderedForPosting(sel, t, "b"))
        sel = MultiCircle.toggle(sel, "b")
        assertEquals(listOf("a", "c"), MultiCircle.orderedForPosting(sel, t, "b"))
        assertEquals(listOf("a"), MultiCircle.orderedForPosting(setOf("a", "dm:x", "zzz"), t, "b"))
    }

    @Test fun everyCircleIsSelectableWhateverIsAttached() {
        // Attachments are sealed for the whole chosen set, so nothing is locked to the active circle.
        val t = MultiCircle.targets(all)
        var sel = MultiCircle.initialSelection("b", t)
        for (id in listOf("a", "c")) sel = MultiCircle.toggle(sel, id)
        assertEquals(setOf("a", "b", "c"), sel)
        assertEquals(listOf("b", "a", "c"), MultiCircle.orderedForPosting(sel, t, "b"))
    }

    @Test fun hintOnlyForTwoPlusCirclesOnceAfterFewPosts() {
        assertFalse(MultiCircle.shouldShowHint(1, 10, false))
        assertFalse(MultiCircle.shouldShowHint(3, 2, false))
        assertTrue(MultiCircle.shouldShowHint(2, 3, false))
        assertFalse(MultiCircle.shouldShowHint(2, 9, true))
    }

    @Test fun selectAllClearAndAllSelected() {
        val t = MultiCircle.targets(all)
        assertEquals(setOf("a", "b", "c"), MultiCircle.selectAll(t))
        assertEquals(emptySet<String>(), MultiCircle.clear())
        assertFalse(MultiCircle.allSelected(setOf("b"), t))
        assertFalse(MultiCircle.allSelected(setOf("a", "b"), t))
        assertTrue(MultiCircle.allSelected(MultiCircle.selectAll(t), t))
        assertTrue("extra ids (a DM) do not matter", MultiCircle.allSelected(setOf("a", "b", "c", "dm:x"), t))
        assertFalse("no circles offered = nothing to unselect", MultiCircle.allSelected(emptySet(), emptyList()))
        // Select all then toggling one off flips the button back.
        assertFalse(MultiCircle.allSelected(MultiCircle.toggle(MultiCircle.selectAll(t), "c"), t))
    }
}
