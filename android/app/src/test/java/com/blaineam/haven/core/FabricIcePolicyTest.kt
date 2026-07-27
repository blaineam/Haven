package com.blaineam.haven.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Documents the Haven-first ICE policy TABLE:
 * - No fabric → Google STUN allowed (fallback).
 * - Fabric without TURN → `hostOnly` (host candidates + the [CallMediaBridge] hairpin for media).
 * - Fabric + TURN → circle TURN only.
 *
 * ⚠️ `hostOnly` here is ADVISORY. `CallManager.iceServers()` deliberately does not honour it and
 * adds STUN anyway — host-candidates-only cannot complete a call between two NATs, which is what
 * the field report about a relay advertising a Docker-internal TURN host turned out to be. This
 * test pins the POLICY OBJECT, not the caller's behaviour; don't read a passing run here as proof
 * that Android goes host-only in that case, because it does not.
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
