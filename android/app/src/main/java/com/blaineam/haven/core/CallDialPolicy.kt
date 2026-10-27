package com.blaineam.haven.core

/**
 * Which outbound call frames re-open a peer's iroh dial backoff first.
 *
 * Mobile dial backoff runs 2 → 4 → 8 → 16 → 30 min after failed connects. A call is the one moment the
 * user has just told us "this person, now": an INVITE (or the callee's ACCEPT) that has to wait out a
 * strike count built up while the peer was offline or on an unreachable network makes the call ring
 * minutes late ("the call finally came through, it had to catch up"). The forgiveness is per peer
 * and only for call SETUP frames — signaling that follows (ICE, SDP, hangup) never re-arms a dial,
 * so a peer that genuinely is unreachable still goes straight back to its cooldown after one probe.
 * iOS `FeedStore.forgiveDials` on call setup parity.
 */
object CallDialPolicy {
    /** Frame 21 / 22: the group-call invite and its join, sent by the iOS and desktop builds. */
    private const val GROUP_INVITE = 21
    private const val GROUP_JOIN = 22

    fun forgivesBackoff(type: Int): Boolean =
        type == Wire.CALL_INVITE || type == Wire.CALL_ACCEPT || type == GROUP_INVITE || type == GROUP_JOIN
}
