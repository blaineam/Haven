package com.blaineam.haven.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Documents Haven-first ICE policy for Android (mirrors [CallManager] private iceServers):
 * - No fabric → Google STUN allowed (fallback).
 * - Fabric without TURN → no Google (host + hairpin).
 * - Fabric + TURN → circle TURN only.
 *
 * CallManager.iceServers() is private; this locks the policy table so a regression
 * that re-introduces Google under fabric is caught when CallManager is next refactored
 * to share [FabricIcePolicy].
 */
class FabricIcePolicyTest {

    @Test
    fun noFabric_allowsGoogleStun() {
        val ice = FabricIcePolicy.resolve(
            derp = emptySet(),
            turn = emptySet(),
            user = "",
            pass = "",
        )
        assertTrue(ice.useGoogleStun)
        assertTrue(ice.turnUrls.isEmpty())
    }

    @Test
    fun fabricWithoutTurn_noGoogle() {
        val ice = FabricIcePolicy.resolve(
            derp = setOf("https://relay.example.com"),
            turn = emptySet(),
            user = "",
            pass = "",
        )
        assertFalse(ice.useGoogleStun)
        assertTrue(ice.turnUrls.isEmpty())
        assertTrue(ice.hostOnly)
    }

    @Test
    fun fabricWithTurn_circleOnly() {
        val ice = FabricIcePolicy.resolve(
            derp = setOf("https://relay.example.com"),
            turn = setOf("turn:10.0.0.1:3478"),
            user = "haven",
            pass = "secret",
        )
        assertFalse(ice.useGoogleStun)
        assertFalse(ice.hostOnly)
        assertTrue(ice.turnUrls.contains("turn:10.0.0.1:3478"))
    }
}
