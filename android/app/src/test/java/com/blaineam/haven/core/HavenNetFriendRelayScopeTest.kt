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

    /** e2e `… A private photo on R_C`: R_C is a standalone relay B operates — its node id is no contact's —
     *  learned for the shared circle. A device that learned the private circle with an EMPTY relay list used
     *  to guess "every active relay", read the circle's mailbox at R_C, and the transport self-enrolled it. */
    @Test fun a_circle_with_no_relays_is_not_guessed_onto_a_relay_learned_for_a_wider_circle() {
        val rc = "c5".repeat(32)
        env.entries()[rc] = HavenNet.RelayEntry(rc, "R_C", true, 0, false, httpUrls = listOf(env.relay.base), httpToken = env.token)
        env.bindCircleRelay("cS", rc)          // announced for the circle we share with B
        @Suppress("UNCHECKED_CAST")
        fun fb(c: String) = NetEnv.call("circleFallbackRelays", c) as List<String>
        assertEquals("private circle, no relays of its own: nothing to guess", emptyList<String>(), fb("cA"))
        assertEquals("a circle whose members all share cS may use cS's relays", listOf(rc), fb("dm:b"))
        assertFalse(runBlocking { HavenNet.uploadEvent("cA", "g".toByteArray()) })
        assertTrue("nothing left for either relay", env.relay.hits.isEmpty())
    }

    /** The e2e `multirelay: A's private post on A's other devices` hole: the circle's record carried no list
     *  and the only relay this device could use was learned AFTER the post. The post had uploaded nowhere and
     *  nothing re-sent it. Learning the relay must backfill the circle — without widening who may hold it. */
    @Test fun a_keyless_circle_is_backfilled_when_a_relay_it_may_use_is_learned_after_the_post() {
        env.social.circleList = env.social.circleList + CircleInfoFfi("cK", "Synced", 1u)
        env.social.members["cK"] = emptyList()
        env.social.envelopes["cK"] = listOf("evt".toByteArray())
        NetEnv.call("rescopeKeylessCircles")   // seeds the watch: nothing known yet
        assertFalse("posted before any relay was usable", runBlocking { HavenNet.uploadEvent("cK", "evt".toByteArray()) })
        assertTrue(env.relay.hits.isEmpty())
        env.addRelay("c4".repeat(32), env.relay.base)   // a relay nobody here knows as a contact's becomes known
        NetEnv.call("rescopeKeylessCircles")
        assertTrue("the stranded event was re-sent to the relay learned later", env.relay.hits.isNotEmpty())
    }

    @Test fun a_keyless_circle_is_not_backfilled_onto_a_relay_only_a_wider_circle_may_use() {
        val rc = "c5".repeat(32)
        val rcRelay = FakeRelayServer().start()
        env.entries()[rc] = HavenNet.RelayEntry(rc, "R_C", true, 0, false, httpUrls = listOf(rcRelay.base), httpToken = env.token)
        env.social.circleList = env.social.circleList.filter { it.id != "dm:b" }   // dm:b legitimately may use rc
        env.social.envelopes["cA"] = listOf("evt".toByteArray())
        NetEnv.call("rescopeKeylessCircles")   // seed
        env.bindCircleRelay("cS", rc)           // announced for the circle shared with B
        HavenNet.relaysForCircle("cS")
        NetEnv.call("rescopeKeylessCircles")
        val onRc = rcRelay.hits.map { it.path }
        rcRelay.stop()
        assertTrue("A's private circle never lands on the relay serving B's circle: $onRc", onRc.none { "cA" in it })
    }

    @Test fun the_watch_flags_only_keyless_circles_that_gain_a_relay() {
        val w = KeylessScopeWatch()
        fun s(k: Boolean, vararg r: String) = KeylessScopeWatch.Scope(k, r.toSet())
        assertEquals("the first look only seeds", emptyList<String>(), w.gained(mapOf("c" to s(true))))
        assertEquals(emptyList<String>(), w.gained(mapOf("c" to s(true))))
        assertEquals(listOf("c"), w.gained(mapOf("c" to s(true, "r1"))))
        assertEquals("unchanged afterwards", emptyList<String>(), w.gained(mapOf("c" to s(true, "r1"))))
        assertEquals("a record landing with its list is a gain too", listOf("c2"),
            KeylessScopeWatch().also { it.gained(mapOf("c2" to s(true))) }.gained(mapOf("c2" to s(false, "r1"))))
        assertEquals("a keyed circle gaining a relay was handled by its setter", emptyList<String>(),
            KeylessScopeWatch().also { it.gained(mapOf("c3" to s(false, "r1"))) }.gained(mapOf("c3" to s(false, "r1", "r2"))))
        assertEquals("a circle first seen after the seed", listOf("new"),
            KeylessScopeWatch().also { it.gained(emptyMap()) }.gained(mapOf("new" to s(true, "r1"))))
    }

    @Test fun the_rule_is_pure() {
        val friends = setOf(b, bDevice)
        assertFalse(RelayScope.verdict(bDevice, emptySet(), friends))
        assertTrue(RelayScope.verdict(bDevice, setOf(b, bDevice), friends))
        assertTrue(RelayScope.verdict("c4".repeat(32), emptySet(), friends))
        val m = mapOf("cS" to setOf("b"), "cA" to emptySet<String>(), "dm" to setOf("b"))
        val lists = mapOf("cS" to listOf("rc"), "cA" to listOf("ra"))
        assertEquals(emptyList<String>(), RelayScope.fallback("cA", m, lists - "cA"))
        assertEquals(listOf("rc", "ra"), RelayScope.fallback("dm", m, lists))
        assertEquals("a relay of a me-only circle exposes nothing to a wider one", listOf("ra"), RelayScope.fallback("cS", m, lists))
        assertTrue(mine.isNotEmpty())
    }
}
