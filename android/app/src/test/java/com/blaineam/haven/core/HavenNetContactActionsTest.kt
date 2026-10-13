package com.blaineam.haven.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.json.JSONArray
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Blocking, un-blocking, dismissing requests, severing someone from one circle, deleting a DM and the
 * seedless-link cancel paths — what HavenNet records locally and tells the engine. Driven by [FakeSocial].
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HavenNetContactActionsTest {
    private lateinit var ctx: FakeContext
    private lateinit var social: FakeSocial
    private val net = HavenNet::class.java
    private val hexA = "aa".repeat(32)
    private val hexB = "bb".repeat(32)

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
        field("appContext").set(HavenNet, ctx)
        CircleDeletion.init(ctx); CircleRemovals.init(ctx); ContactRemovals.init(ctx)
        social = FakeSocial()
        field("social").set(HavenNet, social)
        field("ready").setBoolean(HavenNet, false)
        HavenNet.contacts.clear(); HavenNet.blocked.clear(); HavenNet.pending.clear()
        HavenNet.activeCircle.value = DEFAULT_CIRCLE
    }
    @After fun tearDown() {
        ContactRemovals.markReadded(hexA); ContactRemovals.markReadded(hexB)
        HavenNet.contacts.clear(); HavenNet.blocked.clear(); HavenNet.pending.clear()
        HavenNet.activeCircle.value = DEFAULT_CIRCLE
        field("circlesCache").set(HavenNet, null)
        Dispatchers.resetMain(); ctx.filesDir.deleteRecursively()
    }

    private fun field(name: String) = net.getDeclaredField(name).apply { isAccessible = true }
    private val prefs get() = ctx.prefs("haven.contacts")

    /** Wait (bounded) for the circle-list refresh `bumpCircles` runs on the engine's IO scope. */
    private fun awaitRefresh(before: Int) {
        if (before < 0) return
        val deadline = System.nanoTime() + 5_000_000_000L
        while (HavenNet.circlesVersion.value <= before && System.nanoTime() < deadline) Thread.onSpinWait()
    }

    private fun request(hex: String) = PendingRequest(hex, "Req", "vv", ByteArray(4))

    // ---- block / unblock / dismiss ---------------------------------------------------------------

    @Test fun blocking_forgets_the_contact_tombstones_it_and_persists_both_lists() {
        HavenNet.contacts.addAll(listOf(Contact(hexA, "Ana", ""), Contact(hexB, "Ben", "")))
        HavenNet.pending.add(request(hexA))
        HavenNet.block(hexA)
        assertEquals(listOf(hexB), HavenNet.contacts.map { it.idHex })
        assertTrue("a request from a blocked node is gone too", HavenNet.pending.isEmpty())
        assertEquals(listOf(hexA), HavenNet.blocked.toList())
        assertTrue("the removal sticks fleet-wide", ContactRemovals.isRemoved(hexA))
        assertEquals(listOf("block $hexA"), social.calls.toList())
        assertEquals(listOf(hexA), JSONArray(prefs.getString("blocked", "[]")).let { a -> (0 until a.length()).map { a.getString(it) } })
        assertEquals(1, JSONArray(prefs.getString("contacts", "[]")).length())
    }

    @Test fun blocking_twice_lists_the_node_once() {
        HavenNet.block(hexA); HavenNet.block(hexA)
        assertEquals(1, HavenNet.blocked.size)
    }

    @Test fun blocking_still_works_locally_when_the_engine_refuses() {
        social.failReads = true
        HavenNet.contacts.add(Contact(hexA, "Ana", ""))
        HavenNet.block(hexA)
        assertTrue(HavenNet.contacts.isEmpty()); assertEquals(listOf(hexA), HavenNet.blocked.toList())
    }

    @Test fun unblocking_removes_and_persists() {
        HavenNet.block(hexA); HavenNet.block(hexB)
        HavenNet.unblock(hexA)
        assertEquals(listOf(hexB), HavenNet.blocked.toList())
        assertEquals("[\"$hexB\"]", prefs.getString("blocked", null))
        HavenNet.unblock("cc".repeat(32))   // never blocked: harmless
        assertEquals(listOf(hexB), HavenNet.blocked.toList())
    }

    @Test fun dismissing_a_request_drops_only_that_requester() {
        HavenNet.pending.addAll(listOf(request(hexA), request(hexB)))
        HavenNet.dismiss(request(hexA))
        assertEquals(listOf(hexB), HavenNet.pending.map { it.idHex })
    }

    // ---- severing from one circle ----------------------------------------------------------------

    @Test fun removing_someone_from_a_circle_records_the_severance_and_tells_the_engine() {
        val feed = HavenNet.feedVersion.value; val circles = HavenNet.circlesVersion.value
        HavenNet.removeFromCircle("c1abc", hexA)
        assertTrue(HavenNet.isRemovedFromCircle("c1abc", hexA))
        assertFalse("only that circle", HavenNet.isRemovedFromCircle("c1other", hexA))
        assertEquals(listOf("removeMember c1abc $hexA"), social.calls.toList())
        assertEquals(feed + 1, HavenNet.feedVersion.value); assertEquals(circles + 1, HavenNet.circlesVersion.value)
    }

    @Test fun the_one_argument_form_targets_the_circle_being_viewed() {
        HavenNet.activeCircle.value = "c1viewing"
        HavenNet.removeFromCircle(hexB)
        assertTrue(HavenNet.isRemovedFromCircle("c1viewing", hexB))
        assertEquals(listOf("removeMember c1viewing $hexB"), social.calls.toList())
    }

    @Test fun a_failing_engine_still_records_the_severance_locally() {
        social.failReads = true
        HavenNet.removeFromCircle("c1abc", hexA)
        assertTrue(HavenNet.isRemovedFromCircle("c1abc", hexA))
    }

    // ---- deleting a DM ---------------------------------------------------------------------------

    @Test fun deleting_a_dm_watermarks_it_tombstones_it_and_leaves_the_engine_circle() {
        val dm = "dm:$hexA-$hexB"
        HavenNet.activeCircle.value = dm
        val v = HavenNet.circlesVersion.value
        val before = System.currentTimeMillis()
        HavenNet.deleteConversation(dm)
        awaitRefresh(v)
        assertTrue(CircleDeletion.isDeleted(dm))
        assertEquals(listOf("leave $dm"), social.calls.toList())
        assertEquals(DEFAULT_CIRCLE, HavenNet.activeCircle.value)
        assertTrue("re-syncing the same deterministic DM id hides everything older than now",
            HavenNet.dmClearedBefore(dm)!! >= before.toULong())
    }

    @Test fun only_a_dm_can_be_deleted_this_way() {
        HavenNet.deleteConversation("c1abc")
        assertTrue(social.calls.isEmpty()); assertFalse(CircleDeletion.isDeleted("c1abc"))
        assertNull(HavenNet.dmClearedBefore("c1abc"))
    }

    // ---- seedless link UI state ------------------------------------------------------------------

    @Test fun cancelling_the_seedless_ticket_clears_the_offered_qr_and_any_pending_request() {
        HavenNet.seedlessTicketUri.value = "haven-enroll:abc"
        HavenNet.seedlessPendingRequest.value = HavenNet.SeedlessEnrollPrompt(hexA, "Pixel", ByteArray(1))
        HavenNet.cancelSeedlessTicket()
        assertEquals("", HavenNet.seedlessTicketUri.value); assertNull(HavenNet.seedlessPendingRequest.value)
    }

    @Test fun dismissing_the_confirm_prompt_keeps_the_ticket_but_drops_the_request() {
        HavenNet.seedlessTicketUri.value = "haven-enroll:abc"
        HavenNet.seedlessPendingRequest.value = HavenNet.SeedlessEnrollPrompt(hexA, "Pixel", ByteArray(1))
        HavenNet.dismissSeedlessEnroll()
        assertNull(HavenNet.seedlessPendingRequest.value)
        assertEquals("haven-enroll:abc", HavenNet.seedlessTicketUri.value)
        HavenNet.seedlessTicketUri.value = ""
    }

    @Test fun backing_out_of_linking_clears_the_waiting_state() {
        HavenNet.seedlessLinking.value = true
        HavenNet.cancelSeedlessLink()
        assertFalse(HavenNet.seedlessLinking.value)
    }

    // ---- small builders ---------------------------------------------------------------------------

    @Test fun a_shared_link_becomes_a_track_reference_with_a_fallback_title() {
        val t = HavenNet.trackFromLink("https://music.example/x", "  ", "Artist")
        assertEquals("https://music.example/x", t.catalogId); assertEquals("Shared track", t.title)
        assertEquals("Artist", t.artist); assertEquals(0uL, t.durationMs)
        assertNotNull(HavenNet.trackFromLink("u", "Song", "").title); assertEquals("Song", HavenNet.trackFromLink("u", "Song", "").title)
    }
}
