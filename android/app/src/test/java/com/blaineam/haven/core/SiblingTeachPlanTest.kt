package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SiblingTeachPlanTest {
    private val own = "b".repeat(64)   // B's in-app relay
    private val ra = "a".repeat(64)    // A's relay: C_S, C_R
    private val rc = "c".repeat(64)    // B's second relay: C_S only
    private val dead = "d".repeat(64)

    /** multirelay: B's second relay is adopted for the shared circle only, so it is taught to A's
     *  relay for C_S — never for C_R (which B was later removed from) or B's private circle. */
    @Test fun eachCircleTeachesOnlyItsOwnRelays() {
        val relays = mapOf("cS" to listOf(ra, rc), "cR" to listOf(ra), "cB" to emptyList())
        val plan = siblingTeachPlan(listOf("cS", "cR", "cB"), { relays[it] ?: emptyList() }, setOf(ra, rc, own), own)
            .associate { (t, lessons) -> t to lessons.toMap() }
        assertEquals(listOf(own, rc).sorted(), plan[ra]?.get("cS"))
        assertEquals(listOf(own), plan[ra]?.get("cR"))
        assertNull("B's second relay serves no C_R", plan[rc]?.get("cR"))
        assertEquals(listOf(ra, own).sorted(), plan[rc]?.get("cS"))
        assertEquals(listOf(ra, rc).sorted(), plan[own]?.get("cS"))
        assertNull("a circle with only our relay teaches nothing", plan[own]?.get("cB"))
    }

    @Test fun deadRelaysAndSingleRelayCirclesTeachNothing() =
        assertTrue(siblingTeachPlan(listOf("solo", "x"), { if (it == "x") listOf(dead) else emptyList() }, setOf(own), own).isEmpty())
}
