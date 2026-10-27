package com.blaineam.haven.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallDialPolicyTest {
    @Test fun callSetupFramesForgiveTheDialBackoff() {
        assertTrue(CallDialPolicy.forgivesBackoff(Wire.CALL_INVITE))
        assertTrue(CallDialPolicy.forgivesBackoff(Wire.CALL_ACCEPT))
        assertTrue(CallDialPolicy.forgivesBackoff(21))   // group invite
        assertTrue(CallDialPolicy.forgivesBackoff(22))   // group join
    }

    @Test fun signalingAfterSetupNeverReArmsADial() {
        // ICE/SDP arrive in dozens per call and the sealed media frames share this send path: none of
        // them may keep forgiving a peer that genuinely is unreachable.
        for (t in listOf(Wire.CALL_HANGUP, Wire.CALL_AUDIO, Wire.CALL_VIDEO, Wire.SDP_OFFER, Wire.SDP_ANSWER,
            Wire.ICE, Wire.MEDIA_WANTED, Wire.MEDIA_AVAILABLE, Wire.MEDIA_RESUME_REQ)) {
            assertFalse("type $t", CallDialPolicy.forgivesBackoff(t))
        }
    }
}
