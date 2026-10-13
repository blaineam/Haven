package com.blaineam.haven.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.ReportFfi

/**
 * Circle management through HavenNet: what it tells the engine, what it records locally (the LWW
 * deletion tombstone, the active circle) and how it behaves when the engine misbehaves. Driven by
 * [FakeSocial]; the engine lock and disk persistence are out of scope here (persist is a logged
 * no-op without an identity).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HavenNetCircleActionsTest {
    private lateinit var ctx: FakeContext
    private lateinit var social: FakeSocial
    private val net = HavenNet::class.java

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
        field("appContext").set(HavenNet, ctx)
        CircleDeletion.init(ctx); CircleRemovals.init(ctx)
        social = FakeSocial()
        field("social").set(HavenNet, social)
        field("ready").setBoolean(HavenNet, false)
        HavenNet.contacts.clear()
        HavenNet.activeCircle.value = DEFAULT_CIRCLE
    }
    @After fun tearDown() {
        awaitBackgroundRefresh()
        HavenNet.contacts.clear(); HavenNet.activeCircle.value = DEFAULT_CIRCLE
        field("circlesCache").set(HavenNet, null)
        Dispatchers.resetMain(); ctx.filesDir.deleteRecursively()
    }

    private fun field(name: String) = net.getDeclaredField(name).apply { isAccessible = true }

    /** `bumpCircles` refreshes the circle cache on the engine's IO scope and then bumps
     *  [HavenNet.circlesVersion]; wait on that bump (bounded) so no refresh outlives its test. */
    private fun awaitBackgroundRefresh(before: Int = -1) {
        val target = if (before >= 0) before + 1 else HavenNet.circlesVersion.value
        val deadline = System.nanoTime() + 5_000_000_000L
        while (HavenNet.circlesVersion.value < target && System.nanoTime() < deadline) Thread.onSpinWait()
    }

    private val hexA = "aa".repeat(32)
    private val hexB = "bb".repeat(32)

    // ---- membership -----------------------------------------------------------------------------

    @Test fun members_resolve_to_known_contacts_and_fall_back_to_a_short_tag() {
        HavenNet.contacts.add(Contact(hexA, "Ana", "v"))
        social.members["c1x"] = listOf(hexA, hexB)
        val m = HavenNet.membersOf("c1x")
        assertEquals(listOf("Ana", "Someone (bbbbbb)"), m.map { it.name })
        assertEquals(listOf(hexA, hexB), m.map { it.idHex })
        social.failReads = true
        assertTrue(HavenNet.membersOf("c1x").isEmpty())
    }

    @Test fun reports_are_grouped_by_the_event_they_name() {
        fun r(id: String, target: String) = ReportFfi(id, hexA, "aaaaaaaa", target, hexB, "spam", "", 1uL)
        social.reportList["c1x"] = listOf(r("r1", "p1"), r("r2", "p2"), r("r3", "p1"))
        val g = HavenNet.reports("c1x")
        assertEquals(setOf("p1", "p2"), g.keys)
        assertEquals(listOf("r1", "r3"), g["p1"]!!.map { it.id })
        social.failReads = true
        assertTrue(HavenNet.reports("c1x").isEmpty())
    }

    // ---- leave / rename / add -------------------------------------------------------------------

    @Test fun leaving_a_circle_tombstones_it_leaves_the_engine_and_resets_the_active_circle() {
        HavenNet.activeCircle.value = "c1leave"
        val v = HavenNet.circlesVersion.value
        HavenNet.leaveCircle("c1leave")
        awaitBackgroundRefresh(v)
        assertTrue("the deletion survives a sibling re-broadcast", CircleDeletion.isDeleted("c1leave"))
        assertEquals(listOf("leave c1leave"), social.calls.toList())
        assertEquals(DEFAULT_CIRCLE, HavenNet.activeCircle.value)
    }

    @Test fun leaving_a_circle_i_am_not_viewing_keeps_the_active_one() {
        HavenNet.activeCircle.value = "c1keep"
        val v = HavenNet.circlesVersion.value
        HavenNet.leaveCircle("c1other")
        awaitBackgroundRefresh(v)
        assertEquals("c1keep", HavenNet.activeCircle.value)
    }

    @Test fun the_personal_default_circle_cannot_be_left() {
        HavenNet.leaveCircle(DEFAULT_CIRCLE)
        assertTrue(social.calls.isEmpty())
        assertFalse(CircleDeletion.isDeleted(DEFAULT_CIRCLE))
    }

    @Test fun leaving_survives_an_engine_that_throws() {
        social.failReads = true
        val v = HavenNet.circlesVersion.value
        HavenNet.leaveCircle("c1boom")
        awaitBackgroundRefresh(v)
        assertTrue("the local tombstone is written regardless", CircleDeletion.isDeleted("c1boom"))
    }

    @Test fun renaming_goes_to_the_engine_with_the_exact_name() {
        val v = HavenNet.circlesVersion.value
        HavenNet.renameCircle("c1ren", "New Name")
        awaitBackgroundRefresh(v)
        assertEquals(listOf("rename c1ren New Name"), social.calls.toList())
    }

    @Test fun re_adding_a_person_lifts_their_removal_before_the_engine_adds_them() {
        CircleRemovals.add("c1re", hexA)
        assertTrue(CircleRemovals.contains("c1re", hexA))
        val v = HavenNet.circlesVersion.value
        // sendHello needs a live node (it is a logged no-op here); the removal bookkeeping is what's under test.
        runCatching { HavenNet.addToCircle("c1re", hexA) }
        awaitBackgroundRefresh(v)
        assertFalse("a deliberate re-add un-bans", CircleRemovals.contains("c1re", hexA))
        assertEquals(listOf("clearRemoval c1re $hexA", "add c1re $hexA"), social.calls.take(2))
    }

    // ---- superseded circles ---------------------------------------------------------------------

    @Test fun a_superseded_legacy_circle_collapses_into_its_successor() {
        social.superseded = listOf("legacy1")
        social.successors["legacy1"] = "c1succ"
        HavenNet.activeCircle.value = "legacy1"
        val v = HavenNet.circlesVersion.value
        HavenNet.reconcileSupersededCircles()
        awaitBackgroundRefresh(v)
        assertTrue(CircleDeletion.isDeleted("legacy1"))
        assertEquals(listOf("leave legacy1"), social.calls.toList())
        assertEquals("the viewer lands on the replacement", "c1succ", HavenNet.activeCircle.value)
    }

    @Test fun with_no_successor_the_viewer_lands_on_the_default_circle() {
        social.superseded = listOf("legacy2")
        HavenNet.activeCircle.value = "legacy2"
        val v = HavenNet.circlesVersion.value
        HavenNet.reconcileSupersededCircles()
        awaitBackgroundRefresh(v)
        assertEquals(DEFAULT_CIRCLE, HavenNet.activeCircle.value)
    }

    @Test fun an_already_tombstoned_legacy_circle_is_not_left_twice_and_nothing_superseded_does_nothing() {
        HavenNet.reconcileSupersededCircles()
        assertTrue(social.calls.isEmpty())
        CircleDeletion.markDeleted("legacy3")
        social.superseded = listOf("legacy3")
        HavenNet.reconcileSupersededCircles()
        assertTrue("healed once, never again", social.calls.isEmpty())
        social.failReads = true
        HavenNet.reconcileSupersededCircles()   // an engine that cannot answer is "nothing superseded"
        assertTrue(social.calls.isEmpty())
    }
}
