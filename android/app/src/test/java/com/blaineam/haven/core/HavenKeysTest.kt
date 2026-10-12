package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest

/** Store keys, DM ids, manifests, invite links and media frames — formats shared with iOS/desktop. */
class HavenKeysTest {
    private val K = HavenKeys
    private val a = "aa".repeat(32)
    private val b = "bb".repeat(32)
    private val c = "cc".repeat(32)

    @Test fun mailbox_key_is_the_content_hash_under_the_circle() {
        val env = "sealed".toByteArray()
        val h = MessageDigest.getInstance("SHA-256").digest(env).joinToString("") { "%02x".format(it) }
        assertEquals("haven/mailbox/circ/$h", K.mailboxKey("circ", env))
        assertEquals("same envelope, same slot", K.mailboxKey("circ", env), K.mailboxKey("circ", env.copyOf()))
        assertNotEquals(K.mailboxKey("circ", env), K.mailboxKey("circ", "other".toByteArray()))
    }

    @Test fun hello_key_lowercases_both_accounts_and_hashes_the_body() {
        val k = K.helloMailboxKey("circ", "AB", "CD", "hi".toByteArray())
        assertTrue(k.startsWith("haven/mailbox/circ/__hello__/ab/cd/"))
        assertEquals(64, k.substringAfterLast('/').length)
        assertEquals(k, K.helloMailboxKey("circ", "ab", "cd", "hi".toByteArray()))
    }

    @Test fun control_plane_keys_sort_ahead_of_content() {
        val keys = listOf("haven/mailbox/c/abc", "haven/mailbox/c/__relay__/x", "haven/mailbox/c/__hello__/a/b/d")
        assertEquals(listOf(0, 1, 2), keys.sortedBy { K.mailboxKeyRank(it) }.map { K.mailboxKeyRank(it) })
        assertEquals(keys[2], keys.minByOrNull { K.mailboxKeyRank(it) })
    }

    @Test fun media_keys_keep_chunks_and_scope_beside_the_manifest_not_under_it() {
        assertEquals("haven/media/vid_x", K.mediaKey("vid_x"))
        assertEquals("haven/media/vid_x.p/3", K.mediaChunkKey("vid_x", 3))
        assertEquals("haven/media/vid_x.c/circ", K.mediaScopeKey("vid_x", "circ"))
        assertFalse(K.mediaChunkKey("vid_x", 0).startsWith(K.mediaKey("vid_x") + "/"))
    }

    @Test fun manifest_round_trips_the_chunk_count() {
        val m = K.makeManifest(listOf(8, 8, 3))
        assertTrue(String(m, Charsets.UTF_8).startsWith("HVCHUNK1\n"))
        assertEquals(3, K.parseManifest(m))
        assertEquals(1, K.parseManifest(K.makeManifest(listOf(5))))
    }

    @Test fun anything_that_is_not_a_manifest_parses_to_null() {
        assertNull(K.parseManifest("{\"sealed\":true}".toByteArray()))
        assertNull(K.parseManifest(K.manifestMagic))                       // magic only
        assertNull(K.parseManifest(ByteArray(0)))
        assertNull(K.parseManifest(K.manifestMagic + "not json".toByteArray()))
        assertNull("zero chunks is not a manifest", K.parseManifest(K.makeManifest(emptyList())))
    }

    @Test fun manifest_fingerprint_distinguishes_seals_with_the_same_chunk_count() {
        val one = K.makeManifest(listOf(8, 8)); val two = K.makeManifest(listOf(8, 7))
        assertEquals(2, K.parseManifest(one)); assertEquals(2, K.parseManifest(two))
        assertEquals(16, K.manifestFingerprint(one).length)
        assertNotEquals(K.manifestFingerprint(one), K.manifestFingerprint(two))
        assertEquals(K.manifestFingerprint(one), K.manifestFingerprint(one.copyOf()))
    }

    @Test fun dm_circle_id_is_identical_from_both_sides() {
        assertEquals("dm:$a-$b", K.dmCircleId(a, b))
        assertEquals(K.dmCircleId(a, b), K.dmCircleId(b, a))
    }

    @Test fun group_dm_id_is_order_case_and_duplicate_insensitive_and_includes_me() {
        val id = K.groupDmCircleId(c, listOf(b.uppercase(), a, a))
        assertEquals("dm:$a-$b-$c", id)
        assertEquals(id, K.groupDmCircleId(a, listOf(c, b)))
    }

    @Test fun dm_members_and_membership_checks() {
        val id = K.groupDmCircleId(a, listOf(b, c))
        assertEquals(listOf(a, b, c), K.dmMemberHexes(id))
        assertEquals(emptyList<String>(), K.dmMemberHexes("dm:short-ids"))
        assertEquals("a plain circle has no dm members", emptyList<String>(), K.dmMemberHexes("default"))
        assertTrue(K.dmAllows(id, b)); assertFalse(K.dmAllows(id, "dd".repeat(32)))
        assertFalse("a lone id is not a thread", K.dmAllows("dm:$a", a))
    }

    @Test fun invite_ticket_goes_after_hints_and_before_the_fragment() {
        assertEquals("https://x/i?d=1&t=T#frag", K.embedInviteTicket("https://x/i?d=1#frag", "T"))
        assertEquals("https://x/i?t=T#frag", K.embedInviteTicket("https://x/i#frag", "T"))
        assertEquals("https://x/i?t=T", K.embedInviteTicket("https://x/i", "T"))
        assertEquals("https://x/i?d=1&t=T", K.embedInviteTicket("https://x/i?d=1", "T"))
    }

    @Test fun invite_ticket_extract_inverts_embed_and_ignores_lookalikes() {
        for (link in listOf("https://x/i?d=1#f", "https://x/i#f", "https://x/i")) {
            assertEquals("tick", K.extractInviteTicket(K.embedInviteTicket(link, "tick")))
        }
        assertNull(K.extractInviteTicket("https://x/i"))
        assertNull(K.extractInviteTicket("https://x/i?t=#f"))
        assertNull(K.extractInviteTicket("https://x/i#f?t=hidden"))
        assertNull(K.extractInviteTicket("https://x/i?tt=1&x=t"))
        assertEquals("2", K.extractInviteTicket("https://x/i?a=1&t=2&t=3"))
    }

    @Test fun media_frame_round_trips_and_lowercases_the_sender() {
        val body = K.mediaFrameBody(a.uppercase(), "img_ref", "circ", "post1")
        val f = K.parseMediaFrame(body)!!
        assertEquals(HavenKeys.MediaFrame(a, "img_ref", "circ", "post1"), f)
        assertEquals("", K.parseMediaFrame(K.mediaFrameBody(a, "r", "c", ""))!!.postId)
    }

    @Test fun malformed_media_frames_are_rejected() {
        assertNull(K.parseMediaFrame(ByteArray(10)))
        assertNull(K.parseMediaFrame(a.toByteArray()))                      // sender only
        assertNull(K.parseMediaFrame(K.mediaFrameBody(a, "", "c", "p")))    // empty ref
        assertNull(K.parseMediaFrame(K.mediaFrameBody(a, "r", "", "p")))    // empty circle
        val truncated = K.mediaFrameBody(a, "ref", "circ", "post").let { it.copyOf(it.size - 3) }
        assertNull(K.parseMediaFrame(truncated))
    }

    @Test fun hex_helpers_round_trip_32_bytes_and_reject_bad_input() {
        val bytes = ByteArray(32) { it.toByte() }
        val hex = K.bytesToHex(bytes)
        assertEquals(64, hex.length)
        assertArrayEquals(bytes, K.hexToBytes32(hex))
        assertNull(K.hexToBytes32("abcd")); assertNull(K.hexToBytes32("zz".repeat(32)))
    }
}
