package com.blaineam.haven.core

/**
 * QA driver ops that must run on CallManager's dedicated CALL thread ("haven-call"). QaDriver applies
 * commands on its own "haven-qa" executor, but CallManager is single-thread state: WebRTC callbacks
 * post to the call thread and every public entry point hops there. A `call_end` applied on the QA
 * thread tore peers down concurrently with ICE callbacks closing the same peers — a double
 * `PeerConnection.dispose()` and a native crash. (It used to be MAIN; see CallManager.callThread for
 * why main no longer owns call state.)
 */
object QaOpThreads {
    val CALL_THREAD_OPS: Set<String> = setOf(
        "call", "call_accept", "call_end", "call_speaker", "call_route_legacy",
    )
    fun needsCallThread(op: String): Boolean = op.trim().lowercase() in CALL_THREAD_OPS
}
