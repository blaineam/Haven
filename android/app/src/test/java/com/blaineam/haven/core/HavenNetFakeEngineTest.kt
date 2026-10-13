package com.blaineam.haven.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.CircleUpgradeOffer
import uniffi.haven_ffi.FeedCommentFfi
import uniffi.haven_ffi.FeedItemFfi

/**
 * HavenNet's engine-backed read paths — circle list, DM threads, unread counts, upgrade rules, the
 * media inventory and the serve-circle lookup — against [FakeSocial], the generated binding's own
 * test double. Every case also has its failure twin: the engine throwing must degrade, not crash.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HavenNetFakeEngineTest {
    private lateinit var ctx: FakeContext
    private lateinit var social: FakeSocial
    private val net = HavenNet::class.java
    private val me = "11".repeat(32)
    private val other = "22".repeat(32)
    private val third = "33".repeat(32)

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
        field("appContext").set(HavenNet, ctx)
        LocalMedia.init(ctx)
        CircleDeletion.init(ctx)
        DmRead.init(ctx)
        PinnedMediaStore.init(ctx)
        social = FakeSocial()
        field("social").set(HavenNet, social)
        field("circlesCache").set(HavenNet, null)
        field("ready").setBoolean(HavenNet, false)
        (field("serveCircleCache").get(HavenNet) as MutableMap<*, *>).clear()
        (field("serveRoleCache").get(HavenNet) as MutableMap<*, *>).clear()
    }
    @After fun tearDown() {
        field("ready").setBoolean(HavenNet, false)
        field("circlesCache").set(HavenNet, null)
        ScheduledStore.items.clear()
        Dispatchers.resetMain(); ctx.filesDir.deleteRecursively()
    }

    private fun field(name: String) = net.getDeclaredField(name).apply { isAccessible = true }
    private fun circle(id: String, name: String, members: UInt = 2u) = CircleInfoFfi(id, name, members)
    private fun post(id: String, at: ULong, body: String = "", media: List<String> = emptyList(),
                     me: Boolean = false, unsent: Boolean = false, comments: List<FeedCommentFfi> = emptyList()) =
        FeedItemFfi(id, "aaaaaaaa", me, at, body, media, null, false, unsent, false, false, comments, emptyList(), null)

    // ---- circle list ----------------------------------------------------------------------------

    @Test fun the_circle_list_is_read_from_the_engine_and_remembered() {
        social.circleList = listOf(circle("default", "Home"), circle("c1x", "Family"))
        assertEquals(listOf("Home", "Family"), HavenNet.circlesSnapshot().map { it.name })
        social.failReads = true
        assertEquals("a failing engine falls back to the last list read", listOf("Home", "Family"),
            HavenNet.circlesSnapshot().map { it.name })
    }

    @Test fun with_no_list_ever_read_a_failing_engine_gives_an_empty_one() {
        social.failReads = true
        assertTrue(HavenNet.circlesSnapshot().isEmpty())
    }

    @Test fun a_circles_wire_name_is_never_replaced_by_my_private_nickname() {
        social.circleList = listOf(circle("c1x", "Family"))
        assertEquals("Family", HavenNet.circleName("c1x"))
        CircleSettings.init(ctx)
        CircleSettings.setNickname("c1x", "  The Clan ")
        try {
            assertEquals("The Clan", HavenNet.circleName("c1x"))
            assertEquals("the name that goes on the wire stays real", "Family", HavenNet.realCircleName("c1x"))
        } finally { CircleSettings.setNickname("c1x", "") }
        assertEquals("a circle the engine does not list reads as the default label", "My Circle", HavenNet.realCircleName("zzz"))
    }

    @Test fun the_feed_switcher_hides_dms_and_deleted_circles() {
        social.circleList = listOf(circle("default", "Home"), circle("dm:$me-$other", "x"),
            circle("c1gone", "Old"), circle("c1live", "Live"))
        CircleDeletion.markDeleted("c1gone")
        try {
            assertEquals(listOf("default", "c1live"), HavenNet.feedCircles().map { it.id })
        } finally { CircleDeletion.markRecreated("c1gone") }
    }

    // ---- DM threads -----------------------------------------------------------------------------

    private val dm get() = "dm:$me-$other"

    @Test fun messages_read_oldest_first_and_pass_the_viewers_retention_window() {
        social.feeds[dm] = listOf(post("m2", 200uL), post("m1", 100uL), post("m3", 300uL))
        assertEquals(listOf("m1", "m2", "m3"), HavenNet.messages(dm).map { it.id })
        assertEquals("the engine is asked for this thread", listOf(dm), social.feedAsks.map { it.first })
    }

    @Test fun a_cleared_conversation_hides_everything_before_the_watermark() {
        val cutoff = System.currentTimeMillis()
        ctx.prefs("haven.dm").data["cleared.$dm"] = cutoff
        social.feeds[dm] = listOf(post("old", (cutoff - 10_000).toULong()), post("new", (cutoff + 10_000).toULong()))
        assertEquals(listOf("new"), HavenNet.messages(dm).map { it.id })
        assertEquals(cutoff.toULong(), HavenNet.dmClearedBefore(dm))
        assertNull(HavenNet.dmClearedBefore("dm:never"))
    }

    @Test fun a_failing_engine_shows_an_empty_thread() {
        social.feeds[dm] = listOf(post("m1", 100uL))
        social.failReads = true
        assertTrue(HavenNet.messages(dm).isEmpty())
        assertEquals(0uL, HavenNet.lastActivity(dm))
    }

    @Test fun last_activity_is_the_newest_message_time() {
        social.feeds[dm] = listOf(post("a", 5uL), post("b", 90uL), post("c", 40uL))
        assertEquals(90uL, HavenNet.lastActivity(dm))
        assertEquals(0uL, HavenNet.lastActivity("dm:empty"))
    }

    @Test fun unread_counts_only_inbound_messages_after_the_read_watermark() {
        val wm = DmRead.watermark(dm).toLong()
        social.feeds[dm] = listOf(
            post("read", (wm - 1).toULong()),                    // before the watermark
            post("in1", (wm + 10).toULong()),
            post("in2", (wm + 20).toULong()),
            post("mine", (wm + 30).toULong(), me = true),        // my own never badges
            post("gone", (wm + 40).toULong(), unsent = true),    // an unsent one never badges
        )
        assertEquals(2, HavenNet.unreadMessages(dm))
    }

    @Test fun the_messages_tab_badge_counts_conversations_not_messages() {
        val wm = DmRead.watermark(dm).toLong()
        val dm2 = "dm:$me-$third"
        social.circleList = listOf(circle(dm, "a"), circle(dm2, "b"), circle("default", "Home"), circle("dm:$other-$third", "quiet"))
        social.feeds[dm] = listOf(post("a1", (wm + 5).toULong()), post("a2", (wm + 6).toULong()))
        social.feeds[dm2] = listOf(post("b1", (wm + 7).toULong()))
        social.feeds["default"] = listOf(post("p", (wm + 8).toULong()))   // a circle post is not a DM
        assertEquals(2, HavenNet.unreadDmConversations())
        social.failReads = true
        assertEquals(0, HavenNet.unreadDmConversations())
    }

    @Test fun dm_membership_helpers_read_the_ids_encoded_in_the_circle() {
        val group = HavenKeys.groupDmCircleId(me, listOf(other, third))
        assertTrue(HavenNet.isGroupDm(group))
        assertFalse(HavenNet.isGroupDm(dm))
        assertFalse(HavenNet.isGroupDm("c1abc"))
        assertEquals(setOf(me, other, third), HavenNet.dmMemberHexes(group).toSet())
    }

    // ---- circle upgrades ------------------------------------------------------------------------

    @Test fun only_an_ownerless_legacy_circle_can_be_upgraded() {
        social.admins["legacy"] = emptyList()
        social.admins["owned"] = listOf(me)
        assertTrue(HavenNet.circleIsUpgradable("legacy"))
        assertFalse("an admin is a verified owner", HavenNet.circleIsUpgradable("owned"))
        assertFalse("owned c1 ids never upgrade", HavenNet.circleIsUpgradable("c1abc"))
        assertFalse(HavenNet.circleIsUpgradable("default"))
        assertFalse(HavenNet.circleIsUpgradable("dm:$me-$other"))
        social.failReads = true
        assertFalse("an engine that cannot answer offers nothing", HavenNet.circleIsUpgradable("legacy"))
    }

    @Test fun pending_upgrade_offers_are_surfaced_and_a_failure_is_just_none() {
        val offer = CircleUpgradeOffer("legacy", "c1new", other, "Ben", false)
        social.offers["legacy"] = listOf(offer)
        assertEquals(listOf(offer), HavenNet.pendingCircleUpgrades("legacy"))
        assertTrue(HavenNet.pendingCircleUpgrades("other").isEmpty())
        social.failReads = true
        assertTrue(HavenNet.pendingCircleUpgrades("legacy").isEmpty())
    }

    // ---- media inventory ------------------------------------------------------------------------

    private fun blob(ref: String, size: Int) { assertTrue(LocalMedia.writeRawSealed(ref, ByteArray(size) { 1 })) }
    private val imgA = "img_" + "a1".repeat(32)
    private val vidB = "vid_" + "b2".repeat(32)
    private val imgC = "img_" + "c3".repeat(32)
    private val audD = "aud_" + "d4".repeat(32)

    @Test fun every_stored_blob_is_joined_to_what_names_it_and_sorted_largest_first() {
        blob(imgA, 300); blob(vidB, 500); blob(imgC, 100); blob(audD, 50)
        social.circleList = listOf(circle("c1fam", "Family"), circle("dm:$me-$other", "dm"))
        social.feeds["c1fam"] = listOf(post("p1", 10uL, body = "x".repeat(200), media = listOf(imgA)))
        social.feeds["dm:$me-$other"] = listOf(post("m1", 11uL, comments = listOf(
            FeedCommentFfi("c", "bbbbbbbb", false, 12uL, "see this", listOf(vidB), false, false, emptyList()))))
        ScheduledStore.items.add(ScheduledStore.Item("s1", "c1fam", "later", listOf(audD), null, 0L))
        PinnedMediaStore.refs.add(imgA)
        field("ready").setBoolean(HavenNet, true)

        val rows = HavenNet.mediaInventory()
        assertEquals("largest first", listOf(vidB, imgA, imgC, audD), rows.map { it.key })
        val v = rows[0]; val a = rows[1]; val c = rows[2]; val d = rows[3]
        assertTrue(v.isVideo); assertEquals("Direct message", v.circleName); assertEquals("see this", v.snippet); assertFalse(v.orphan)
        assertEquals("Family", a.circleName); assertEquals(80, a.snippet!!.length); assertTrue(a.pinned); assertFalse(v.pinned)
        assertEquals("Unused", c.circleName); assertTrue(c.orphan); assertNull(c.snippet); assertNull(c.circleId)
        assertEquals("Scheduled to send", d.circleName); assertFalse("queued media is not an orphan", d.orphan); assertTrue(d.isAudio)
    }

    @Test fun the_inventory_is_empty_before_the_engine_is_ready_and_orphans_everything_when_it_fails() {
        blob(imgC, 100)
        assertTrue(HavenNet.mediaInventory().isEmpty())
        field("ready").setBoolean(HavenNet, true)
        social.failReads = true
        val rows = HavenNet.mediaInventory()
        assertEquals(1, rows.size); assertTrue(rows[0].orphan)
    }

    // ---- serve-circle lookup --------------------------------------------------------------------

    @Test fun a_ref_is_served_from_the_circle_whose_feed_carries_it_and_the_answer_is_cached() {
        social.circleList = listOf(circle("c1a", "A"), circle("c1b", "B"))
        social.feeds["c1b"] = listOf(post("p", 1uL, media = listOf(imgA)))
        val m = net.getDeclaredMethod("circleOfRef", String::class.java).apply { isAccessible = true }
        assertEquals("c1b", m.invoke(HavenNet, imgA))
        social.failReads = true
        assertEquals("cached: no second engine walk", "c1b", m.invoke(HavenNet, imgA))
        assertNull("a ref nobody carries has no circle", m.invoke(HavenNet, imgC))
    }
}
