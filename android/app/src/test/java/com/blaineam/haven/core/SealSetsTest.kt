package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The pure rules for which circles a stored media blob is sealed for. */
class SealSetsTest {
    @Test fun the_persisted_form_is_order_free_and_drops_blanks() {
        assertEquals("a,b,c", SealSets.encode(listOf("c", "a", "", "b", "a")))
        assertEquals(setOf("a", "b"), SealSets.decode("a,,b"))
        assertEquals(emptySet<String>(), SealSets.decode(null))
        assertEquals(emptySet<String>(), SealSets.decode(""))
    }

    @Test fun a_seal_covers_a_subset_but_not_a_new_circle() {
        val recorded = setOf("a", "b")
        assertTrue(SealSets.covers(recorded, listOf("b")))
        assertTrue(SealSets.covers(recorded, listOf("b", "a")))
        assertFalse(SealSets.covers(recorded, listOf("a", "c")))
        assertFalse("an unknown seal covers nothing", SealSets.covers(emptySet(), listOf("a")))
    }

    @Test fun the_target_is_wanted_first_then_what_was_already_sealed_for() {
        assertEquals(listOf("b", "a", "c"), SealSets.target(listOf("b", "a"), setOf("c", "a")))
        assertEquals("growing the set never drops an earlier circle", listOf("c", "a", "b"),
            SealSets.target(listOf("c"), setOf("a", "b")))
        assertEquals(listOf("a"), SealSets.target(listOf("a", "a", ""), emptySet()))
    }
}
