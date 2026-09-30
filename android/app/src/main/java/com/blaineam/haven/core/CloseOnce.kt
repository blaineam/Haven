package com.blaineam.haven.core

import java.util.concurrent.atomic.AtomicBoolean

/**
 * Runs a release action at most once, whichever thread asks first.
 *
 * `PeerConnection.dispose()` on an already-disposed connection is a native CHECK failure — SIGILL,
 * the whole process gone, not an exception `runCatching` can catch. A hangup's teardown and the ICE
 * CLOSED callback it provokes (`onPeerIceStateOnMain → dropPeer`) could both close the same peer —
 * e2e sshare-4: `call_end` → teardown on the QA thread, dispose on main → SIGILL in
 * libjingle_peerconnection, and the caller sat in a dead call for 100 s.
 */
class CloseOnce {
    private val done = AtomicBoolean(false)
    val isClosed: Boolean get() = done.get()
    /** Runs [action] if nobody has yet; returns whether this call ran it. */
    fun close(action: () -> Unit): Boolean {
        if (!done.compareAndSet(false, true)) return false
        action()
        return true
    }
}
