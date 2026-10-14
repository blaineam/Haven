package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.ContactRosterWire

/**
 * Device rosters over the relay: publishing my account-signed roster (the write that authorizes this device at a
 * headless relay), pulling a contact's roster back, and recovering when the relay holds a NEWER one of mine.
 */
class HavenNetRosterTest {
    private val env = NetEnv()
    private val friend = "f1".repeat(32)
    private lateinit var mine: String
    private val v1 = byteArrayOf(1, 1, 1)
    private val v2 = byteArrayOf(2, 2, 2, 2)

    @Before fun setUp() {
        env.up()
        mine = env.me
        env.social.ownRoster = listOf(ContactRosterWire(mine, v1))
        rosterPublished().clear()
    }
    @After fun tearDown() { env.down() }

    @Suppress("UNCHECKED_CAST")
    private fun rosterPublished() = NetEnv.field("rosterPublished").get(HavenNet) as MutableMap<String, Pair<Int, Long>>
    private fun publish(force: Boolean = false) = NetEnv.call("publishDeviceRoster", force)
    private fun fetch(hex: String) = runBlocking { HavenNet.fetchContactRoster(hex) }
    private val devKey get() = "haven/devroster/$mine"

    // ---- publish --------------------------------------------------------------------------------

    @Test fun my_roster_is_put_under_my_account_key_on_every_relay() {
        publish()
        assertArrayEquals(v1, env.relay.store[devKey])
        assertTrue("remembered, so an unchanged roster is not re-sent", rosterPublished().containsKey(env.relayHex))
    }

    @Test fun an_unchanged_roster_is_not_re_sent_but_a_changed_one_or_a_forced_one_is() {
        publish()
        env.relay.hits.clear()
        publish()
        assertTrue(env.relay.puts().isEmpty())
        publish(force = true)
        assertEquals(1, env.relay.puts().size)
        env.relay.hits.clear()
        env.social.ownRoster = listOf(ContactRosterWire(mine, v2))
        publish()
        assertArrayEquals("any change republishes immediately", v2, env.relay.store[devKey])
    }

    @Test fun nothing_is_published_without_a_roster() {
        env.social.ownRoster = emptyList()
        publish()
        env.social.ownRoster = listOf(ContactRosterWire(mine, ByteArray(0)))
        publish()
        assertTrue(env.relay.hits.isEmpty())
    }

    @Test fun a_broken_relay_backs_the_url_off_and_is_not_marked_published() {
        env.relay.forceStatus = 500
        publish()
        assertFalse(rosterPublished().containsKey(env.relayHex))
        assertTrue((NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>).containsKey(env.relay.base))
    }

    @Test fun a_refused_publish_adopts_the_newer_roster_the_relay_holds_and_publishes_at_that_version() {
        // The relay holds a NEWER roster of mine; the publish of v1 is refused (rollback defense).
        env.social.rosterStatus = { w -> if (w.contentEquals(v2)) 1 else -1 }
        env.relay.store[devKey] = v2
        env.relay.putStatus[devKey] = 403
        // Once the newer roster is ingested the engine exports it, and the relay accepts my writes again.
        env.social.onIngest = { w ->
            if (w.contentEquals(v2)) { env.social.ownRoster = listOf(ContactRosterWire(mine, v2)); env.relay.putStatus.clear() }
        }
        publish()
        assertTrue("the newer roster was pulled back and ingested", env.social.ingestedRosters.any { it.contentEquals(v2) })
        assertArrayEquals("and then re-published at that version", v2, env.relay.store[devKey])
        assertEquals(v2.contentHashCode(), rosterPublished().getValue(env.relayHex).first)
    }

    @Test fun a_refusal_where_the_stored_roster_is_the_one_we_sent_is_not_a_rollback() {
        env.relay.store[devKey] = v1
        env.relay.putStatus[devKey] = 403
        env.social.rosterStatus = { 1 }   // ingests fine, but the engine still exports v1: identical to the refused wire
        publish()
        assertEquals("only the refused publish went out", 1, env.relay.puts().size)
    }

    @Test fun a_refusal_where_the_stored_roster_is_already_current_adopts_nothing() {
        env.relay.store[devKey] = v1
        env.relay.putStatus[devKey] = 403
        env.social.rosterStatus = { 0 }
        publish()
        assertEquals(1, env.relay.puts().size)
    }

    @Test fun a_refusal_with_nothing_readable_back_gives_up_quietly() {
        env.relay.putStatus[devKey] = 403
        publish()
        assertEquals(1, env.relay.puts().size)
    }

    // ---- fetch ----------------------------------------------------------------------------------

    @Test fun a_contacts_roster_is_pulled_from_the_relay_and_ingested() {
        env.relay.store["haven/devroster/$friend"] = v2
        env.social.rosterStatus = { 1 }
        assertTrue(fetch(friend))
        assertArrayEquals(v2, env.social.ingestedRosters.single())
    }

    @Test fun an_already_known_roster_keeps_asking_other_relays_and_reports_no_change() {
        env.relay.store["haven/devroster/$friend"] = v2
        env.social.rosterStatus = { 0 }
        assertFalse(fetch(friend))
        assertEquals(1, env.social.ingestedRosters.size)
    }

    @Test fun a_forged_or_rolled_back_roster_is_refused() {
        env.relay.store["haven/devroster/$friend"] = v2
        env.social.rosterStatus = { -1 }
        assertFalse(fetch(friend))
    }

    @Test fun a_relay_with_no_roster_for_them_is_a_miss() {
        assertFalse(fetch(friend))
        assertTrue(env.social.ingestedRosters.isEmpty())
    }

    @Test fun a_refusing_relay_does_not_end_the_search_and_a_broken_one_is_backed_off() {
        env.relay.forceStatus = 403
        assertFalse(fetch(friend))
        env.relay.forceStatus = 500
        assertFalse(fetch(friend))
        assertTrue((NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>).containsKey(env.relay.base))
    }

    @Test fun a_hex_that_is_not_an_account_id_is_not_asked_for() {
        assertFalse(fetch("abc"))
        assertTrue(env.relay.hits.isEmpty())
    }

    // ---- periodic sync -----------------------------------------------------------------------------

    @Test fun the_sync_tick_greets_contacts_pulls_missing_rosters_and_republishes_mine() {
        env.social.myRosterWire = byteArrayOf(5)
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 2u))
        HavenNet.contacts.add(Contact(friend, "Pat", "v"))
        env.relay.store["haven/devroster/$friend"] = v2
        env.social.rosterStatus = { 1 }
        for (t in listOf("lastMediaBackfillMs", "lastHistoryResendMs", "lastRelayReannounceMs", "lastOwnDeviceCatchupMs"))
            NetEnv.field(t).setLong(HavenNet, 0L)   // the sweep's own throttles are process-wide
        val published = env.relay.latchForPuts(1)
        HavenNet.syncWithContacts()
        assertTrue("the periodic sweep re-published my roster", env.relay.awaitPuts(published))
        assertArrayEquals(v1, env.relay.store[devKey])
    }

    @Test fun the_sync_tick_does_nothing_before_the_engine_is_ready() {
        NetEnv.field("ready").setBoolean(HavenNet, false)
        HavenNet.syncWithContacts()
        assertTrue(env.relay.hits.isEmpty())
    }
}
