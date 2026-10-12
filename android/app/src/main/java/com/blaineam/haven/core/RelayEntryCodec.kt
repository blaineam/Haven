package com.blaineam.haven.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * The persisted shape of one configured relay ([HavenNet.RelayEntry]) — the JSON that lives in the
 * `relayEntries` pref. Split out of `HavenNet.loadRelayNodes` / `saveRelayNodes` so a field added to
 * [HavenNet.RelayEntry] and forgotten here (a relay that silently loses its DERP/TURN/HTTP config on
 * every restart) is a failing test, not a field report.
 */
internal object RelayEntryCodec {
    fun shortName(hex: String): String =
        if (hex.startsWith("s3:")) "S3 · " + hex.removePrefix("s3:").take(16)
        else "Relay · " + hex.take(8) + "…"

    /** Optional fields are OMITTED when empty so the stored blob stays small and diff-stable. */
    fun encode(e: HavenNet.RelayEntry): JSONObject = JSONObject().apply {
        put("hex", e.hex); put("name", e.name); put("active", e.active)
        put("lastSeenMs", e.lastSeenMs); put("isS3", e.isS3)
        if (e.httpUrls.isNotEmpty()) put("httpUrls", JSONArray(e.httpUrls))
        if (e.httpToken.isNotEmpty()) put("httpToken", e.httpToken)
        if (e.addedAtMs > 0) put("addedAtMs", e.addedAtMs)
        if (e.derpUrl.isNotEmpty()) put("derpUrl", e.derpUrl)
        if (e.turnUrls.isNotEmpty()) put("turnUrls", JSONArray(e.turnUrls))
        if (e.turnUser.isNotEmpty()) put("turnUser", e.turnUser)
        if (e.turnPass.isNotEmpty()) put("turnPass", e.turnPass)
    }

    /** Throws when `hex` is missing (the caller skips the whole table on a corrupt record). Absent
     *  fields take their defaults; [nowMs] stands in for a missing last-seen stamp. */
    fun decode(o: JSONObject, nowMs: Long): HavenNet.RelayEntry {
        val hex = o.getString("hex")
        return HavenNet.RelayEntry(
            hex = hex,
            name = o.optString("name", shortName(hex)),
            active = o.optBoolean("active", true),
            lastSeenMs = o.optLong("lastSeenMs", nowMs),
            isS3 = o.optBoolean("isS3", hex.startsWith("s3:")),
            httpUrls = strings(o.optJSONArray("httpUrls")) { it.isNotEmpty() },
            httpToken = o.optString("httpToken", ""),
            addedAtMs = o.optLong("addedAtMs", 0L),
            derpUrl = o.optString("derpUrl", "").trim().trimEnd('/'),
            turnUrls = strings(o.optJSONArray("turnUrls")) { it.startsWith("turn:") || it.startsWith("turns:") },
            turnUser = o.optString("turnUser", ""),
            turnPass = o.optString("turnPass", ""),
        )
    }

    private fun strings(a: JSONArray?, keep: (String) -> Boolean): List<String> =
        if (a == null) emptyList() else (0 until a.length()).mapNotNull { a.optString(it).takeIf(keep) }
}
