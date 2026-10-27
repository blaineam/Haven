package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi

/**
 * e2e `multirelay: no private circle's media on a friend's relay that doesn't serve it` (A's private photo
 * on B's relay). The fleet's default relay was B's; A's new PRIVATE circle inherited it, so a device
 * enrolled the circle on B's relay, uploaded to it, and exported it as an explicit relay of the circle to
 * every sibling. The default must never carry a circle onto a friend's relay the friend isn't a member of.
 */
class HavenNetFriendRelayScopeTest {
    private val b = "b2".repeat(32)          // friend B's account id
    private val bDevice = "b3".repeat(32)    // B's device — what B's in-app relay is announced as
    private val env = NetEnv(relayHex = "b3".repeat(32))
    private val mine = "a1".repeat(32)

    @Before fun setUp() {
        env.up()   // the relay under test is the all-circles DEFAULT, and it is B's device
        env.social.circleList = listOf(CircleInfoFfi("cA", "Private", 1u), CircleInfoFfi("cS", "Shared", 2u),
            CircleInfoFfi("dm:b", "B", 2u))
        env.social.members["cS"] = listOf(b)   // the shared circle
        env.social.members["cA"] = emptyList() // A's private circle
        env.social.members["dm:b"] = listOf(b) // a DM with B
        env.social.deviceIds[b] = listOf(bDevice)
        HavenNet.relaysForCircle("cA")   // warm: nothing
    }
    @After fun tearDown() { env.down() }

    @Test fun a_friends_relay_set_as_default_is_not_inherited_by_a_circle_the_friend_is_not_in() {
        assertEquals("private circle: no relay", emptyList<String>(), HavenNet.relaysForCircle("cA"))
        assertEquals("the shared circle keeps it", listOf(bDevice), HavenNet.relaysForCircle("cS"))
        assertEquals("a DM with the friend keeps it", listOf(bDevice), HavenNet.relaysForCircle("dm:b"))
    }

    @Test fun a_private_circles_events_never_reach_the_friends_relay() {
        assertFalse(runBlocking { HavenNet.uploadEvent("cA", "e".toByteArray()) })
        assertTrue("nothing was sent to the friend's relay", env.relay.hits.isEmpty())
        assertTrue(runBlocking { HavenNet.uploadEvent("cS", "f".toByteArray()) })
        assertTrue("the shared circle still lands there", env.relay.hits.isNotEmpty())
    }

    @Test fun a_relay_nobody_here_knows_as_a_contacts_is_inherited_by_every_circle() {
        val own = "c4".repeat(32)
        env.addRelay(own, env.relay.base)   // my own / hosted / cloud relay becomes the default
        assertEquals(listOf(own), HavenNet.relaysForCircle("cA"))
        assertEquals(listOf(own), HavenNet.relaysForCircle("cS"))
    }

    @Test fun ticking_the_friends_relay_for_a_circle_explicitly_is_the_users_choice() {
        env.bindCircleRelay("cA", bDevice)
        assertEquals(listOf(bDevice), HavenNet.relaysForCircle("cA"))
    }

    @Test fun a_circle_created_after_the_snapshot_is_judged_on_its_own_members() {
        HavenNet.relaysForCircle("cS")                  // snapshot taken: cA, cS, dm:b
        env.social.members["cNew"] = emptyList()        // a private circle created a moment later
        assertEquals(emptyList<String>(), HavenNet.relaysForCircle("cNew"))
        env.social.members["cNew2"] = listOf(b)
        assertEquals(listOf(bDevice), HavenNet.relaysForCircle("cNew2"))
    }

    @Test fun the_rule_is_pure() {
        val friends = setOf(b, bDevice)
        assertFalse(RelayScope.verdict(bDevice, emptySet(), friends))
        assertTrue(RelayScope.verdict(bDevice, setOf(b, bDevice), friends))
        assertTrue(RelayScope.verdict("c4".repeat(32), emptySet(), friends))
        assertTrue(mine.isNotEmpty())
    }
}
