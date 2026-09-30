package com.blaineam.haven.core

/**
 * QA driver ops that must run on the MAIN thread. QaDriver applies commands on its own "haven-qa"
 * executor, but CallManager is main-thread state: WebRTC callbacks post to main, the UI calls it on
 * main. A `call_end` applied on the QA thread tore peers down concurrently with main-thread ICE
 * callbacks closing the same peers — a double `PeerConnection.dispose()` and a native crash.
 */
object QaOpThreads {
    val MAIN_THREAD_OPS: Set<String> = setOf(
        "call", "call_accept", "call_end", "call_speaker", "call_route_legacy",
    )
    fun needsMain(op: String): Boolean = op.trim().lowercase() in MAIN_THREAD_OPS
}
