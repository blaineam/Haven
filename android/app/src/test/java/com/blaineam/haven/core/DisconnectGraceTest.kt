package com.blaineam.haven.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.webrtc.PeerConnection.IceConnectionState

class DisconnectGraceTest {
    @Test fun aLinkStillDownAfterTheGraceIsDropped() =
        assertTrue(DisconnectGrace.stillDown(sameConnection = true, ice = IceConnectionState.DISCONNECTED))

    /** A blip that healed inside the grace must not end the call six seconds later. */
    @Test fun aLinkThatRecoveredIsKept() {
        assertFalse(DisconnectGrace.stillDown(true, IceConnectionState.CONNECTED))
        assertFalse(DisconnectGrace.stillDown(true, IceConnectionState.COMPLETED))
        assertFalse(DisconnectGrace.stillDown(true, IceConnectionState.CHECKING))
    }

    /** FAILED belongs to the hairpin relay; CLOSED was dropped by its own handler; unknown is not evidence. */
    @Test fun otherStatesAreNotThisChecksToDrop() {
        assertFalse(DisconnectGrace.stillDown(true, IceConnectionState.FAILED))
        assertFalse(DisconnectGrace.stillDown(true, IceConnectionState.CLOSED))
        assertFalse(DisconnectGrace.stillDown(true, null))
    }

    /** A check left over from an ended call must not hang up the next call with the same person. */
    @Test fun aCheckFromAnEarlierCallNeverTouchesTheNextOne() {
        for (s in IceConnectionState.values()) assertFalse(DisconnectGrace.stillDown(sameConnection = false, ice = s))
        assertFalse(DisconnectGrace.stillDown(sameConnection = false, ice = null))
    }
}
