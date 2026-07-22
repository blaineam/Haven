package com.blaineam.haven.core

/**
 * Haven-first WebRTC ICE policy (shared by [CallManager] and unit tests).
 *
 * When a circle fabric (DERP) is known, Google STUN is **not** a first path —
 * only circle TURN or host candidates (+ path-proxy WebSocket hairpin for media).
 * n0 / Google remain fallbacks only when no fabric is configured.
 */
object FabricIcePolicy {
    data class Result(
        val turnUrls: List<String>,
        val turnUser: String,
        val turnPass: String,
        val useGoogleStun: Boolean,
        val hostOnly: Boolean,
    )

    fun resolve(
        derp: Set<String>,
        turn: Set<String>,
        user: String,
        pass: String,
    ): Result {
        val turnList = turn.filter { it.startsWith("turn:") || it.startsWith("turns:") }
        if (turnList.isNotEmpty() && user.isNotEmpty() && pass.isNotEmpty()) {
            return Result(
                turnUrls = turnList,
                turnUser = user,
                turnPass = pass,
                useGoogleStun = false,
                hostOnly = false,
            )
        }
        if (derp.isNotEmpty() || turn.isNotEmpty()) {
            return Result(
                turnUrls = emptyList(),
                turnUser = "",
                turnPass = "",
                useGoogleStun = false,
                hostOnly = true,
            )
        }
        return Result(
            turnUrls = emptyList(),
            turnUser = "",
            turnPass = "",
            useGoogleStun = true,
            hostOnly = false,
        )
    }

    val googleStunUrls: List<String> = listOf(
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
    )
}
