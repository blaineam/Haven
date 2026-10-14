package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The relay "fabric" roles (a custom DERP front door and TURN servers a relay announces) as the rest of the app sees them:
 * which ones are written to the ICE policy's preferences, and when a front door we have watched fail stops counting, so a
 * rotated free-tunnel hostname cannot pin rendezvous to a dead host.
 */
@Suppress("UNCHECKED_CAST")
class HavenNetFabricTest {
    private val env = NetEnv()
    private val relay = "9a".repeat(32)
    private val derp = "https://derp.example"

    @Before fun setUp() {
        env.up(withRelay = false)
        env.entries()[relay] = HavenNet.RelayEntry(relay, "r", true, 0, false, derpUrl = derp,
            turnUrls = listOf("turn:t.example:3478"), turnUser = "u", turnPass = "p")
    }
    @After fun tearDown() { env.down() }

    private val prefs get() = env.ctx.prefs("haven.fabric")
    private fun active() = NetEnv.call("activeFabricUrls") as List<String>

    @Test fun an_active_relays_derp_and_turn_roles_are_written_for_the_ice_policy() {
        NetEnv.call("refreshHavenFabric")
        assertEquals(setOf(derp), prefs.getStringSet("derpUrls", null))
        assertEquals(setOf("turn:t.example:3478"), prefs.getStringSet("turnUrls", null))
        assertEquals("u", prefs.getString("turnUser", null)); assertEquals("p", prefs.getString("turnPass", null))
    }

    @Test fun a_deactivated_relay_contributes_nothing() {
        env.entries()[relay] = env.entries().getValue(relay).copy(active = false)
        NetEnv.call("refreshHavenFabric")
        assertTrue(prefs.getStringSet("derpUrls", null)!!.isEmpty())
        assertTrue(prefs.getStringSet("turnUrls", null)!!.isEmpty())
        assertEquals("", prefs.getString("turnUser", null))
    }

    @Test fun a_front_door_we_watched_fail_is_stood_down_until_it_answers_again() {
        assertEquals(listOf(derp), active())
        NetEnv.call("noteFabricBaseDead", "$derp/")
        assertTrue("the fabric falls back to n0 rather than staying pinned to a dead host", active().isEmpty())
        assertTrue(prefs.getStringSet("derpUrls", null)!!.isEmpty())
        HavenNet.noteFabricBaseAlive("$derp/")
        assertEquals(listOf(derp), active())
    }

    @Test fun a_base_sitting_in_the_http_bad_window_is_not_trusted_either() {
        (NetEnv.field("httpUrlBad").get(HavenNet) as MutableMap<String, Long>)[derp] = System.currentTimeMillis() + 60_000
        assertTrue(active().isEmpty())
        (NetEnv.field("httpUrlBad").get(HavenNet) as MutableMap<String, Long>).clear()
        assertEquals(listOf(derp), active())
    }

    @Test fun a_blank_url_is_never_marked_dead_and_a_dead_mark_is_logged_once_per_window() {
        NetEnv.call("noteFabricBaseDead", "/")
        assertFalse((NetEnv.field("derpDeadUntilMs").get(HavenNet) as Map<*, *>).containsKey(""))
        NetEnv.call("noteFabricBaseDead", derp)
        NetEnv.call("noteFabricBaseDead", derp)
        assertEquals(1, (NetEnv.field("derpDeadUntilMs").get(HavenNet) as Map<*, *>).size)
    }
}
