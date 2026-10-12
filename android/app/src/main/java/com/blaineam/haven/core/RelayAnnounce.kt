package com.blaineam.haven.core

import org.json.JSONObject

/**
 * A relay announce (wire frame 19), parsed, plus the rule that decides whether it may bring back a
 * relay the user deactivated or deleted. Pure: lifted out of `HavenNet.handleRelayNode` so the
 * resurrection rules — the "deleted relays came back when mom opened the app" class of bug — can be
 * tested without an engine.
 */
internal data class RelayAnnounce(
    val nodeHex: String,
    val urls: List<String>,
    val token: String,
    /** When the announcer adopted the relay (unix ms); 0 = a legacy announce that carries none. */
    val addedAt: Long,
    val derp: String?,
    val turn: List<String>,
    val turnUser: String,
    val turnPass: String,
) {
    enum class Decision { DROP, REACTIVATE, KEEP }

    companion object {
        private fun isTurn(u: String) = u.startsWith("turn:") || u.startsWith("turns:")

        /** Plain text = a bare node hex (legacy). `{…}` = the extended JSON announce. Null when the
         *  text isn't a usable announce (bad JSON, or the node id isn't 64 hex chars long). */
        fun parse(rawText: String): RelayAnnounce? {
            val text = rawText.trim()
            if (!text.startsWith("{")) {
                val hex = text.lowercase()
                return if (hex.length == 64) RelayAnnounce(hex, emptyList(), "", 0L, null, emptyList(), "", "") else null
            }
            val o = runCatching { JSONObject(text) }.getOrNull() ?: return null
            val urls = o.optJSONArray("urls")?.let { a ->
                (0 until a.length()).mapNotNull { i -> a.optString(i).takeIf { u -> u.startsWith("http") } }
            } ?: emptyList()
            val token = o.optString("token", "")
            val d = o.optString("derp", "").trim()
            val turn = o.optJSONArray("turn")?.let { a ->
                (0 until a.length()).mapNotNull { i -> a.optString(i).takeIf { u -> isTurn(u) } }
            } ?: o.optString("turn", "").takeIf { isTurn(it) }?.let { listOf(it) } ?: emptyList()
            var turnUser = o.optString("turnUser", "")
            var turnPass = o.optString("turnPass", "")
            if (turnUser.isEmpty() && turn.isNotEmpty()) turnUser = "haven"
            if (turnPass.isEmpty() && turn.isNotEmpty() && token.isNotEmpty()) turnPass = token
            val hex = o.optString("node", "").trim().lowercase()
            if (hex.length != 64) return null
            return RelayAnnounce(hex, urls, token, o.optLong("addedAt", 0L),
                if (d.startsWith("http")) d.trimEnd('/') else null, turn, turnUser, turnPass)
        }

        /**
         * May this announce revive the relay?
         *  • User DELETED it ([suppressed]): only a genuine re-add whose adoption stamp is NEWER than
         *    the deletion — never the owner merely reopening the app (which re-announces the older
         *    original adoption time), and never a legacy announce (addedAt = 0).
         *  • Merely INACTIVE: the relay's OWNER (the announced id is the announcer's account or one of
         *    their devices) or a newer re-add may bring it back; a third-party echo may not.
         *  • Otherwise nothing to decide (already active, or brand new).
         */
        fun reactivation(
            suppressed: Boolean, active: Boolean, announcedAddedAt: Long, forgottenAt: Long,
            nodeHex: String, announcerHex: String, announcerDeviceHexes: List<String>,
        ): Decision = when {
            suppressed -> if (announcedAddedAt <= forgottenAt) Decision.DROP else Decision.REACTIVATE
            !active -> {
                val owns = nodeHex == announcerHex || nodeHex in announcerDeviceHexes
                val newer = announcedAddedAt > 0 && announcedAddedAt > forgottenAt
                if (!owns && !newer) Decision.DROP else Decision.REACTIVATE
            }
            else -> Decision.KEEP
        }
    }
}
