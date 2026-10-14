package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import java.io.File
import java.security.MessageDigest

/**
 * The surface "Load history from your relays" and lazy history paging stand on: full relay listings that ignore the delta digest
 * and the seen-set, single-key fetches, saving the engine before keys are trusted, and the page-by-page history ask.
 */
class HavenNetHistoryTest {
    private val env = NetEnv()
    private val peer = "c3".repeat(32)

    @Before fun setUp() {
        env.up()
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 2u), CircleInfoFfi("dm:a-b", "dm", 2u))
        HavenNet.contacts.add(Contact(peer, "Pat", "v"))
    }
    @After fun tearDown() { env.down() }

    private fun listing(circle: String = "default") = runBlocking { HavenNet.historyList(circle, env.relayHex) }
    private fun get(key: String) = runBlocking { HavenNet.historyGet(env.relayHex, key) }

    // ---- full listings ------------------------------------------------------------------------------

    @Test fun the_whole_mailbox_is_listed_regardless_of_what_has_been_seen() {
        env.relay.store["haven/mailbox/default/a"] = byteArrayOf(1); env.relay.store["haven/mailbox/default/b"] = byteArrayOf(2)
        env.relay.store["haven/mailbox/other/z"] = byteArrayOf(3)
        env.seen().let { @Suppress("UNCHECKED_CAST") (it as MutableSet<String>).add("haven/mailbox/default/a") }
        assertEquals(listOf("haven/mailbox/default/a", "haven/mailbox/default/b"), listing())
        assertEquals("an empty mailbox is a listing, not a failure", emptyList<String>(), listing("dm:a-b"))
    }

    @Test fun a_relay_that_refuses_or_cannot_be_reached_has_no_listing() {
        env.relay.forceStatus = 403
        assertNull(listing())
        assertTrue("a refusal is queued for the roster heal", (NetEnv.field("rosterNeeded").get(HavenNet) as Set<*>).contains(env.relayHex))
        env.relay.forceStatus = 500
        assertNull(listing())
        assertTrue((NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>).containsKey(env.relay.base))
    }

    @Test fun a_relay_with_no_http_interface_cannot_be_listed_without_a_dial() {
        assertNull(runBlocking { HavenNet.historyList("default", "77".repeat(32)) })
    }

    @Test fun a_single_key_comes_back_or_is_a_clean_miss() {
        env.relay.store["haven/mailbox/default/a"] = byteArrayOf(5, 6)
        env.relay.store["haven/mailbox/default/empty"] = ByteArray(0)
        assertArrayEquals(byteArrayOf(5, 6), get("haven/mailbox/default/a"))
        assertNull(get("haven/mailbox/default/missing"))
        assertNull("an empty body is not an envelope", get("haven/mailbox/default/empty"))
        env.relay.forceStatus = 403
        assertNull(get("haven/mailbox/default/a"))
        env.relay.forceStatus = 500
        assertNull(get("haven/mailbox/default/a"))
    }

    // ---- engine hooks ---------------------------------------------------------------------------------

    @Test fun the_resync_only_sees_the_engine_once_it_is_booted_and_reads_circles_and_relays_from_it() {
        assertNotNull(HavenNet.historySocial)
        assertEquals(listOf("default", "dm:a-b"), HavenNet.historyCircleIds())
        assertEquals(listOf(env.relayHex), HavenNet.historyRelayNodes("default"))
        NetEnv.field("ready").setBoolean(HavenNet, false)
        assertNull(HavenNet.historySocial)
        env.social.failReads = true
        assertTrue(HavenNet.historyCircleIds().isEmpty())
        assertTrue(HavenNet.historyJournalFile.name.startsWith("haven_relay_history"))
    }

    @Test fun keys_are_trusted_only_after_the_engine_state_is_saved() {
        env.social.exported = byteArrayOf(8)
        assertTrue(HavenNet.historySave())
        assertArrayEquals(byteArrayOf(8), File(env.ctx.filesDir, "haven_social_state_${env.me}.bin").readBytes())
        env.social.exported = null   // the engine can no longer export: a failed save must not report success
        assertFalse(HavenNet.historySave())
    }

    @Test fun processed_keys_join_the_ordinary_seen_set() {
        HavenNet.historyMarkSeen(listOf("haven/mailbox/default/k1", "haven/mailbox/default/k2"))
        assertTrue(env.seen().contains("haven/mailbox/default/k1") && env.seen().contains("haven/mailbox/default/k2"))
    }

    @Test fun landing_history_repaints_the_feed_once() {
        val v = HavenNet.feedVersion.value
        runBlocking { HavenNet.historyLanded() }
        assertTrue(HavenNet.feedVersion.value > v)
    }

    @Test fun history_media_is_fetched_relay_first_and_a_held_blob_needs_no_fetch() {
        val plain = ByteArray(300) { (it * 5 % 251).toByte() }
        val ref = "img_" + MessageDigest.getInstance("SHA-256").digest(plain).joinToString("") { "%02x".format(it) }
        env.relay.store["haven/media/$ref"] = plain
        env.social.openMedia = { _, sealed -> sealed }   // a legacy blob stored unsealed opens as itself
        assertTrue(runBlocking { HavenNet.historyFetchMedia("default", ref) })
        assertTrue(LocalMedia.has(ref))
        env.relay.hits.clear()
        assertTrue(runBlocking { HavenNet.historyFetchMedia("default", ref) })
        assertTrue(env.relay.hits.isEmpty())
        assertFalse(runBlocking { HavenNet.historyFetchMedia("default", "img_" + "ee".repeat(32)) })
    }

    // ---- paging ----------------------------------------------------------------------------------------------

    @Test fun older_history_is_asked_for_once_per_cursor() {
        env.social.myNode = env.me
        HavenNet.requestOlderHistory("default", 0uL)
        val asked = NetEnv.field("historyAskedBefore").get(HavenNet) as Map<*, *>
        assertTrue("a zero cursor asks nothing", asked.isEmpty())
        HavenNet.requestOlderHistory("default", 1_000uL)
        assertEquals(1_000uL, asked["default"])
        HavenNet.requestOlderHistory("default", 1_000uL)
        HavenNet.requestOlderHistory("default", 500uL)
        assertEquals("scrolling further moves the cursor", 500uL, asked["default"])
    }

    @Test fun a_members_page_request_is_served_one_page_and_a_strangers_is_not() {
        env.social.pages["default"] = listOf(byteArrayOf(1), byteArrayOf(2))
        val ask = Wire.historyReqPayload(peer, 5_000uL, "default")
        NetEnv.call("handleHistoryRequest", ask)
        assertEquals(listOf(Triple("default", 5_000uL, HavenNet.HISTORY_PAGE_SIZE)), env.social.pageAsks.toList())
        NetEnv.call("handleHistoryRequest", Wire.historyReqPayload("e5".repeat(32), 5_000uL, "default"))
        NetEnv.call("handleHistoryRequest", ByteArray(10))
        assertEquals("no work spent on a stranger or a malformed ask", 1, env.social.pageAsks.size)
    }
}
