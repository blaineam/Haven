package com.blaineam.haven.core

import com.blaineam.haven.core.RelayAnnounce.Decision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Relay announce parsing and the "may this bring a deleted/inactive relay back?" rule. */
class RelayAnnounceTest {
    private val node = "ab".repeat(32)
    private val other = "cd".repeat(32)

    @Test fun legacy_plain_text_announce_is_a_bare_node_id() {
        val a = RelayAnnounce.parse("  ${node.uppercase()} ")!!
        assertEquals(node, a.nodeHex)
        assertEquals(0L, a.addedAt)
        assertEquals(emptyList<String>(), a.urls)
        assertNull(a.derp)
    }

    @Test fun plain_text_with_the_wrong_length_is_rejected() {
        assertNull(RelayAnnounce.parse("abc")); assertNull(RelayAnnounce.parse("")); assertNull(RelayAnnounce.parse(node + "00"))
    }

    @Test fun json_announce_carries_interface_fabric_and_adoption_time() {
        val a = RelayAnnounce.parse("""{"node":" ${node.uppercase()} ","urls":["https://r.example","ftp://bad","http://10.0.0.2:8080"],
            "token":"tok","addedAt":1700000000123,"derp":" https://derp.example/ ","turn":["turn:t.example:3478","stun:x","turns:t.example:5349"],
            "turnUser":"u","turnPass":"p"}""")!!
        assertEquals(node, a.nodeHex)
        assertEquals(listOf("https://r.example", "http://10.0.0.2:8080"), a.urls)
        assertEquals("tok", a.token)
        assertEquals(1700000000123L, a.addedAt)
        assertEquals("https://derp.example", a.derp)
        assertEquals(listOf("turn:t.example:3478", "turns:t.example:5349"), a.turn)
        assertEquals("u", a.turnUser); assertEquals("p", a.turnPass)
    }

    @Test fun a_non_http_derp_is_ignored() {
        assertNull(RelayAnnounce.parse("""{"node":"$node","derp":"derp.example"}""")!!.derp)
    }

    @Test fun a_single_string_turn_url_is_accepted_and_credentials_default_sensibly() {
        val a = RelayAnnounce.parse("""{"node":"$node","turn":"turn:t.example:3478","token":"shared"}""")!!
        assertEquals(listOf("turn:t.example:3478"), a.turn)
        assertEquals("haven", a.turnUser)
        assertEquals("the relay token stands in for a missing TURN password", "shared", a.turnPass)
        val bare = RelayAnnounce.parse("""{"node":"$node","turn":"turn:t.example:3478"}""")!!
        assertEquals("", bare.turnPass)
        val none = RelayAnnounce.parse("""{"node":"$node","token":"shared"}""")!!
        assertEquals("", none.turnUser); assertEquals("", none.turnPass)
    }

    @Test fun broken_or_incomplete_json_is_rejected() {
        assertNull(RelayAnnounce.parse("{not json"))
        assertNull(RelayAnnounce.parse("""{"urls":["https://x"]}"""))
        assertNull(RelayAnnounce.parse("""{"node":"short"}"""))
        assertNotNull(RelayAnnounce.parse("""{"node":"$node"}"""))
    }

    private fun decide(suppressed: Boolean, active: Boolean, added: Long, forgotten: Long, announcer: String = other,
                       devices: List<String> = emptyList()) =
        RelayAnnounce.reactivation(suppressed, active, added, forgotten, node, announcer, devices)

    @Test fun a_deleted_relay_returns_only_for_a_strictly_newer_readd() {
        assertEquals(Decision.REACTIVATE, decide(true, false, added = 200, forgotten = 100))
        assertEquals("same stamp = a stale echo", Decision.DROP, decide(true, false, added = 100, forgotten = 100))
        assertEquals(Decision.DROP, decide(true, false, added = 50, forgotten = 100))
        assertEquals("legacy announce carries no time", Decision.DROP, decide(true, false, added = 0, forgotten = 0))
    }

    @Test fun even_the_relays_owner_cannot_revive_a_deleted_relay_with_its_old_stamp() {
        assertEquals(Decision.DROP, decide(true, false, added = 10, forgotten = 100, announcer = node))
    }

    @Test fun an_inactive_relay_comes_back_for_its_owner_account_or_device() {
        assertEquals(Decision.REACTIVATE, decide(false, false, added = 0, forgotten = 0, announcer = node))
        assertEquals(Decision.REACTIVATE, decide(false, false, added = 0, forgotten = 0, devices = listOf(node)))
    }

    @Test fun an_inactive_relay_ignores_a_third_party_echo_unless_it_is_a_newer_readd() {
        assertEquals(Decision.DROP, decide(false, false, added = 0, forgotten = 0))
        assertEquals(Decision.DROP, decide(false, false, added = 50, forgotten = 100))
        assertEquals(Decision.REACTIVATE, decide(false, false, added = 150, forgotten = 100))
    }

    @Test fun an_active_or_new_relay_needs_no_decision() {
        assertEquals(Decision.KEEP, decide(false, true, added = 0, forgotten = 0))
    }
}
