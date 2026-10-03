package com.blaineam.haven.core

import com.blaineam.haven.core.HeavyWorkPolicy.Conditions
import com.blaineam.haven.core.HeavyWorkPolicy.Heat
import com.blaineam.haven.core.HeavyWorkPolicy.ServeDecision
import com.blaineam.haven.core.HeavyWorkPolicy.ServeRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Relay-first media serving + the call / thermal / Battery Saver heavy-I/O gate — the same table
 * as Apple's HeavyWorkPolicyTests, so both platforms answer alike.
 */
class HeavyWorkPolicyTest {
    private fun friend(onRelay: Boolean = false, pending: Boolean = false, relay: Boolean = true, hints: Int = 0) =
        ServeRequest(isOwnDevice = false, onRelay = onRelay, uploadPending = pending,
            circleHasRelay = relay, hintsAlreadySent = hints)

    private fun own(pending: Boolean = false, handoff: Boolean = false) =
        ServeRequest(isOwnDevice = true, isHandoffTarget = handoff, onRelay = false,
            uploadPending = pending, circleHasRelay = true, hintsAlreadySent = 0)

    @Test fun gate_suspends_for_any_call_power_save_or_severe_heat() {
        assertFalse(Conditions().suspendHeavyIO)
        assertTrue(Conditions(havenCall = true).suspendHeavyIO)
        assertTrue(Conditions(systemCall = true).suspendHeavyIO)
        assertTrue(Conditions(powerSave = true).suspendHeavyIO)
        assertTrue(Conditions(heat = Heat.SERIOUS).suspendHeavyIO)
        assertFalse(Conditions(heat = Heat.FAIR).suspendHeavyIO)
    }

    @Test fun friend_serving_needs_a_cool_idle_device() {
        assertTrue(Conditions().peerServingAllowedForFriends)
        assertFalse(Conditions(heat = Heat.FAIR).peerServingAllowedForFriends)
        assertFalse(Conditions(havenCall = true).peerServingAllowedForFriends)
    }

    /** The reported bug: a friend asks during a call for a blob the relay holds. */
    @Test fun never_stream_during_a_call() {
        val c = Conditions(havenCall = true)
        assertNotEquals(ServeDecision.Stream, HeavyWorkPolicy.decideServe(friend(onRelay = true), c))
        assertNotEquals(ServeDecision.Stream, HeavyWorkPolicy.decideServe(friend(relay = false), c))
        assertNotEquals(ServeDecision.Stream, HeavyWorkPolicy.decideServe(own(), c))
    }

    @Test fun relay_first() {
        assertEquals(ServeDecision.HintRelay, HeavyWorkPolicy.decideServe(friend(onRelay = true), Conditions()))
        assertEquals(ServeDecision.HintWhenUploaded, HeavyWorkPolicy.decideServe(friend(pending = true), Conditions()))
        assertEquals(ServeDecision.Stream, HeavyWorkPolicy.decideServe(friend(relay = false), Conditions()))
        assertTrue(HeavyWorkPolicy.decideServe(friend(relay = false), Conditions(heat = Heat.FAIR)) is ServeDecision.Decline)
    }

    @Test fun hint_budget_falls_back_to_direct_only_when_allowed() {
        val spent = HeavyWorkPolicy.MAX_RELAY_HINTS
        assertEquals(ServeDecision.Stream, HeavyWorkPolicy.decideServe(friend(onRelay = true, hints = spent), Conditions()))
        assertTrue(HeavyWorkPolicy.decideServe(friend(onRelay = true, hints = spent), Conditions(powerSave = true))
            is ServeDecision.Decline)
    }

    @Test fun own_devices_are_served_unless_suspended() {
        assertEquals(ServeDecision.Stream, HeavyWorkPolicy.decideServe(own(), Conditions(heat = Heat.FAIR)))
        assertEquals(ServeDecision.HintWhenUploaded, HeavyWorkPolicy.decideServe(own(pending = true), Conditions()))
        assertEquals(ServeDecision.Stream, HeavyWorkPolicy.decideServe(own(pending = true, handoff = true), Conditions()))
        assertTrue(HeavyWorkPolicy.decideServe(own(), Conditions(heat = Heat.CRITICAL)) is ServeDecision.Decline)
    }

    @Test fun fresh_refs_wait_for_the_relay_and_thumbs_never_do() {
        assertFalse(HeavyWorkPolicy.mayDirectAskAfterRelayMiss(false, true, 30_000L, false, Conditions()))
        assertTrue(HeavyWorkPolicy.mayDirectAskAfterRelayMiss(false, true,
            HeavyWorkPolicy.FRESH_RELAY_PATIENCE_MS + 1, false, Conditions()))
        assertTrue(HeavyWorkPolicy.mayDirectAskAfterRelayMiss(false, false, 1_000L, false, Conditions()))
        assertTrue(HeavyWorkPolicy.mayDirectAskAfterRelayMiss(true, true, 1L, false, Conditions(havenCall = true)))
        assertFalse(HeavyWorkPolicy.mayDirectAskAfterRelayMiss(false, false, null, true, Conditions(systemCall = true)))
    }

    @Test fun own_fresh_uploads_continue_through_a_call() {
        assertTrue(HeavyWorkPolicy.backupAllowed(priority = true, c = Conditions(havenCall = true)))
        assertFalse(HeavyWorkPolicy.backupAllowed(priority = false, c = Conditions(havenCall = true)))
        assertTrue(HeavyWorkPolicy.backupAllowed(priority = false, c = Conditions(heat = Heat.FAIR)))
        assertFalse(HeavyWorkPolicy.backupAllowed(priority = true, c = Conditions(heat = Heat.CRITICAL)))
    }

    /** rc.3 field report: a warm phone kept re-mirroring a recovered history. Mirroring (media this
     *  device is not the only holder of) waits already at FAIR; own backfill and fresh uploads don't. */
    @Test fun mirroring_backfill_stops_when_merely_warm() {
        assertFalse(HeavyWorkPolicy.backupAllowed(priority = false, c = Conditions(heat = Heat.FAIR), mirror = true))
        assertTrue(HeavyWorkPolicy.backupAllowed(priority = false, c = Conditions(heat = Heat.FAIR), mirror = false))
        assertTrue(HeavyWorkPolicy.backupAllowed(priority = true, c = Conditions(heat = Heat.FAIR), mirror = true))
        assertTrue(HeavyWorkPolicy.backupAllowed(priority = false, c = Conditions(), mirror = true))
        assertFalse(Conditions(heat = Heat.FAIR).backgroundMirrorAllowed)
        assertTrue(Conditions().backgroundMirrorAllowed)
    }

    /** The QA attribution of a direct friend serve names its cause (e2e `relayfirst`). */
    @Test fun stream_reason_names_why_no_hint_answered() {
        assertEquals("circle-unresolved", HeavyWorkPolicy.streamReason(friend(onRelay = true, relay = false), circleKnown = false))
        assertEquals("circle-has-no-relay", HeavyWorkPolicy.streamReason(friend(relay = false), circleKnown = true))
        assertEquals("hints-exhausted", HeavyWorkPolicy.streamReason(friend(onRelay = true, hints = HeavyWorkPolicy.MAX_RELAY_HINTS), circleKnown = true))
        assertEquals("not-on-relay-nor-queued", HeavyWorkPolicy.streamReason(friend(), circleKnown = true))
    }

    /** On a satellite link only satellite-safe media leaves, by ANY path. */
    @Test fun ultra_constrained_link_moves_only_satellite_safe_media() {
        assertTrue(HeavyWorkPolicy.mayMoveOverLink(ultraConstrained = false, satelliteSafe = false))
        assertTrue(HeavyWorkPolicy.mayMoveOverLink(ultraConstrained = true, satelliteSafe = true))
        assertFalse(HeavyWorkPolicy.mayMoveOverLink(ultraConstrained = true, satelliteSafe = false))
    }
}
