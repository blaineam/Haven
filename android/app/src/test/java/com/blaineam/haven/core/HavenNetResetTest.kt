package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * Starting over must hand the next identity a clean device: nothing of the previous account's contacts, relays, read
 * marks, seen-sets or engine state may survive. Plus the handshakes this device initiated, which persist until answered.
 */
class HavenNetResetTest {
    private val env = NetEnv()
    private val friend = "f1".repeat(32)

    @Before fun setUp() { env.up() }
    @After fun tearDown() { env.down() }

    @Suppress("UNCHECKED_CAST") private fun initiated() = NetEnv.field("initiated").get(HavenNet) as MutableMap<String, String>
    @Suppress("UNCHECKED_CAST") private fun initiatedAt() = NetEnv.field("initiatedAt").get(HavenNet) as MutableMap<String, Long>

    @Test fun a_reset_wipes_contacts_relays_seen_keys_prefs_and_the_engine_state_file() {
        HavenNet.contacts.add(Contact(friend, "Pat", "v"))
        HavenNet.blocked.add("e5".repeat(32))
        env.seen().let { (it as MutableSet<String>).add("haven/mailbox/default/abc") }
        env.bindCircleRelay("default")
        val stateFile = File(env.ctx.filesDir, "haven_social_state_${env.me}.bin").apply { writeBytes(byteArrayOf(1)) }
        val seenFile = File(env.ctx.filesDir, "haven_mailbox_seen.txt").apply { writeText("x") }
        env.ctx.prefs("haven.contacts").data["contacts"] = "[{}]"
        env.ctx.prefs("haven.notified").data["notifiedIds"] = "x"
        HavenNet.activeCircle.value = "c1other"
        val version = HavenNet.feedVersion.value
        HavenNet.reset()
        assertTrue(HavenNet.contacts.isEmpty() && HavenNet.blocked.isEmpty() && HavenNet.pending.isEmpty())
        assertTrue(env.seen().isEmpty())
        assertTrue(env.entries().isEmpty())
        assertNull(HavenNet.defaultRelay())
        assertFalse(stateFile.exists()); assertFalse(seenFile.exists())
        assertTrue(env.ctx.prefs("haven.contacts").data.isEmpty())
        assertTrue(env.ctx.prefs("haven.notified").data.isEmpty())
        assertEquals(DEFAULT_CIRCLE, HavenNet.activeCircle.value)
        assertTrue("and the feed recomposes", HavenNet.feedVersion.value > version)
        assertFalse(HavenNet.hasRelay())
    }

    @Test fun handshakes_this_device_started_survive_a_restart_with_their_start_time() {
        initiated()[friend] = "beef"; initiatedAt()[friend] = 1234L
        NetEnv.call("saveInitiated")
        initiated().clear(); initiatedAt().clear()
        NetEnv.call("loadInitiated")
        assertEquals("beef", initiated()[friend])
        assertEquals(1234L, initiatedAt()[friend])
    }

    @Test fun forgetting_a_handshake_removes_both_halves_and_persists() {
        initiated()[friend] = "beef"; initiatedAt()[friend] = 1L
        NetEnv.call("forgetInitiated", friend)
        assertTrue(initiated().isEmpty() && initiatedAt().isEmpty())
        initiated().clear()
        NetEnv.call("loadInitiated")
        assertTrue("the removal was saved", initiated().isEmpty())
        NetEnv.call("forgetInitiated", friend)   // already gone: no-op
    }
}
