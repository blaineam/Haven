package com.blaineam.haven.core

import org.webrtc.PeerConnection

/**
 * The verdict of the grace check a call schedules when a peer's link goes quiet
 * (ICE `DISCONNECTED`): six seconds later, is that peer really gone?
 *
 * Kept as a pure decision so a unit test can hold it. The check may drop the peer only when BOTH
 * are true at the moment it fires:
 *
 *  - it is still looking at the connection it was scheduled for. A call that ended and a new call
 *    to the same person started inside the grace has a peer under the same name — a different
 *    connection, which this check has no business touching;
 *  - the link is still `DISCONNECTED`. One that recovered (`CONNECTED` / `COMPLETED`) is a blip,
 *    not a departure; one that went on to `FAILED` is the hairpin relay's to rescue; `CLOSED` has
 *    already been dropped by its own handler.
 *
 * Apple parity: CallManager.swift gates the same timer on `lastPeerState[peer] == .disconnected`.
 */
object DisconnectGrace {
    const val GRACE_MS = 6_000L

    fun stillDown(sameConnection: Boolean, ice: PeerConnection.IceConnectionState?): Boolean =
        sameConnection && ice == PeerConnection.IceConnectionState.DISCONNECTED
}
