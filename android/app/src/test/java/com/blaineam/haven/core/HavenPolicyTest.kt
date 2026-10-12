package com.blaineam.haven.core

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Poll cadence, media-ask targeting, relay-hint budget, push banner and chunk-frame rules. */
class HavenPolicyTest {
    // ---- PollCadence ------------------------------------------------------------------------

    @Test fun idle_users_are_polled_less_often() {
        assertEquals(1L, PollCadence.multiplier(0, null, false))
        assertEquals(1L, PollCadence.multiplier(179_999, null, false))
        assertEquals(3L, PollCadence.multiplier(180_000, null, false))
        assertEquals(3L, PollCadence.multiplier(899_999, null, false))
        assertEquals(6L, PollCadence.multiplier(900_000, null, false))
    }

    @Test fun a_hot_phone_backs_off_further() {
        val statuses = mapOf(0 to 1L, 1 to 1L, 2 to 1L, 3 to 2L, 4 to 2L, 5 to 2L, 6 to 2L)
        // THERMAL_STATUS_NONE/LIGHT = 0/1 leave the cadence alone; MODERATE (2) is x1.5; SEVERE+ (3..6) x2.
        assertEquals(1L, PollCadence.multiplier(0, 0, false)); assertEquals(1L, PollCadence.multiplier(0, 1, false))
        assertEquals(1L, PollCadence.multiplier(0, 2, false))        // 1 * 3 / 2 == 1 (integer)
        assertEquals(4L, PollCadence.multiplier(180_000, 2, false))  // 3 * 3 / 2
        for ((s, m) in statuses.filter { it.key >= 3 }) assertEquals(m, PollCadence.multiplier(0, s, false))
        assertEquals(12L, PollCadence.multiplier(900_000, 6, false))
    }

    @Test fun data_saver_adds_half_again() {
        assertEquals(1L, PollCadence.multiplier(0, null, true))      // 1 * 3 / 2 rounds to 1 but never below 1
        assertEquals(4L, PollCadence.multiplier(180_000, null, true))
        assertEquals(9L, PollCadence.multiplier(900_000, null, true))
        assertEquals(18L, PollCadence.multiplier(900_000, 3, true))
    }

    @Test fun foreground_polling_never_stretches_past_twice_the_base() {
        assertEquals(60L, PollCadence.mailboxInterval(full = 180, base = 30, foreground = true))
        assertEquals(45L, PollCadence.mailboxInterval(full = 45, base = 30, foreground = true))
        assertEquals(180L, PollCadence.mailboxInterval(full = 180, base = 30, foreground = false))
    }

    // ---- MediaAsk ---------------------------------------------------------------------------

    private val friends = listOf("aaaa1111", "bbbb2222", "cccc3333")

    @Test fun the_first_asks_go_to_the_author_only() {
        assertEquals(listOf("bbbb2222"), MediaAsk.targets(friends, 1, "bbbb", 2))
        assertEquals(listOf("bbbb2222"), MediaAsk.targets(friends, 2, "BBBB", 2))
    }

    @Test fun later_asks_widen_to_everyone() {
        assertEquals(friends, MediaAsk.targets(friends, 3, "bbbb", 2))
    }

    @Test fun an_unknown_author_or_one_who_is_not_a_friend_asks_everyone() {
        assertEquals(friends, MediaAsk.targets(friends, 1, null, 2))
        assertEquals(friends, MediaAsk.targets(friends, 1, "dddd", 2))
    }

    @Test fun my_own_media_is_never_asked_of_a_friend() {
        assertEquals(emptyList<String>(), MediaAsk.targets(friends, 1, MediaAsk.SELF_AUTHOR, 2))
        assertEquals("but after the widening point even own media asks around", friends, MediaAsk.targets(friends, 3, MediaAsk.SELF_AUTHOR, 2))
    }

    // ---- RelayHintBudget ----------------------------------------------------------------------

    @Test fun each_requester_gets_a_fixed_number_of_hints_per_window() {
        var t = 0L
        val b = RelayHintBudget(windowMs = 1000, max = 3, now = { t })
        assertEquals(0, b.count("ref", "alice"))
        assertTrue(b.note("ref", "alice")); assertTrue(b.note("ref", "alice")); assertTrue(b.note("ref", "alice"))
        assertEquals(3, b.count("ref", "alice"))
        assertFalse("budget spent", b.note("ref", "alice"))
        assertTrue("another requester has their own budget", b.note("ref", "bob"))
        assertTrue("another ref has its own budget", b.note("other", "alice"))
    }

    @Test fun the_budget_refills_when_the_window_ends() {
        var t = 0L
        val b = RelayHintBudget(windowMs = 1000, max = 1, now = { t })
        assertTrue(b.note("r", "a")); assertFalse(b.note("r", "a"))
        t = 999; assertFalse(b.note("r", "a")); assertEquals(1, b.count("r", "a"))
        t = 1000; assertEquals(0, b.count("r", "a")); assertTrue(b.note("r", "a"))
    }

    @Test fun the_table_is_bounded() {
        val b = RelayHintBudget(windowMs = 10_000, max = 1, capacity = 5, now = { 0L })
        for (i in 0..5) b.note("r$i", "a")
        assertEquals("a full table is dropped wholesale", 0, b.count("r0", "a"))
    }

    // ---- PushBannerJson ----------------------------------------------------------------------

    @Test fun the_banner_carries_sender_texts_circle_and_kind() {
        val o = JSONObject(String(PushBannerJson.encode("Ana", PushBanner.Copy("comment", "Ana: hi", "New comment"), "circ")!!))
        assertEquals("Ana", o.getString("t")); assertEquals("Ana: hi", o.getString("b")); assertEquals("New comment", o.getString("bp"))
        assertEquals("circ", o.getString("c")); assertEquals("comment", o.getString("k"))
        assertFalse(o.has("e")); assertFalse(o.has("p"))
    }

    @Test fun optional_banner_fields_appear_only_when_present_and_a_blank_name_becomes_someone() {
        val full = JSONObject(String(PushBannerJson.encode("  ", PushBanner.Copy("react", "b", "p", emoji = "🔥", postId = "post1"), "c")!!))
        assertEquals("Someone", full.getString("t")); assertEquals("🔥", full.getString("e")); assertEquals("post1", full.getString("p"))
        val emptyPost = JSONObject(String(PushBannerJson.encode("A", PushBanner.Copy("react", "b", "p", postId = ""), "c")!!))
        assertFalse(emptyPost.has("p"))
    }

    // ---- ChunkFrame --------------------------------------------------------------------------

    @Test fun a_chunk_frame_round_trips() {
        val sealed = ByteArray(1000) { (it % 251).toByte() }
        val f = ChunkFrame.decode(ChunkFrame.encode("vid_abc".toByteArray(), 7, 12, sealed))!!
        assertEquals("vid_abc", f.ref); assertEquals(7, f.index); assertEquals(12, f.total)
        assertArrayEquals(sealed, f.sealed)
    }

    @Test fun the_header_is_little_endian_and_matches_the_other_platforms() {
        val bytes = ChunkFrame.encode("ab".toByteArray(), 0x01020304, 5, byteArrayOf(9))
        assertArrayEquals(byteArrayOf(2, 0, 'a'.code.toByte(), 'b'.code.toByte(), 4, 3, 2, 1, 5, 0, 0, 0, 9), bytes)
    }

    @Test fun truncated_chunk_frames_are_rejected() {
        assertNull(ChunkFrame.decode(ByteArray(0))); assertNull(ChunkFrame.decode(byteArrayOf(5)))
        val ok = ChunkFrame.encode("abcd".toByteArray(), 1, 2, byteArrayOf())
        assertNotNull(ChunkFrame.decode(ok))
        assertNull(ChunkFrame.decode(ok.copyOf(ok.size - 1)))
        assertNull("a ref length that overruns the frame", ChunkFrame.decode(byteArrayOf(0xFF.toByte(), 0xFF.toByte(), 1, 2, 3)))
    }

    @Test fun an_empty_final_chunk_body_is_allowed_by_the_framing() {
        val f = ChunkFrame.decode(ChunkFrame.encode("r".toByteArray(), 0, 1, byteArrayOf()))!!
        assertEquals(0, f.sealed.size)
    }
}
