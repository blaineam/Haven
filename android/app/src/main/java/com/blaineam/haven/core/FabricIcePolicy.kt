package com.blaineam.haven.core

/**
 * Haven-first WebRTC ICE policy (shared by [CallManager] and unit tests).
 *
 * THE RULE: a public STUN server is a LAST RESORT, reached for only when no Haven relay is
 * available to carry the call for the parties involved. Google learns the IP of every peer it
 * serves during ICE, so it is used when the alternative is a call that cannot connect at all —
 * and not otherwise.
 *
 * | Fabric | TURN                | ICE                                                    |
 * |--------|---------------------|--------------------------------------------------------|
 * | no     | none / private only | Google STUN (nothing else can pair two home NATs)      |
 * | no     | public              | circle TURN + STUN on the same host                    |
 * | yes    | any (incl. none)    | circle TURN/STUN if present — never Google             |
 *
 * A fabric counts as an available relay even with no TURN of its own, because the relay's path
 * proxy serves the WebRTC hairpin ([CallHairpin] + [CallMediaBridge]): media has a route that
 * never touches a third party. That hairpin is opened alongside ICE and takes over on FAILED.
 *
 * ⚠️ THE DOCUMENTED RISK, because this rule re-opens a real field failure. Google was originally
 * added as an unconditional companion after a relay advertised a Docker-internal
 * `turn:172.20.0.2:3478`, leaving both phones with one dead server, no STUN and host candidates
 * only — calls that "connected" carrying zero media. The no-fabric half of that case is still
 * covered (an unreachable private TURN with no fabric is not an available relay, so the fallback
 * still applies, pinned by `noFabric_privateTurnStillFallsBack`). What changes is that a circle
 * with a working fabric no longer discloses its callers' IPs to Google merely because the relay
 * has no TURN — it leans on the hairpin, which did not exist when that fallback was written.
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
        val haveFabric = derp.isNotEmpty()
        val havenRelayAvailable = haveFabric || havePublicTurn

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
