package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.FeedItemFfi

/** A multi-circle post is remembered locally so an edit of one copy reaches every other copy. */
class MultiPostGroupsTest {
    private val env = NetEnv()

    @Before fun setUp() {
        env.up()
        CircleSettings.init(env.ctx)
        HiddenStore.init(env.ctx)
        env.social.circleList = listOf(CircleInfoFfi("c1a", "A", 1u), CircleInfoFfi("c1b", "B", 1u), CircleInfoFfi("c1c", "C", 1u))
        env.social.authorOk = "ENV".toByteArray()
        var n = 0
        env.social.onAuthor = { if (env.social.authored.last().verb == "post") env.social.authoredId = "ev${n++}" }
    }
    @After fun tearDown() { env.down() }

    private fun edits() = env.social.authored.filter { it.verb == "edit" }
    private fun item(id: String, media: List<String>) =
        FeedItemFfi(id, "aaaaaaaa", true, 1uL, "old", media, null, false, false, false, false, emptyList(), emptyList(), null)

    @Test fun a_group_is_registered_only_when_more_than_one_circle_is_targeted() {
        HavenNet.postToCircles(listOf("c1a"), "solo")
        assertEquals(0, MultiPostGroups.count())
        HavenNet.postToCircles(listOf("c1a", "c1b", "c1c"), "all")
        assertEquals(1, MultiPostGroups.count())
        assertEquals(listOf("c1b" to "ev2", "c1c" to "ev3"),
            MultiPostGroups.siblingsOf("c1a", "ev1").map { it.circleId to it.eventId })
    }

    @Test fun each_copy_gets_a_distinct_created_at() {
        HavenNet.postToCircles(listOf("c1a", "c1b", "c1c"), "same body")
        val ts = env.social.authored.filter { it.verb == "post" }.map { it.createdAt }
        assertEquals(3, ts.distinct().size)
    }

    @Test fun editing_one_copy_authors_the_same_edit_into_every_sibling_with_its_own_target() {
        HavenNet.postToCircles(listOf("c1a", "c1b", "c1c"), "hello")
        val song = uniffi.haven_ffi.TrackRefFfi("cat", "T", "A", "", 0uL)
        HavenNet.editPostFull("c1b", "ev1", "fixed", listOf("vid_v"), song, true)
        val e = edits()
        assertEquals(listOf("c1b" to "ev1", "c1a" to "ev0", "c1c" to "ev2"), e.map { it.circleId to it.target }.let { l ->
            // primary first; siblings in group order (a=ev0, c=ev2) — each with its OWN event id
            listOf(l[0]) + l.drop(1).sortedBy { it.first }
        })
        for (a in e) {
            assertEquals("fixed", a.body); assertEquals(listOf("vid_v"), a.media); assertEquals(song, a.music); assertTrue(a.muteVideo)
        }
    }

    @Test fun a_text_edit_keeps_each_siblings_own_attachments() {
        HavenNet.postToCircles(listOf("c1a", "c1b"), "hello")
        env.social.feeds["c1a"] = listOf(item("ev0", listOf("img_a")))
        env.social.feeds["c1b"] = listOf(item("ev1", listOf("img_b")))
        HavenNet.editPost("c1a", "ev0", "retyped")
        val byCircle = edits().associateBy { it.circleId }
        assertEquals(listOf("img_a"), byCircle.getValue("c1a").media)
        assertEquals("ev1", byCircle.getValue("c1b").target)
        assertEquals(listOf("img_b"), byCircle.getValue("c1b").media)
        assertEquals("retyped", byCircle.getValue("c1b").body)
    }

    @Test fun a_sibling_whose_circle_no_longer_exists_is_skipped_and_forgotten() {
        HavenNet.postToCircles(listOf("c1a", "c1b", "c1c"), "hello")
        env.social.circleList = listOf(CircleInfoFfi("c1a", "A", 1u), CircleInfoFfi("c1c", "C", 1u))
        HavenNet.editPostFull("c1a", "ev0", "x", emptyList(), null, false)
        assertEquals(setOf("c1a", "c1c"), edits().map { it.circleId }.toSet())
        assertEquals(listOf("c1c"), MultiPostGroups.siblingsOf("c1a", "ev0").map { it.circleId })
    }

    @Test fun a_failing_sibling_does_not_abort_the_rest() {
        HavenNet.postToCircles(listOf("c1a", "c1b", "c1c"), "hello")
        val prev = env.social.onAuthor
        env.social.onAuthor = { prev?.invoke(); val l = env.social.authored.last(); if (l.verb == "edit" && l.circleId == "c1b") error("boom") }
        HavenNet.editPostFull("c1a", "ev0", "x", emptyList(), null, false)
        assertEquals(setOf("c1a", "c1b", "c1c"), edits().map { it.circleId }.toSet())
    }

    @Test fun a_post_without_a_group_edits_one_circle_only() {
        HavenNet.postToCircles(listOf("c1a"), "solo")
        HavenNet.editPostFull("c1a", "ev0", "x", emptyList(), null, false)
        assertEquals(1, edits().size)
        HavenNet.editPostFull("c1b", "legacy", "x", emptyList(), null, false)
        assertEquals(2, edits().size)
    }

    @Test fun the_index_is_capped_and_evicts_the_oldest_group_first() {
        for (i in 0 until MultiPostGroups.MAX_GROUPS + 5)
            MultiPostGroups.register(listOf(MultiPostGroups.Member("a", "x$i"), MultiPostGroups.Member("b", "y$i")))
        assertEquals(MultiPostGroups.MAX_GROUPS, MultiPostGroups.count())
        assertTrue(MultiPostGroups.siblingsOf("a", "x0").isEmpty())
        assertEquals("y5", MultiPostGroups.siblingsOf("a", "x5").single().eventId)
        // Survives a reload from disk.
        MultiPostGroups.init(env.ctx)
        assertEquals(MultiPostGroups.MAX_GROUPS, MultiPostGroups.count())
        assertNotEquals(0, MultiPostGroups.siblingsOf("a", "x504").size)
    }

    @Test fun a_single_circle_group_is_never_stored() {
        MultiPostGroups.register(listOf(MultiPostGroups.Member("a", "x"), MultiPostGroups.Member("a", "y")))
        assertEquals(0, MultiPostGroups.count())
    }
}
