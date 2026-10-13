package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.OpenedCircleBlobFfi

/**
 * Two inbound handlers that decide who and what the device trusts: the circle HELLO handshake (frame 0) and
 * the relay announce (frame 19). Each branch is a decision with a reason string the mailbox claim log
 * prints, so the outcome AND the reason are asserted.
 */
class HavenNetHandlersTest {
    private val env = NetEnv()
    private val bundle = ByteArray(40) { 0x31 }
    private val who = nodeHex(bundle)
    private val circle = "c1members"

    @Before fun setUp() {
        env.up()
        env.social.verifyHex = { "beef" }
        env.social.profileName = "Pat"
        CircleRemovals.clear()
        ContactRemovals.markReadded(who)
    }
    @After fun tearDown() { env.down(); CircleRemovals.clear() }

    private fun payload(c: String = circle, b: ByteArray = bundle) = Wire.helloPayload(c, "Family", b, byteArrayOf(9, 9))

    private fun hello(p: ByteArray, nearby: Boolean = false, device: String? = null): Pair<Boolean, String> {
        val r = NetEnv.call("handleHello", p, nearby, device)!!
        fun get(n: String) = r.javaClass.getDeclaredMethod(n).apply { isAccessible = true }.invoke(r)
        return (get("getConsumed") as Boolean) to (get("getWhy") as String)
    }

    @Suppress("UNCHECKED_CAST")
    private fun initiated() = NetEnv.field("initiated").get(HavenNet) as MutableMap<String, String>

    // ---- hello ----------------------------------------------------------------------------------

    @Test fun a_payload_that_is_not_a_hello_is_dropped_as_consumed() {
        assertEquals(true to "malformed", hello(byteArrayOf(1)))
    }

    @Test fun a_bundle_the_engine_cannot_verify_is_dropped_as_consumed() {
        env.social.verifyHex = null
        assertEquals(true to "malformed", hello(payload()))
    }

    @Test fun a_blocked_node_cannot_handshake_back_in() {
        HavenNet.blocked.add(who)
        assertEquals(true to "blocked", hello(payload()))
    }

    @Test fun a_direct_hello_teaches_the_senders_dialable_device_id() {
        val dev = "d9".repeat(32)
        hello(payload(), device = dev)
        assertEquals(listOf(dev), (NetEnv.call("deviceHintsFor", who) as List<*>))
    }

    @Test fun only_the_two_members_of_a_dm_may_join_it() {
        val dm = HavenKeys.dmCircleId("a1".repeat(32), "b2".repeat(32))
        assertEquals(true to "dm-third-party", hello(payload(c = dm)))
    }

    @Test fun a_member_i_removed_from_this_circle_cannot_auto_rejoin_but_can_ask_again() {
        CircleRemovals.add(circle, who)
        assertEquals("proximity is not a deliberate request", true to "removed-from-circle", hello(payload(), nearby = true))
        assertTrue(HavenNet.pending.isEmpty())
        assertEquals("a direct hello asks for consent instead of dropping", false to "removed-needs-approval", hello(payload()))
        assertEquals(listOf(who), HavenNet.pending.map { it.idHex })
    }

    @Test fun a_removed_member_in_a_dm_is_dropped_never_asked() {
        val dm = HavenKeys.dmCircleId(env.me, who)
        CircleRemovals.add(dm, who)
        assertEquals(true to "removed-from-circle", hello(payload(c = dm)))
    }

    @Test fun scanning_first_auto_accepts_a_matching_bundle() {
        env.social.lenient = true
        initiated()[who] = "beef"
        assertEquals(true to "applied", hello(payload()))
        assertEquals(listOf(who), HavenNet.contacts.map { it.idHex })
        assertEquals("Pat", HavenNet.contacts.single().name)
        assertTrue(env.social.calls.contains("addBundle $circle"))
        assertTrue("the circle is formed on our side", env.social.calls.contains("create $circle Family"))
        assertNull("the scan promise is spent", initiated()[who])
    }

    @Test fun a_bundle_that_differs_from_the_scanned_one_is_dropped_as_a_possible_mitm() {
        env.social.lenient = true
        initiated()[who] = "0123"
        assertEquals(true to "verify-mismatch", hello(payload()))
        assertTrue(HavenNet.contacts.isEmpty())
    }

    @Test fun a_hello_back_from_an_existing_contact_adds_their_bundle_to_the_circle() {
        env.social.lenient = true
        HavenNet.contacts.add(Contact(who, "Pat", "beef"))
        assertEquals(true to "applied", hello(payload()))
        assertTrue(env.social.calls.contains("addBundle $circle"))
    }

    @Test fun a_transient_engine_failure_leaves_the_hello_for_the_next_poll() {
        HavenNet.contacts.add(Contact(who, "Pat", "beef"))   // lenient is off: addContactBundle throws
        assertEquals(false to "engine-add-failed", hello(payload()))
    }

    @Test fun a_device_bundle_of_a_known_account_is_not_a_new_contact() {
        val account = "ac".repeat(32)
        env.social.accountOfDevice[who] = account
        assertEquals(true to "known-device", hello(payload()))
        assertTrue(HavenNet.contacts.isEmpty() && HavenNet.pending.isEmpty())
        assertEquals(listOf(who), (NetEnv.call("deviceHintsFor", account) as List<*>))
    }

    @Test fun a_member_the_engine_already_lists_is_adopted_as_a_contact() {
        env.social.lenient = true
        env.social.circleList = listOf(CircleInfoFfi("c1other", "Other", 2u))
        env.social.members["c1other"] = listOf(who)
        assertEquals(true to "applied", hello(payload()))
        assertEquals(listOf(who), HavenNet.contacts.map { it.idHex })
    }

    @Test fun a_stranger_over_the_proximity_mesh_is_ignored() {
        assertEquals(true to "nearby-stranger", hello(payload(), nearby = true))
        assertTrue(HavenNet.pending.isEmpty())
    }

    @Test fun a_stranger_is_held_for_approval_and_listed_once() {
        assertEquals(false to "held-for-approval", hello(payload()))
        hello(payload())
        val p = HavenNet.pending.single()
        assertEquals(who, p.idHex); assertEquals("Pat", p.name); assertEquals(circle, p.circleId)
    }

    @Test fun a_dm_stranger_is_held_but_never_listed_as_a_request() {
        val dm = HavenKeys.dmCircleId(env.me, who)
        assertEquals(false to "held-for-approval", hello(payload(c = dm)))
        assertTrue(HavenNet.pending.isEmpty())
    }

    @Test fun a_dm_circle_formed_inbound_is_a_live_lane() {
        env.social.lenient = true
        val dm = HavenKeys.dmCircleId(env.me, who)
        HavenNet.contacts.add(Contact(who, "Pat", "beef"))
        hello(payload(c = dm))
        assertTrue(env.social.calls.contains("liveLane $dm true"))
    }

    // ---- relay announce (frame 19) -------------------------------------------------------------------

    private val newRelay = "ee".repeat(32)
    private val announcer = "c5".repeat(32)

    private fun announce(json: String, from: String = announcer, circleId: String = circle) {
        env.social.openBlob = { _, sealed -> OpenedCircleBlobFfi(from, sealed) }
        NetEnv.call("handleRelayNode", Wire.eventPayload(circleId, json.toByteArray()))
    }
    private fun announceJson(node: String = newRelay, extra: String = "") = """{"node":"$node"$extra}"""
    @Suppress("UNCHECKED_CAST")
    private fun relayNodes() = NetEnv.field("relayNodes").get(HavenNet) as MutableMap<String, MutableList<String>>

    @Test fun a_brand_new_relay_is_pooled_for_the_circle_with_its_http_interface() {
        announce(announceJson(extra = ""","urls":["http://relay.example:8080"],"token":"tok","addedAt":1234"""))
        assertEquals(listOf(newRelay), relayNodes()[circle])
        val e = env.entries().getValue(newRelay)
        assertEquals(listOf("http://relay.example:8080"), e.httpUrls)
        assertEquals("tok", e.httpToken)
        assertTrue((NetEnv.field("announcedRelayNodes").get(HavenNet) as Set<*>).contains(newRelay))
    }

    @Test fun a_legacy_bare_hex_announce_is_enough_to_learn_a_relay() {
        announce(newRelay)
        assertEquals(listOf(newRelay), relayNodes()[circle])
    }

    @Test fun the_fabric_roles_a_relay_announces_are_recorded() {
        announce(announceJson(extra = ""","derp":"https://derp.example/","turn":["turn:t.example:3478"],"turnUser":"u","turnPass":"p","urls":["http://relay.example:1"],"token":"t""""))
        val e = env.entries().getValue(newRelay)
        assertEquals("https://derp.example", e.derpUrl)
        assertEquals(listOf("turn:t.example:3478"), e.turnUrls)
        assertEquals("u", e.turnUser); assertEquals("p", e.turnPass)
    }

    @Test fun an_announce_that_moves_a_relays_interface_replaces_it_and_a_stale_echo_does_not_move_it_back() {
        announce(announceJson(extra = ""","urls":["http://old.example:1"],"token":"t1""""))
        announce(announceJson(extra = ""","urls":["http://new.example:2"],"token":"t2""""))
        assertEquals(listOf("http://new.example:2"), env.entries().getValue(newRelay).httpUrls)
        announce(announceJson(extra = ""","urls":["http://old.example:1"],"token":"t1""""))
        assertEquals("a late copy of the old interface is not re-adopted", listOf("http://new.example:2"), env.entries().getValue(newRelay).httpUrls)
    }

    @Test fun an_announce_naming_a_relay_already_in_the_circle_adds_nothing() {
        announce(announceJson())
        announce(announceJson())
        assertEquals(listOf(newRelay), relayNodes()[circle])
    }

    @Test fun garbage_announces_are_ignored() {
        announce("not json at all")
        announce("""{"node":"short"}""")
        announce(announceJson(), circleId = "")
        NetEnv.call("handleRelayNode", byteArrayOf(1))
        NetEnv.call("handleRelayNode", Wire.eventPayload(circle, ByteArray(0)))
        assertNull(relayNodes()[circle])
        assertFalse(env.entries().containsKey(newRelay))
    }

    @Test fun an_announce_the_engine_cannot_open_is_ignored() {
        env.social.openBlob = null
        NetEnv.call("handleRelayNode", Wire.eventPayload(circle, newRelay.toByteArray()))
        assertNull(relayNodes()[circle])
    }

    @Test fun a_relay_i_deleted_does_not_come_back_on_a_third_partys_echo() {
        (NetEnv.field("suppressedRelays").get(HavenNet) as MutableSet<String>).add(newRelay)
        announce(announceJson(extra = ""","addedAt":0"""))
        assertNull("a deleted relay needs a genuinely newer re-add", relayNodes()[circle])
        (NetEnv.field("suppressedRelays").get(HavenNet) as MutableSet<String>).remove(newRelay)
    }

    @Test fun an_inactive_relay_comes_back_only_for_its_owner() {
        env.entries()[newRelay] = HavenNet.RelayEntry(newRelay, "r", false, 0, false)
        announce(announceJson())   // announced by a third party, no newer stamp
        assertFalse(env.entries().getValue(newRelay).active)
        announce(announceJson(), from = newRelay)   // the relay's own account re-announcing it
        assertTrue(env.entries().getValue(newRelay).active)
    }

    @Test fun learning_a_device_relay_retires_a_members_stale_account_id_relay() {
        val staleAccount = "bb".repeat(32)
        env.social.members[circle] = listOf(staleAccount)
        relayNodes().getOrPut(circle) { RelayNodeMap.newList() }.add(staleAccount)
        announce(announceJson())
        assertEquals(listOf(newRelay), relayNodes()[circle])
        assertTrue((NetEnv.field("suppressedRelays").get(HavenNet) as Set<*>).contains(staleAccount))
    }
}
