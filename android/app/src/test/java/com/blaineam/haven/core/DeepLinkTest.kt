package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Post / story / DM / circle links: emission, parsing both generations, and story-reply inference. */
class DeepLinkTest {
    @Test fun post_url_keeps_the_payload_in_the_fragment_never_the_path() {
        val u = DeepLink.postUrl("circ1", "post1")!!
        assertEquals("https://wemiller.com/apps/haven/open/#p/circ1.post1", u)
        assertFalse("payload must follow '#'", u.substringBefore('#').contains("circ1"))
    }

    @Test fun empty_ids_never_make_a_link() {
        assertNull(DeepLink.postUrl("", "p")); assertNull(DeepLink.postUrl("c", ""))
        assertNull(DeepLink.storyUrl("", "p")); assertNull(DeepLink.internalPostUrl("c", ""))
        assertNull(DeepLink.internalStoryUrl("", "p")); assertNull(DeepLink.dmUrl(""))
        assertNull(DeepLink.circleUrl("")); assertNull(DeepLink.interactionLink(""))
    }

    @Test fun web_post_link_round_trips_including_delimiters_inside_ids() {
        val u = DeepLink.postUrl("dm:a.b/c d", "id.with/dots %é")!!
        val p = DeepLink.parsePost(u)!!
        assertEquals("dm:a.b/c d", p.circleId)
        assertEquals("id.with/dots %é", p.postId)
    }

    @Test fun legacy_scheme_links_still_parse_forever() {
        val p = DeepLink.parsePost("haven://p/circ%201/post-9")!!
        assertEquals(DeepLink.Post("circ 1", "post-9"), p)
        assertEquals(p, DeepLink.parsePost(DeepLink.internalPostUrl("circ 1", "post-9")))
    }

    @Test fun older_open_less_web_links_match_the_wide_prefix() {
        assertEquals(DeepLink.Post("c", "p"), DeepLink.parsePost("https://wemiller.com/apps/haven/#p/c.p"))
        assertEquals(DeepLink.Post("c", "p"), DeepLink.parsePost("  HTTPS://WEMILLER.COM/apps/haven/open#p/c.p  "))
    }

    @Test fun foreign_hosts_paths_and_malformed_links_are_not_posts() {
        for (bad in listOf(
            null, "", "   ", "https://evil.com/apps/haven/open/#p/c.p", "http://wemiller.com/apps/haven/#p/c.p",
            "https://wemiller.com/other/#p/c.p", "https://wemiller.com/apps/haven/open/",
            "https://wemiller.com/apps/haven/open/#x/c.p", "https://wemiller.com/apps/haven/open/#p/nodot",
            "https://wemiller.com/apps/haven/open/#p/.p", "https://wemiller.com/apps/haven/open/#p/c.",
            "haven://q/c/p", "haven://p/onlyone", "ftp://p/c/p",
        )) assertNull("should not parse: $bad", DeepLink.parsePost(bad))
    }

    @Test fun story_links_round_trip_in_both_forms() {
        val web = DeepLink.storyUrl("c1", "s1")!!
        assertEquals("https://wemiller.com/apps/haven/open/#s/c1.s1", web)
        assertEquals(DeepLink.Story("c1", "s1"), DeepLink.parseStory(web))
        assertEquals(DeepLink.Story("c 1", "s/1"), DeepLink.parseStory(DeepLink.internalStoryUrl("c 1", "s/1")))
        assertNull(DeepLink.parseStory(DeepLink.postUrl("c1", "p1")))
        assertNull(DeepLink.parseStory("haven://s/onlyone"))
        assertNull(DeepLink.parseStory("https://wemiller.com/apps/haven/open/#s/nodot"))
        assertNull(DeepLink.parseStory(null))
    }

    @Test fun dm_links_carry_the_thread_and_optional_message() {
        val u = DeepLink.dmUrl("dm:aa-bb", "msg1")!!
        assertEquals(DeepLink.Dm("dm:aa-bb", "msg1"), DeepLink.parseDm(u))
        assertEquals(DeepLink.Dm("dm:aa-bb", null), DeepLink.parseDm(DeepLink.dmUrl("dm:aa-bb")))
        assertEquals(DeepLink.Dm("dm:aa-bb", null), DeepLink.parseDm(DeepLink.dmUrl("dm:aa-bb", "")))
        assertNull("only dm: circles are threads", DeepLink.parseDm("haven://m/plain-circle"))
        assertNull(DeepLink.parseDm("haven://c/dm:aa")); assertNull(DeepLink.parseDm("")); assertNull(DeepLink.parseDm("haven://m"))
    }

    @Test fun circle_links_round_trip() {
        assertEquals(DeepLink.Circle("default"), DeepLink.parseCircle(DeepLink.circleUrl("default")))
        assertEquals(DeepLink.Circle("a b"), DeepLink.parseCircle(DeepLink.circleUrl("a b")))
        assertNull(DeepLink.parseCircle("haven://c")); assertNull(DeepLink.parseCircle("haven://m/x")); assertNull(DeepLink.parseCircle(null))
    }

    @Test fun interaction_link_picks_thread_post_or_circle() {
        assertTrue(DeepLink.interactionLink("dm:a-b", "m1")!!.startsWith("haven://m/"))
        assertTrue(DeepLink.interactionLink("dm:a-b")!!.startsWith("haven://m/"))
        assertTrue(DeepLink.interactionLink("c1", "p1")!!.startsWith("haven://p/"))
        assertTrue(DeepLink.interactionLink("c1")!!.startsWith("haven://c/"))
        assertTrue(DeepLink.interactionLink("c1", "")!!.startsWith("haven://c/"))
    }

    @Test fun first_story_in_finds_a_pointer_in_free_text() {
        val link = DeepLink.storyUrl("c", "s")!!
        val (story, token) = DeepLink.firstStoryIn("love this!\n$link")!!
        assertEquals(DeepLink.Story("c", "s"), story); assertEquals(link, token)
        assertNull(DeepLink.firstStoryIn("no links here"))
        assertNull(DeepLink.firstStoryIn("see ${DeepLink.postUrl("c", "p")}"))
        // not whitespace-separated: falls through to the regex scans
        assertEquals(DeepLink.Story("c", "s"), DeepLink.firstStoryIn("see:$link")?.first)
        assertEquals(DeepLink.Story("c", "s"), DeepLink.firstStoryIn("x,haven://s/c/s")?.first)
    }

    // ---- story reply resolution -------------------------------------------------------------

    private val day = 24L * 3600 * 1000
    private fun live(author: String, me: Boolean, at: Long, media: Boolean = true) = DeepLink.LiveStory(author, me, at, media)
    private fun target(
        body: String = "", media: List<String> = listOf("img_aaa"), isMe: Boolean = false, at: Long = 10 * day,
        peer: String? = "abcdef0123456789", unsent: Boolean = false,
        stories: List<Triple<String, String, DeepLink.LiveStory>> = emptyList(), kept: List<Pair<String, Long>> = emptyList(),
    ) = DeepLink.storyReplyTarget(body, media, isMe, "abcdef01", at, peer, unsent, stories, kept)

    @Test fun explicit_link_wins_and_unsent_messages_resolve_to_nothing() {
        val link = DeepLink.storyUrl("c", "s")!!
        assertEquals(DeepLink.Story("c", "s"), target(body = "hey $link"))
        assertNull(target(body = "hey $link", unsent = true))
    }

    @Test fun legacy_reply_from_a_friend_matches_that_friends_recent_story() {
        val s = listOf(
            Triple("c1", "old", live("abcdef01", false, 10 * day - 2 * day)),   // too old
            Triple("c1", "mine", live("myself01", true, 10 * day - 1000)),      // my own story: not theirs
            Triple("c1", "other", live("ffff0000", false, 10 * day - 1000)),    // another author
            Triple("c1", "hit-old", live("abcdef01", false, 10 * day - 5000)),
            Triple("c2", "hit-new", live("abcdef0123", false, 10 * day - 1000)),
            Triple("c1", "future", live("abcdef01", false, 10 * day + 1)),      // posted after the reply
            Triple("c1", "nomedia", live("abcdef01", false, 10 * day - 10, media = false)),
        )
        assertEquals(DeepLink.Story("c2", "hit-new"), target(isMe = true, stories = s))
    }

    @Test fun legacy_reply_to_my_story_considers_my_live_and_kept_stories() {
        val s = listOf(Triple("c1", "live-mine", live("me", true, 10 * day - 3000)))
        assertEquals(DeepLink.Story("c1", "live-mine"), target(isMe = false, stories = s))
        val kept = listOf("kept-1" to (10 * day - 1000), "kept-ancient" to (10 * day - 8 * day), "kept-future" to (10 * day + 5))
        assertEquals(DeepLink.Story(DEFAULT_CIRCLE, "kept-1"), target(stories = s, kept = kept))
    }

    @Test fun reply_i_sent_never_matches_my_own_stories() {
        val s = listOf(Triple("c1", "live-mine", live("me", true, 10 * day - 3000)))
        assertNull(target(isMe = true, stories = s))
    }

    @Test fun ambiguous_or_missing_media_resolves_to_nothing() {
        val s = listOf(Triple("c1", "x", live("me", true, 10 * day - 3000)))
        assertNull("two visuals", target(media = listOf("img_a", "img_b"), stories = s))
        assertNull("audio only", target(media = listOf("aud_a"), stories = s))
        assertNull("no media", target(media = emptyList(), stories = s))
        assertEquals("a thumb marker is not a second visual", DeepLink.Story("c1", "x"),
            target(media = listOf("img_a", "thumb:img_a:img_t"), stories = s))
    }

    @Test fun group_replies_without_a_peer_fall_back_to_nothing_for_friend_authors() {
        val s = listOf(Triple("c1", "x", live("abcdef01", false, 10 * day - 3000)))
        assertNull(target(isMe = true, peer = null, stories = s))
    }
}
