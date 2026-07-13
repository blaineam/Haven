package com.blaineam.haven.core

/**
 * Byte-exact Kotlin port of the iOS CallManager signaling frames (apple/HavenApp/CallManager.swift).
 * Mesh group calls: a session id + roster; every participant opens one WebRTC connection to every
 * other (no SFU); the lexicographically smaller hex is the offerer (glare-free).
 *
 * All call frames lead with the sender's 64-char node-id hex, so HavenNet can drop blocked senders.
 *
 *   21 group-invite : [hex64][lp sessionId][lp groupName][lp rosterCSV][lp sentAtSecs?]
 *   11 accept       : [hex64][lp sessionId]
 *   12 hangup       : [hex64]
 *   16/17/18 signal : [hex64][lp sessionId][json]      (offer / answer / ice; SDP or candidate JSON)
 *   10 legacy invite: [hex64][name utf8]
 */
object CallWire {
    const val INVITE = 10
    const val ACCEPT = 11
    const val HANGUP = 12
    const val OFFER = 16
    const val ANSWER = 17
    const val ICE = 18
    const val GROUP_INVITE = 21
    const val CAMERA = 22   // [hex64][lp sessionId][on byte] — peer camera on/off (avoid frozen frame)

    private fun hexHead(payload: ByteArray): String? {
        if (payload.size < 64) return null
        val from = String(payload.copyOfRange(0, 64), Charsets.UTF_8)
        return if (from.length == 64) from else null
    }

    // ---- builders ----

    /** The 4th LP field is the send time (unix seconds, decimal) so receivers can refuse to ring
     *  for a stale relay-replayed copy; every platform's parser tolerates trailing fields, so
     *  older receivers are unaffected. */
    fun groupInvite(
        myHex: String,
        sessionId: String,
        groupName: String,
        rosterCsv: String,
        sentAtSecs: Long = System.currentTimeMillis() / 1000,
    ): ByteArray {
        val out = ArrayList<Byte>()
        myHex.toByteArray(Charsets.UTF_8).forEach { out.add(it) }
        Wire.lpAppend(out, sessionId.toByteArray(Charsets.UTF_8))
        Wire.lpAppend(out, groupName.toByteArray(Charsets.UTF_8))
        Wire.lpAppend(out, rosterCsv.toByteArray(Charsets.UTF_8))
        Wire.lpAppend(out, sentAtSecs.toString().toByteArray(Charsets.UTF_8))
        return out.toByteArray()
    }

    fun accept(myHex: String, sessionId: String): ByteArray {
        val out = ArrayList<Byte>()
        myHex.toByteArray(Charsets.UTF_8).forEach { out.add(it) }
        Wire.lpAppend(out, sessionId.toByteArray(Charsets.UTF_8))
        return out.toByteArray()
    }

    fun hangup(myHex: String): ByteArray = myHex.toByteArray(Charsets.UTF_8)

    /** Frame 22: tell peers my camera is on/off so they show my avatar instead of a frozen last frame. */
    fun cameraState(myHex: String, sessionId: String, on: Boolean): ByteArray {
        val out = ArrayList<Byte>()
        myHex.toByteArray(Charsets.UTF_8).forEach { out.add(it) }
        Wire.lpAppend(out, sessionId.toByteArray(Charsets.UTF_8))
        out.add(if (on) 1 else 0)
        return out.toByteArray()
    }

    /** (from, cameraOn). iOS reads only the leading hex + trailing flag byte, so we match that. */
    fun parseCameraState(payload: ByteArray): Pair<String, Boolean>? {
        val from = hexHead(payload) ?: return null
        val on = payload.isNotEmpty() && payload.last() == 1.toByte()
        return from to on
    }

    /** offer/answer/ice body: [hex64][lp sessionId][json]. */
    fun signal(myHex: String, sessionId: String, json: ByteArray): ByteArray {
        val out = ArrayList<Byte>()
        myHex.toByteArray(Charsets.UTF_8).forEach { out.add(it) }
        Wire.lpAppend(out, sessionId.toByteArray(Charsets.UTF_8))
        json.forEach { out.add(it) }
        return out.toByteArray()
    }

    // ---- parsers ----

    /** [sentAt] is null when the sender predates the timestamp field. */
    data class GroupInvite(val from: String, val sessionId: String, val groupName: String, val roster: List<String>, val sentAt: Long? = null)

    fun parseGroupInvite(payload: ByteArray): GroupInvite? {
        val from = hexHead(payload) ?: return null
        val r = Wire.Reader(payload, 64)
        val sid = r.lp()?.let { String(it, Charsets.UTF_8) } ?: return null
        val gname = r.lp()?.let { String(it, Charsets.UTF_8) } ?: return null
        val rosterStr = r.lp()?.let { String(it, Charsets.UTF_8) } ?: return null
        if (sid.isEmpty()) return null
        val roster = rosterStr.split(",").map { it.trim() }.filter { it.length == 64 }
        val sentAt = r.lp()?.let { String(it, Charsets.UTF_8).toLongOrNull() }
        return GroupInvite(from, sid, gname.ifEmpty { "Group call" }, roster, sentAt)
    }

    data class Accept(val from: String, val sessionId: String)

    fun parseAccept(payload: ByteArray): Accept? {
        val from = hexHead(payload) ?: return null
        val r = Wire.Reader(payload, 64)
        val sid = r.lp()?.let { String(it, Charsets.UTF_8) } ?: ""
        return Accept(from, sid)
    }

    fun parseHangup(payload: ByteArray): String? = hexHead(payload)

    fun parseInviteName(payload: ByteArray): Pair<String, String>? {
        val from = hexHead(payload) ?: return null
        val name = if (payload.size > 64) String(payload.copyOfRange(64, payload.size), Charsets.UTF_8) else "Someone"
        return from to name
    }

    data class Signal(val from: String, val sessionId: String, val json: ByteArray)

    /**
     * Decode `[hex64][lp sessionId?][json]`. The session id is optional (legacy 1:1 frames omit it).
     * JSON always starts with '{', which disambiguates the legacy framing — matching iOS parseSignal.
     */
    fun parseSignal(payload: ByteArray, fallbackSession: String): Signal? {
        val from = hexHead(payload) ?: return null
        val body = payload.copyOfRange(64, payload.size)
        if (body.isEmpty()) return null
        val r = Wire.Reader(body, 0)
        val sidBytes = r.lp()
        if (sidBytes != null) {
            val sid = String(sidBytes, Charsets.UTF_8)
            if (sid.isNotEmpty() && r.off < body.size && body[r.off] == '{'.code.toByte()) {
                return Signal(from, sid, body.copyOfRange(r.off, body.size))
            }
        }
        // Legacy: body is raw JSON; infer the session.
        return Signal(from, fallbackSession, body)
    }
}

/**
 * SDP / ICE JSON, byte-compatible with the iOS CallSignal enum so an Android phone and an iPhone
 * can negotiate a call:
 *   SDP       : { "t": "offer"|"answer", "sdp": "<sdp>" }
 *   candidate : { "c": "<candidate>", "m": <sdpMLineIndex>, "i": "<sdpMid>"? }
 */
object CallSignal {
    fun encodeSdp(type: String, sdp: String): ByteArray =
        org.json.JSONObject().put("t", type).put("sdp", sdp).toString().toByteArray(Charsets.UTF_8)

    data class Sdp(val type: String, val sdp: String)

    fun decodeSdp(json: ByteArray): Sdp? = runCatching {
        val o = org.json.JSONObject(String(json, Charsets.UTF_8))
        Sdp(o.getString("t"), o.getString("sdp"))
    }.getOrNull()

    fun encodeCandidate(candidate: String, mLineIndex: Int, mid: String?): ByteArray {
        val o = org.json.JSONObject().put("c", candidate).put("m", mLineIndex)
        if (mid != null) o.put("i", mid)
        return o.toString().toByteArray(Charsets.UTF_8)
    }

    data class Candidate(val candidate: String, val mLineIndex: Int, val mid: String?)

    fun decodeCandidate(json: ByteArray): Candidate? = runCatching {
        val o = org.json.JSONObject(String(json, Charsets.UTF_8))
        Candidate(o.getString("c"), o.getInt("m"), if (o.has("i")) o.getString("i") else null)
    }.getOrNull()
}
