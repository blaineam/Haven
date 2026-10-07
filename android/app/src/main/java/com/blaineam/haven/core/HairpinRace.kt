package com.blaineam.haven.core

import org.webrtc.PeerConnection

/**
 * When the hairpin relay should race WebRTC's direct path for a peer — Apple parity with
 * `CallManager.createPeer`'s `directMediaGraceSecs` (CallManager.swift).
 *
 * Android used to relay ONLY on ICE `FAILED`. That state takes ~15-30 s to arrive, and with
 * continual gathering it may never arrive at all (seen 2026-10-07: an Android → Mac call sat in
 * `CHECKING` for the whole call). Meanwhile the Mac had already raced onto the relay after 1.5 s
 * and was sending its media there, so the call was one-way: the Mac relayed, Android never
 * listened or sent — a relayed screen share decoded zero frames on the far end.
 *
 * Now: the direct path gets [GRACE_MS] of head start, then the relay comes up alongside it, and
 * `CONNECTED` tears the relay back down (onPeerIceStateOnCall). The check repeats every [GRACE_MS]
 * until the call is accepted, ICE wins, the relay is up, or the peer is gone — never relaying an
 * unanswered call (the early-media poison startHairpin also refuses).
 */
object HairpinRace {
    const val GRACE_MS = 1_500L
    /** Re-checks before giving up on an unanswered peer (~3 min, the invite's max age). */
    const val MAX_CHECKS = 120

    enum class Verdict { RELAY, WAIT, DONE }

    fun decide(
        peerAlive: Boolean,
        relaying: Boolean,
        ice: PeerConnection.IceConnectionState?,
        ringing: Boolean,
        inCall: Boolean,
    ): Verdict = when {
        !peerAlive || relaying -> Verdict.DONE
        ice == PeerConnection.IceConnectionState.CONNECTED ||
            ice == PeerConnection.IceConnectionState.COMPLETED -> Verdict.DONE   // direct path won
        ringing || !inCall -> Verdict.WAIT                                       // not answered yet
        else -> Verdict.RELAY
    }
}
