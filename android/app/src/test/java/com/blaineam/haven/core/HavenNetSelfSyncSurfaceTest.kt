package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The HavenNet surface the self-sync coordinator drives: the signed-HTTP rung of the slot transport, the relay
 * delete / re-add tombstones (last-writer-wins by their semantic time), and the contact / blocked reconcilers.
 */
class HavenNetSelfSyncSurfaceTest {
    private val env = NetEnv()
    private val slot = "haven/self/${"a1".repeat(32)}/dev1"

    @Before fun setUp() { env.up() }
    @After fun tearDown() { env.down() }

    // ---- slot transport over HTTP -------------------------------------------------------------------

    @Test fun a_slot_round_trips_over_the_http_rung() {
        assertTrue(HavenNet.selfSyncHttpPut(env.relayHex, slot, byteArrayOf(1, 2, 3)))
        assertArrayEquals(byteArrayOf(1, 2, 3), HavenNet.selfSyncHttpGet(env.relayHex, slot))
        assertEquals(listOf(slot), HavenNet.selfSyncHttpList(env.relayHex, "haven/self/"))
        assertNull("a slot nobody wrote is a miss", HavenNet.selfSyncHttpGet(env.relayHex, "$slot-none"))
    }

    @Test fun a_relay_without_an_http_interface_carries_no_slots() {
        val bare = "77".repeat(32)
        assertNull(HavenNet.selfSyncHttpList(bare, "haven/self/"))
        assertNull(HavenNet.selfSyncHttpGet(bare, slot))
        assertFalse(HavenNet.selfSyncHttpPut(bare, slot, byteArrayOf(1)))
        env.entries()[bare] = HavenNet.RelayEntry(bare, "b", true, 0, false)
        assertNull("known but with no usable interface", HavenNet.selfSyncHttpList(bare, "haven/self/"))
    }

    @Test fun a_refusal_is_recorded_for_the_roster_heal_and_never_backs_the_url_off() {
        env.relay.forceStatus = 403
        assertNull(HavenNet.selfSyncHttpList(env.relayHex, "haven/self/"))
        assertNull(HavenNet.selfSyncHttpGet(env.relayHex, slot))
        assertFalse(HavenNet.selfSyncHttpPut(env.relayHex, slot, byteArrayOf(1)))
        assertTrue((NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>).isEmpty())
        assertTrue((NetEnv.field("rosterNeeded").get(HavenNet) as Set<*>).contains(env.relayHex))
    }

    @Test fun an_unreachable_relay_is_backed_off_on_each_verb() {
        env.relay.forceStatus = 500
        assertNull(HavenNet.selfSyncHttpList(env.relayHex, "haven/self/"))
        assertTrue((NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>).containsKey(env.relay.base))
    }

    @Test fun every_adopted_relay_is_a_self_sync_transport_and_the_hosted_store_is_absent_without_hosting() {
        assertEquals(listOf(env.relayHex), HavenNet.selfSyncRelays())
        assertNull(HavenNet.selfSyncLocalStore(env.relayHex))
    }

    // ---- relay tombstones (LWW) -----------------------------------------------------------------------

    private val relay = "99".repeat(32)
    private fun adopt() { env.entries()[relay] = HavenNet.RelayEntry(relay, "r", true, 0, false, addedAtMs = 1_000L) }

    @Test fun a_deletion_newer_than_my_adoption_forgets_the_relay_and_an_older_one_does_not() {
        adopt()
        HavenNet.applyRelayForgottenTombstone(relay, 500L)
        assertTrue("older than my adoption: a newer local re-add wins", env.entries().getValue(relay).active)
        HavenNet.applyRelayForgottenTombstone(relay, 5_000L)
        assertFalse(env.entries().getValue(relay).active)
        assertEquals(5_000L, HavenNet.relayForgottenRecords()[relay])
        HavenNet.applyRelayForgottenTombstone(relay, 4_000L)
        assertEquals("an earlier deletion changes nothing", 5_000L, HavenNet.relayForgottenRecords()[relay])
        HavenNet.applyRelayForgottenTombstone(relay, 0L)
        HavenNet.applyRelayForgottenTombstone("s3:bucket", 9_000L)
        assertTrue(HavenNet.relayForgottenRecords().containsKey("s3:bucket"))
    }

    @Test fun a_re_add_only_lifts_a_deletion_it_is_newer_than() {
        adopt()
        HavenNet.applyRelayForgottenTombstone(relay, 5_000L)
        HavenNet.applyRelayClearedForget(relay, 4_000L)
        assertTrue("my deletion is newer: the delete wins", HavenNet.relayForgottenRecords().containsKey(relay))
        HavenNet.applyRelayClearedForget(relay, 6_000L)
        assertFalse(HavenNet.relayForgottenRecords().containsKey(relay))
        assertEquals(6_000L, HavenNet.relayClearedForgetRecords()[relay])
        HavenNet.applyRelayClearedForget(relay, 6_000L)
        HavenNet.applyRelayClearedForget(relay, 0L)
        assertEquals(6_000L, HavenNet.relayClearedForgetRecords()[relay])
        HavenNet.applyRelayForgottenTombstone(relay, 3_000L)
        assertTrue("a delete older than a re-add is ignored", HavenNet.relayClearedForgetRecords().containsKey(relay))
    }

    @Test fun a_relay_learned_from_a_synced_circle_is_added_unless_it_is_deactivated_or_malformed() {
        adopt()
        HavenNet.selfSyncAddRelay("c1group", relay.uppercase())
        assertEquals(listOf(relay), HavenNet.relaysForCircle("c1group").filter { it == relay })
        HavenNet.selfSyncAddRelay("c1group", "short")
        val dead = "88".repeat(32)
        env.entries()[dead] = HavenNet.RelayEntry(dead, "d", false, 0, false)
        HavenNet.selfSyncAddRelay("c1group", dead)
        assertFalse(HavenNet.relaysForCircle("c1group").contains(dead))
    }

    // ---- contact / blocked reconcilers -----------------------------------------------------------------

    @Test fun a_contact_upsert_adds_updates_and_respects_a_removal_tombstone() {
        val a = "ad".repeat(32)   // its own id: removal stamps live in a process-wide store
        HavenNet.selfSyncUpsertContact(Contact(a, "Pat", "v1"))
        HavenNet.selfSyncUpsertContact(Contact(a, "Patricia", "v1"))
        assertEquals(listOf("Patricia"), HavenNet.selfSyncContactsSnapshot().map { it.name })
        HavenNet.selfSyncRemoveContact(a)
        assertTrue(HavenNet.selfSyncContactsSnapshot().isEmpty())
        ContactRemovals.markRemoved(a)
        HavenNet.selfSyncUpsertContact(Contact(a, "Pat", "v1"))
        assertTrue("a tombstoned contact is not resurrected by sync", HavenNet.selfSyncContactsSnapshot().isEmpty())
        ContactRemovals.markReadded(a)
    }

    @Test fun blocking_and_unblocking_reconcile_without_duplicates() {
        val a = "f2".repeat(32)
        HavenNet.selfSyncSetBlocked(a, true)
        HavenNet.selfSyncSetBlocked(a, true)
        assertEquals(listOf(a), HavenNet.selfSyncBlockedSnapshot())
        HavenNet.selfSyncSetBlocked(a, false)
        HavenNet.selfSyncSetBlocked(a, false)
        assertTrue(HavenNet.selfSyncBlockedSnapshot().isEmpty())
    }

    // ---- nudge ------------------------------------------------------------------------------------------

    @Test fun local_edits_schedule_one_debounced_push_and_a_burst_rides_it() {
        val job = NetEnv.field("selfSyncNudgeJob")
        job.set(HavenNet, null)
        HavenNet.selfSyncNudge()
        val first = job.get(HavenNet)
        assertTrue((first as kotlinx.coroutines.Job).isActive)
        HavenNet.selfSyncNudge()
        assertTrue("the timer is not restarted: a burst can't starve the push", job.get(HavenNet) === first)
        NetEnv.field("ready").setBoolean(HavenNet, false)
        job.set(HavenNet, null)
        HavenNet.selfSyncNudge()
        assertNull("pre-start edits publish on the launch poll instead", job.get(HavenNet))
    }

    // ---- the coordinator's relay transport ---------------------------------------------------------------

    private fun transport(hex: String): Any =
        Class.forName("com.blaineam.haven.core.SelfSyncCoordinator\$RelayTransport")
            .getDeclaredConstructor(String::class.java).apply { isAccessible = true }.newInstance(hex)

    @Test fun the_relay_transport_falls_through_to_the_signed_http_rung_for_list_get_and_put() {
        val t = transport(env.relayHex)
        assertEquals("relay:${env.relayHex.take(8)}", NetEnv.callOn(t, "getLabel"))
        assertEquals(true, NetEnv.callOn(t, "put", slot, byteArrayOf(4, 5)))
        assertArrayEquals(byteArrayOf(4, 5), NetEnv.callOn(t, "get", slot) as ByteArray?)
        assertEquals(listOf(slot), NetEnv.callOn(t, "list", "haven/self/"))
        assertNull(NetEnv.callOn(t, "get", "$slot-none"))
    }

    @Test fun the_relay_transport_reports_a_relay_that_cannot_carry_slots() {
        val t = transport("77".repeat(32))   // no entry, no dial: nothing to talk to
        assertEquals(false, NetEnv.callOn(t, "put", slot, byteArrayOf(1)))
        assertNull(NetEnv.callOn(t, "get", slot))
        assertNull(NetEnv.callOn(t, "list", "haven/self/"))
    }
}
