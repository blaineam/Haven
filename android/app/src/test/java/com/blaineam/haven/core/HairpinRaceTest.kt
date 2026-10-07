package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Test
import org.webrtc.PeerConnection.IceConnectionState

class HairpinRaceTest {
    private fun d(alive: Boolean = true, relaying: Boolean = false, ice: IceConnectionState? = IceConnectionState.CHECKING,
                  ringing: Boolean = false, inCall: Boolean = true) =
        HairpinRace.decide(alive, relaying, ice, ringing, inCall)

    @Test fun checkingAfterGraceRelays() = assertEquals(HairpinRace.Verdict.RELAY, d())

    @Test fun neverReportedStateRelays() = assertEquals(HairpinRace.Verdict.RELAY, d(ice = null))

    @Test fun directWinStops() {
        assertEquals(HairpinRace.Verdict.DONE, d(ice = IceConnectionState.CONNECTED))
        assertEquals(HairpinRace.Verdict.DONE, d(ice = IceConnectionState.COMPLETED))
    }

    @Test fun unansweredCallWaits() {
        assertEquals(HairpinRace.Verdict.WAIT, d(ringing = true))
        assertEquals(HairpinRace.Verdict.WAIT, d(inCall = false))
    }

    @Test fun goneOrAlreadyRelayingStops() {
        assertEquals(HairpinRace.Verdict.DONE, d(alive = false))
        assertEquals(HairpinRace.Verdict.DONE, d(relaying = true))
    }
}
