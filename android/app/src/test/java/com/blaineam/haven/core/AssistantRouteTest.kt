package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Send a message to Blaine on Haven": recipient resolution and what a voice command may do. */
class AssistantRouteTest {
    private fun person(id: String, name: String) =
        AssistantRoute.Candidate("dm:$id", AssistantRoute.recipientNames(name))

    private val tracyM = person("tracym", "Tracy Miller")
    private val troy = person("troy", "Troy")
    private val trey = person("trey", "Trey Jones")
    private val blaine = person("blaine", "Blaine Miller")
    private val everyone = listOf(tracyM, troy, trey, blaine)

    private fun open(p: AssistantRoute.Plan): AssistantRoute.Plan.Open {
        assertTrue("expected Open but was $p", p is AssistantRoute.Plan.Open)
        return p as AssistantRoute.Plan.Open
    }

    // ---- recipient resolution ---------------------------------------------------------------

    @Test fun `a first name resolves straight to the one contact with it`() {
        assertEquals("dm:blaine", open(AssistantRoute.plan("Blaine", "hi", everyone)).circleId)
    }

    @Test fun `Tracy never offers Troy or Trey`() {
        val p = open(AssistantRoute.plan("Tracy", null, everyone))
        assertEquals("dm:tracym", p.circleId)
    }

    @Test fun `Tracy M and Tracy Miller both resolve`() {
        assertEquals("dm:tracym", open(AssistantRoute.plan("Tracy M", null, everyone)).circleId)
        assertEquals("dm:tracym", open(AssistantRoute.plan("Tracy Miller", null, everyone)).circleId)
        assertEquals("dm:tracym", open(AssistantRoute.plan("tracy miller", null, everyone)).circleId)
    }

    @Test fun `an exact name beats a longer name containing it`() {
        val tracy = person("tracy", "Tracy")
        val p = open(AssistantRoute.plan("Tracy", null, listOf(tracyM, tracy)))
        assertEquals("dm:tracy", p.circleId)
    }

    @Test fun `two people matching at the same tier are a tie, and only they are offered`() {
        val smith = person("tracys", "Tracy Smith")
        val p = AssistantRoute.plan("Tracy", null, everyone + smith)
        assertTrue(p is AssistantRoute.Plan.Pick)
        assertEquals(setOf("dm:tracym", "dm:tracys"), (p as AssistantRoute.Plan.Pick).tied.toSet())
    }

    @Test fun `a one-letter slip still finds the contact but Tracy does not reach Troy`() {
        assertEquals("dm:tracym", open(AssistantRoute.plan("Tracey", null, everyone)).circleId)
        assertEquals("dm:blaine", open(AssistantRoute.plan("Blain", null, everyone)).circleId)
        assertEquals(AssistantRoute.Plan.Pick(emptyList()), AssistantRoute.plan("Tracy", null, listOf(troy)))
        assertEquals(AssistantRoute.Plan.Pick(emptyList()), AssistantRoute.plan("Tracy", null, listOf(troy, trey)))
    }

    @Test fun `accents and punctuation do not matter`() {
        val zoe = person("zoe", "Zoë O'Brien")
        assertEquals("dm:zoe", open(AssistantRoute.plan("zoe obrien", null, listOf(zoe))).circleId)
        assertEquals("dm:zoe", open(AssistantRoute.plan("ZOE", null, listOf(zoe))).circleId)
    }

    @Test fun `a one or two letter fragment is not a match`() {
        assertEquals(AssistantRoute.Plan.Pick(emptyList()), AssistantRoute.plan("Tr", null, everyone))
        assertEquals(AssistantRoute.Plan.Pick(emptyList()), AssistantRoute.plan("T", null, everyone))
    }

    @Test fun `a prefix longer than three letters resolves`() {
        assertEquals("dm:tracym", open(AssistantRoute.plan("Trac", null, everyone)).circleId)
    }

    @Test fun `a one to one thread beats a group with the same name`() {
        val group = AssistantRoute.Candidate("dm:g", listOf("Blaine Miller, Tracy Miller", "Blaine Miller", "Tracy Miller"), group = true)
        assertEquals("dm:blaine", open(AssistantRoute.plan("Blaine Miller", null, listOf(group, blaine))).circleId)
        assertEquals("dm:g", open(AssistantRoute.plan("Blaine Miller, Tracy Miller", null, listOf(group, blaine))).circleId)
    }

    @Test fun `the shortcut id Assistant hands back wins outright`() {
        val p = open(AssistantRoute.plan("dm:trey", "on my way", everyone))
        assertEquals("dm:trey", p.circleId)
        assertEquals("on my way", p.draft)
    }

    @Test fun `an unknown id is just a spoken name and matches nothing`() {
        assertEquals(AssistantRoute.Plan.Pick(emptyList()), AssistantRoute.plan("dm:nobody", "hi", everyone))
    }

    @Test fun `no name or an unknown name opens the Messages list`() {
        assertEquals(AssistantRoute.Plan.Pick(emptyList()), AssistantRoute.plan(null, "hi", everyone))
        assertEquals(AssistantRoute.Plan.Pick(emptyList()), AssistantRoute.plan("  ", "hi", everyone))
        assertEquals(AssistantRoute.Plan.Pick(emptyList()), AssistantRoute.plan("Zed", "hi", everyone))
    }

    @Test fun `a locked circle is simply not a candidate so it cannot be confirmed or opened`() {
        // AssistantLaunch.candidates() drops locked circles before this runs.
        val withoutLocked = everyone.filter { it.circleId != "dm:blaine" }
        assertEquals(AssistantRoute.Plan.Pick(emptyList()), AssistantRoute.plan("Blaine", "hi", withoutLocked))
    }

    // ---- the message text -------------------------------------------------------------------

    @Test fun `the text is staged trimmed and with control characters removed`() {
        assertEquals("hello\nworld", AssistantRoute.sanitizeText("  hel\u0000lo\nworld \u0007 "))
        assertEquals("tab\there", AssistantRoute.sanitizeText("tab\there"))
    }

    @Test fun `blank or missing text stages nothing`() {
        assertNull(AssistantRoute.sanitizeText(null))
        assertNull(AssistantRoute.sanitizeText("   \n "))
        assertNull(open(AssistantRoute.plan("Blaine", "  ", everyone)).draft)
    }

    @Test fun `an oversized text is capped like a car reply`() {
        val long = "x".repeat(CarMessaging.MAX_REPLY_CHARS + 500)
        assertEquals(CarMessaging.MAX_REPLY_CHARS, AssistantRoute.sanitizeText(long)!!.length)
    }

    @Test fun `no plan ever sends - the only outcomes are open or pick`() {
        // An exhaustive `when` with no else: adding a "send" case to Plan stops this compiling, so it
        // has to be a deliberate edit (see the AssistantRoute header for why voice never sends).
        val plans = listOf(
            AssistantRoute.plan("Blaine", "hi", everyone),
            AssistantRoute.plan("nobody", "hi", everyone),
        )
        val kinds = plans.map { p ->
            when (p) {
                is AssistantRoute.Plan.Open -> "open"
                is AssistantRoute.Plan.Pick -> "pick"
            }
        }
        assertEquals(listOf("open", "pick"), kinds)
    }

    // ---- shortcut inventory names -----------------------------------------------------------

    @Test fun `a shortcut is callable by full name and by first name`() {
        assertEquals(listOf("Blaine Miller", "Blaine"), AssistantRoute.recipientNames("Blaine Miller"))
        assertEquals(listOf("Troy"), AssistantRoute.recipientNames("Troy"))
        assertEquals(emptyList<String>(), AssistantRoute.recipientNames("  "))
    }

    @Test fun `edit distance counts a swap as one`() {
        assertEquals(1, AssistantRoute.editDistance("tracy", "trayc"))
        assertEquals(2, AssistantRoute.editDistance("tracy", "troy"))
        assertEquals(0, AssistantRoute.editDistance("same", "same"))
    }
}
