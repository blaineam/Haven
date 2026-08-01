package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the Haven-first ICE table — public STUN is a LAST RESORT, used only when no Haven relay is
 * available to carry the call:
 *
 * | Fabric | TURN                | ICE                                               |
 * |--------|---------------------|---------------------------------------------------|
 * | no     | none / private only | Google STUN (nothing else can pair two home NATs) |
 * | no     | public              | circle TURN + STUN on the same host               |
 * | yes    | any (incl. none)    | circle TURN/STUN if present — never Google        |
 *
 * These assert the plan `CallManager.iceServers()` actually hands to WebRTC. The previous version
 * of this file tested a `hostOnly` flag the caller openly ignored — it carried a warning saying so
 * — which meant a green run here proved nothing about the device. Parity with Apple's
 * HavenFabricTests.
 */
class FabricIcePolicyTest {

    @Test
    fun noFabric_noTurn_fallsBackToGoogle() {
        val plan = FabricIcePolicy.plan(derp = emptySet(), turn = emptySet(), user = "", pass = "")
        assertTrue("nothing else can pair two home NATs", plan.usesGoogleStun)
        assertTrue(plan.turnUrls.isEmpty())
    }

    /**
     * The documented field failure: a relay advertising a Docker-internal TURN host left both
     * phones with one dead server and no STUN — calls that "connected" carrying no media. With no
     * fabric there is no hairpin to fall back to, so this last resort must survive.
     */
    @Test
    fun noFabric_privateTurnStillFallsBack() {
        val plan = FabricIcePolicy.plan(
            derp = emptySet(),
            turn = setOf("turn:172.20.0.2:3478"),
            user = "haven",
            pass = "secret",
        )
        assertTrue("an unreachable private TURN is not an available relay", plan.usesGoogleStun)
    }

    @Test
    fun noFabric_publicTurn_staysOnCircleInfra() {
        val plan = FabricIcePolicy.plan(
            derp = emptySet(),
            turn = setOf("turn:relay.example.com:3478"),
            user = "haven",
            pass = "secret",
        )
        assertFalse(plan.usesGoogleStun)
        assertEquals(listOf("stun:relay.example.com:3478"), plan.stunUrls)
    }

    /** The rule the whole change exists for: a healthy fabric never reaches for Google. */
    @Test
    fun fabricWithoutTurn_neverGoogle() {
        val plan = FabricIcePolicy.plan(
            derp = setOf("https://relay.example.com"),
            turn = emptySet(),
            user = "",
            pass = "",
        )
        assertFalse("the relay's hairpin carries media; no third party needed", plan.usesGoogleStun)
        assertTrue(plan.turnUrls.isEmpty())
    }

    /** A fabric counts as an available relay even when its TURN is unroutable. */
    @Test
    fun fabricWithPrivateTurn_neverGoogle() {
        val plan = FabricIcePolicy.plan(
            derp = setOf("https://relay.example.com"),
            turn = setOf("turn:10.0.0.1:3478"),
            user = "haven",
            pass = "secret",
        )
        assertFalse(plan.usesGoogleStun)
        assertTrue(plan.turnUrls.contains("turn:10.0.0.1:3478"))
        assertEquals(listOf("stun:10.0.0.1:3478"), plan.stunUrls)
    }

    /** Credentials are load-bearing: TURN without them is not usable, so it cannot count as a relay. */
    @Test
    fun turnWithoutCredentials_isNotARelay() {
        val plan = FabricIcePolicy.plan(
            derp = emptySet(),
            turn = setOf("turn:relay.example.com:3478"),
            user = "",
            pass = "",
        )
        assertTrue(plan.turnUrls.isEmpty())
        assertTrue(plan.usesGoogleStun)
    }

    @Test
    fun privateHostDetection() {
        assertTrue(FabricIcePolicy.hostLooksPrivate("turn:172.20.0.2:3478"))
        assertTrue(FabricIcePolicy.hostLooksPrivate("turn:192.168.1.5:3478"))
        assertTrue(FabricIcePolicy.hostLooksPrivate("turn:10.0.0.1:3478"))
        assertFalse(FabricIcePolicy.hostLooksPrivate("turn:172.15.0.1:3478"))
        assertFalse(FabricIcePolicy.hostLooksPrivate("turn:relay.example.com:3478"))
    }
}
