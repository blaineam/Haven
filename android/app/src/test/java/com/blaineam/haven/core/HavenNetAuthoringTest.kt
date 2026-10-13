package com.blaineam.haven.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.FeedCommentFfi
import uniffi.haven_ffi.FeedItemFfi
import uniffi.haven_ffi.TrackRefFfi

/**
 * What HavenNet asks the engine to AUTHOR — the exact arguments for a post, reaction, reply, edit,
 * unsend and report — and the guards in front of each. [FakeSocial] records the request and refuses,
 * so HavenNet stops before its broadcast/upload legs: nothing here touches a network.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HavenNetAuthoringTest {
    private lateinit var ctx: FakeContext
    private lateinit var social: FakeSocial
    private val net = HavenNet::class.java
    private val photo = "img_" + "a1".repeat(32)
    private val thumb = "img_" + "7b".repeat(32)

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
        net.getDeclaredField("appContext").apply { isAccessible = true }.set(HavenNet, ctx)
        LocalMedia.init(ctx)
        social = FakeSocial()
        net.getDeclaredField("social").apply { isAccessible = true }.set(HavenNet, social)
    }
    @After fun tearDown() { Dispatchers.resetMain(); ctx.filesDir.deleteRecursively() }

    private fun item(id: String, media: List<String> = emptyList(), music: TrackRefFfi? = null, mute: Boolean = false,
                     comments: List<FeedCommentFfi> = emptyList()) =
        FeedItemFfi(id, "aaaaaaaa", true, 1uL, "old", media, music, false, false, false, mute, comments, emptyList(), null)

    // ---- post -----------------------------------------------------------------------------------

    @Test fun a_post_is_authored_with_its_body_media_and_retention() {
        HavenNet.post("c1a", "hello", listOf("vid_x"), retentionSecs = 3600uL)
        val a = social.authored.single()
        assertEquals("post", a.verb); assertEquals("c1a", a.circleId); assertEquals("hello", a.body)
        assertEquals(listOf("vid_x"), a.media); assertEquals(3600uL, a.retentionSecs)
    }

    @Test fun an_empty_post_is_never_authored_but_a_song_or_a_photo_alone_is_enough() {
        HavenNet.post("c1a", "   ")
        assertTrue(social.authored.isEmpty())
        HavenNet.post("c1a", "", listOf("img_only"))
        HavenNet.post("c1a", "", music = HavenNet.trackFromLink("u", "t", "a"))
        assertEquals(2, social.authored.size)
    }

    @Test fun a_photos_compose_time_thumb_joins_the_signed_media_list_as_a_marker() {
        ctx.prefs("haven.media.thumbs").data["t|$photo"] = thumb
        assertTrue(LocalMedia.writeRawSealed(thumb, ByteArray(8) { 1 }))
        HavenNet.post("c1a", "pic", listOf(photo))
        assertEquals(listOf(photo, MediaVariants.thumbMarker(photo, thumb)), social.authored.single().media)
    }

    @Test fun a_thumb_that_is_no_longer_on_disk_adds_no_marker() {
        ctx.prefs("haven.media.thumbs").data["t|$photo"] = thumb   // recorded, but the blob is gone
        HavenNet.post("c1a", "pic", listOf(photo))
        assertEquals(listOf(photo), social.authored.single().media)
    }

    // ---- reactions & replies --------------------------------------------------------------------

    @Test fun reacting_and_unreacting_name_the_post_and_the_emoji() {
        HavenNet.react("c1a", "p1", "🔥"); HavenNet.unreact("c1a", "p1", "🔥")
        assertEquals(listOf("react", "unreact"), social.authored.map { it.verb })
        assertTrue(social.authored.all { it.circleId == "c1a" && it.target == "p1" && it.body == "🔥" })
    }

    @Test fun a_reply_needs_text_or_media_and_carries_both() {
        HavenNet.comment("c1a", "p1", "  ")
        assertTrue(social.authored.isEmpty())
        HavenNet.comment("c1a", "p1", "")                      // empty and no media: nothing
        assertTrue(social.authored.isEmpty())
        HavenNet.comment("c1a", "p1", "nice", listOf("aud_voice"))
        val a = social.authored.single()
        assertEquals("comment", a.verb); assertEquals("p1", a.target); assertEquals("nice", a.body); assertEquals(listOf("aud_voice"), a.media)
    }

    @Test fun a_media_only_reply_is_valid() {
        HavenNet.comment("c1a", "p1", "", listOf("img_only"))
        assertEquals(listOf("img_only"), social.authored.single().media)
    }

    // ---- edit / unsend / report -----------------------------------------------------------------

    @Test fun a_text_edit_restates_the_attachments_it_was_not_asked_to_change() {
        val song = TrackRefFfi("cat", "Title", "Artist", "", 0uL)
        social.feeds["c1a"] = listOf(item("p1", media = listOf(photo, "vid_v"), music = song, mute = true))
        HavenNet.editPost("c1a", "p1", "new text")
        val a = social.authored.single()
        assertEquals("edit", a.verb); assertEquals("new text", a.body)
        assertEquals("the photo and video survive a text edit", listOf(photo, "vid_v"), a.media)
        assertEquals(song, a.music); assertTrue(a.muteVideo)
    }

    @Test fun editing_a_reply_carries_the_replys_media_and_no_song() {
        val reply = FeedCommentFfi("k1", "bbbbbbbb", true, 2uL, "old", listOf("aud_v"), false, false, emptyList())
        social.feeds["c1a"] = listOf(item("p1", comments = listOf(reply)))
        HavenNet.editPost("c1a", "k1", "fixed")
        val a = social.authored.single()
        assertEquals(listOf("aud_v"), a.media); assertNull(a.music)
    }

    @Test fun an_edit_of_something_that_cannot_be_read_is_dropped_rather_than_wiping_its_attachments() {
        social.feeds["c1a"] = listOf(item("p1"))
        HavenNet.editPost("c1a", "ghost", "x")
        assertTrue(social.authored.isEmpty())
        social.failReads = true
        HavenNet.editPost("c1a", "p1", "x")
        assertTrue(social.authored.isEmpty())
    }

    @Test fun a_full_edit_replaces_everything_it_is_given() {
        HavenNet.editPostFull("c1a", "p1", "body", listOf("img_new"), null, true)
        val a = social.authored.single()
        assertEquals(listOf("img_new"), a.media); assertNull(a.music); assertTrue(a.muteVideo)
    }

    @Test fun unsending_names_the_event() {
        HavenNet.unsendPost("c1a", "p9")
        assertEquals("unsend", social.authored.single().verb); assertEquals("p9", social.authored.single().target)
    }

    @Test fun a_report_that_the_engine_refuses_is_a_null_author_and_hides_nothing() {
        assertNull(HavenNet.report("c1a", "p9", "spam", "ugh"))
        assertEquals("report", social.authored.single().verb)
        assertEquals("spam|ugh", social.authored.single().body)
        assertTrue("a refused report must not hide the post", !HiddenStore.isHidden("p9"))
    }
}
