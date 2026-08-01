package com.blaineam.haven.core

/**
 * Haven-first WebRTC ICE policy (shared by [CallManager] and unit tests).
 *
 * THE RULE: a public STUN server is a LAST RESORT, reached for only when no Haven relay is
 * available to carry the call for the parties involved. Google learns the IP of every peer it
 * serves during ICE, so it is used when the alternative is a call that cannot connect at all —
 * and not otherwise.
 *
 * | TURN                | ICE                                                              |
 * |---------------------|------------------------------------------------------------------|
 * | none / private only | circle TURN if any + public STUN (nothing else pairs two NATs)   |
 * | public              | circle TURN + STUN on the same host — never Google                |
 *
 * ⚠️ A FABRIC IS NOT PROOF MEDIA HAS A ROUTE, and this rule has been wrong in both directions.
 * It briefly treated a configured fabric as an available relay — no Google even with no usable TURN
 * — on the reasoning that the relay's path proxy serves the WebRTC hairpin. That shipped, and a real
 * call to a real person came up CONNECTED WITH NO AUDIO: host candidates alone cannot pair two NATs,
 * and the hairpin taking over is likely rather than guaranteed (it did take over for a different
 * peer in the same session, so it works — it is just not a guarantee you can bet a call on).
 *
 * That is the same failure the Google fallback was originally added for, after a relay advertised a
 * Docker-internal `turn:172.20.0.2:3478` and left both phones with one dead server and no STUN.
 * Narrowing this again needs PROOF the hairpin has established, not the assumption that it will.
 *
 * This object returns the FINAL server plan that [CallManager] hands to WebRTC — it is not
 * advisory. It used to return a `hostOnly` flag that the caller deliberately ignored, so the unit
 * tests pinned a decision nothing shipped; the caller now translates this plan and nothing more,
 * which is what makes [FabricIcePolicyTest] worth reading.
 */
object FabricIcePolicy {
    /**
     * The exact ICE server set for a call: circle TURN (with credentials), STUN derived from the
     * circle's own TURN host, and [google] — populated only as the last resort described above.
     */
    data class Plan(
        val turnUrls: List<String>,
        val turnUser: String,
        val turnPass: String,
        val stunUrls: List<String>,
        val google: List<String>,
    ) {
        /** True when this plan reaches outside Haven for connectivity. */
        val usesGoogleStun: Boolean get() = google.isNotEmpty()
    }

    fun plan(
        derp: Set<String>,
        turn: Set<String>,
        user: String,
        pass: String,
    ): Plan {
        val turnList = turn.filter { it.startsWith("turn:") || it.startsWith("turns:") }
        val usable = turnList.isNotEmpty() && user.isNotEmpty() && pass.isNotEmpty()

        // The circle TURN host doubles as a STUN server (same socket, no credentials) — so
        // server-reflexive candidates come from the circle's own infrastructure.
        val stun = if (usable) {
            turnList.mapNotNull { url -> url.substringAfter(":", "").ifEmpty { null }?.let { "stun:$it" } }
        } else {
            emptyList()
        }
        val havePublicTurn = usable && turnList.any { !hostLooksPrivate(it) }
        // REVERTED (see Apple HavenFabric): a fabric alone is not proof media has a route. A real
        // call showed CONNECTED WITH NO AUDIO under the narrower rule — host candidates only cannot
        // pair two NATs, and the hairpin taking over is likely, not guaranteed. Public STUN is the
        // fallback again whenever no PUBLICLY REACHABLE TURN exists.
        val havenRelayAvailable = havePublicTurn

        return Plan(
            turnUrls = if (usable) turnList else emptyList(),
            turnUser = if (usable) user else "",
            turnPass = if (usable) pass else "",
            stunUrls = stun,
            google = if (havenRelayAvailable) emptyList() else googleStunUrls,
        )
    }

    /** Best-effort "is this turn:/stun: URL's host a private/unroutable address" check. */
    fun hostLooksPrivate(url: String): Boolean {
        val host = url.substringAfter(":", "").substringBefore(":")
        val second = host.split(".").getOrNull(1)?.toIntOrNull() ?: -1
        return host.startsWith("10.") || host.startsWith("192.168.") || host.startsWith("127.") ||
            host.startsWith("169.254.") || (host.startsWith("172.") && second in 16..31)
    }

    val googleStunUrls: List<String> = listOf(
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
    )
}
