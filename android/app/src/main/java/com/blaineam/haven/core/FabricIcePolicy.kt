package com.blaineam.haven.core

/**
 * Haven-first WebRTC ICE policy (shared by [CallManager] and unit tests).
 *
 * When a circle fabric (DERP) is known, Google STUN is **not** a first path —
 * only circle TURN or host candidates. n0 / Google remain fallbacks only when no
 * fabric is configured.
 *
 * ⚠️ THIS OBJECT'S `hostOnly` RESULT IS ADVISORY — [CallManager.iceServers] deliberately does not
 * honour it, and adds STUN anyway. Host-candidates-only cannot complete a call between two NATs,
 * which is what the field report about a relay advertising a Docker-internal TURN host turned out
 * to be. Do not "restore" the strict reading without also giving Android a media path that works
 * when ICE fails.
 *
 * ⚠️ AND ANDROID HAS NO SUCH PATH. This comment used to promise a "path-proxy WebSocket hairpin
 * for media" as the thing that makes host-only viable. That hairpin exists on Apple
 * (`CallHairpin` + `CallMediaBridge`) and on desktop; on Android it has never been written — the
 * promise was the comment. So when ICE cannot establish, an Android leg has no fallback at all:
 * the call rings, is accepted, and then sits in "connecting" forever. Anything that narrows
 * Android's ICE candidates makes that outcome MORE likely, not less.
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
