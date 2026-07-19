package com.blaineam.haven.core

/**
 * The Haven wire protocol — a byte-exact Kotlin port of the framing in the iOS FeedStore
 * (apple/HavenApp/FeedView.swift, "MARK: - Wire protocol"). This MUST stay identical to iOS
 * or Android ↔ iPhone interop breaks, so it lives in its own pure-Kotlin file with unit tests.
 *
 *   Frame        = [type:u8][payload]
 *   Hello payload= [LP circleId][LP circleName][LP bundle][signed profile]
 *   Event payload= [LP circleId][sealed envelope]
 *   LP field     = [u16 LE len][bytes]
 *
 * Frame types (parity with iOS handleInbound):
 *   0 Hello · 1 Event · 3 MediaReq · 5 MediaChunk · 9 Relay · 10-13 audio call ·
 *   14 BucketConfig · 15 video · 16 SDP offer · 17 SDP answer · 18 ICE · 19 relay node · 20 presign ·
 *   31 media-wanted · 32 media-available · 33 media-resume-req
 */
object Wire {
    const val HELLO: Int = 0
    const val EVENT: Int = 1
    const val MEDIA_REQ: Int = 3
    const val MEDIA_CHUNK: Int = 5
    const val RELAY: Int = 9
    const val RELAY_NODE: Int = 19   // circle relay/mailbox node id share
    const val PRESIGN: Int = 20      // S3 pre-signed URL pool bootstrap
    const val DEVICE_ENROLL: Int = 24 // a device asks its primary to authorize it (multi-device, iOS-compat)
    const val DEVICE_GRANT: Int = 25  // the primary returns a signed credential to the requesting device
    const val DEVICE_ROSTER: Int = 27 // a friend's signed device roster (device-id transport auth/dial), iOS-compat
    const val SEEDLESS_ENROLL_REQ: Int = 28  // a NEW seedless device proves ticket possession to its primary (S4)
    const val SEEDLESS_ENROLL_GRANT: Int = 29 // the primary grants credential + roster + self-sync key (S4)
    const val CALL_INVITE: Int = 10
    const val CALL_ACCEPT: Int = 11
    const val CALL_HANGUP: Int = 12
    const val CALL_AUDIO: Int = 13
    const val CALL_VIDEO: Int = 15
    const val SDP_OFFER: Int = 16
    const val SDP_ANSWER: Int = 17
    const val ICE: Int = 18

    /** 31 — "put this media back": a reader asks a post's AUTHOR to re-upload a blob a relay swept.
     *  32 — "it's back": the author's reply once the re-upload lands.
     *  Both: `[hex64 sender][LP ref][LP circleId][LP postId]`.
     *
     *  These ride the SEALED+SIGNED call-frame path, not the plain one: 31 asks someone to spend
     *  their upload bandwidth and 32 raises a notification and triggers a fetch, so neither may be
     *  forgeable. See HavenNet.onInbound and CallManager.sealedSend. */
    const val MEDIA_WANTED: Int = 31
    const val MEDIA_AVAILABLE: Int = 32

    /** 33 — a RESUME re-request: "send me this media, but only the chunks I'm missing".
     *  `[hex64 requester][u16 LE refLen][ref][u32 LE total][bitmap]` — see [MediaResume].
     *
     *  Frame 3 is deliberately left byte-for-byte alone for a FIRST request: its ref is the unlengthed
     *  remainder, so there is nowhere to put a bitmap without breaking every parser in the field, and a
     *  first request has no bitmap to send anyway. 33 is the RE-request that carries one.
     *
     *  Rides the PLAIN blocked-sender path with frame 3 rather than the sealed call-frame path (31/32):
     *  it asks for a strict SUBSET of what frame 3 already asks for in the clear, so sealing it would
     *  buy nothing while making it fail exactly where its own frame-3 fallback still works. */
    const val MEDIA_RESUME_REQ: Int = 33

    /** Prepend the one-byte frame type. */
    fun frame(type: Int, payload: ByteArray): ByteArray =
        ByteArray(1 + payload.size).also {
            it[0] = type.toByte()
            payload.copyInto(it, 1)
        }

    /** Append a length-prefixed field ([u16 LE len][bytes]) to a buffer. */
    fun lpAppend(out: MutableList<Byte>, field: ByteArray) {
        require(field.size <= 0xFFFF) { "LP field too large: ${field.size}" }
        val n = field.size
        out.add((n and 0xFF).toByte())
        out.add(((n ushr 8) and 0xFF).toByte())
        field.forEach { out.add(it) }
    }

    /** A cursor for reading LP fields out of a payload. */
    class Reader(private val data: ByteArray, var off: Int = 0) {
        /** Read one LP field, or null if the buffer is short (matches iOS lpRead). */
        fun lp(): ByteArray? {
            if (data.size < off + 2) return null
            val n = (data[off].toInt() and 0xFF) or ((data[off + 1].toInt() and 0xFF) shl 8)
            off += 2
            if (data.size < off + n) return null
            val field = data.copyOfRange(off, off + n)
            off += n
            return field
        }

        /** The remaining bytes after the cursor (e.g. the sealed envelope / signed profile). */
        fun rest(): ByteArray = data.copyOfRange(off, data.size)
    }

    /** Hello payload = [LP circleId][LP circleName][LP bundle][signed profile]. */
    fun helloPayload(circleId: String, circleName: String, bundle: ByteArray, signedProfile: ByteArray): ByteArray {
        val out = ArrayList<Byte>(circleId.length + circleName.length + bundle.size + signedProfile.size + 8)
        lpAppend(out, circleId.toByteArray(Charsets.UTF_8))
        lpAppend(out, circleName.toByteArray(Charsets.UTF_8))
        lpAppend(out, bundle)
        signedProfile.forEach { out.add(it) }
        return out.toByteArray()
    }

    data class Hello(val circleId: String, val circleName: String, val bundle: ByteArray, val signedProfile: ByteArray)

    /** Parse a Hello payload; null if malformed (matches iOS handleHello guards). */
    fun parseHello(payload: ByteArray): Hello? {
        val r = Reader(payload)
        val cid = r.lp() ?: return null
        val cname = r.lp() ?: return null
        val bundle = r.lp() ?: return null
        if (bundle.size < 32) return null
        return Hello(
            circleId = String(cid, Charsets.UTF_8),
            circleName = String(cname, Charsets.UTF_8),
            bundle = bundle,
            signedProfile = r.rest(),
        )
    }

    /** Event payload = [LP circleId][sealed envelope]. */
    fun eventPayload(circleId: String, envelope: ByteArray): ByteArray {
        val out = ArrayList<Byte>(circleId.length + envelope.size + 2)
        lpAppend(out, circleId.toByteArray(Charsets.UTF_8))
        envelope.forEach { out.add(it) }
        return out.toByteArray()
    }

    data class EventFrame(val circleId: String, val envelope: ByteArray)

    fun parseEvent(payload: ByteArray): EventFrame? {
        val r = Reader(payload)
        val cid = r.lp() ?: return null
        return EventFrame(String(cid, Charsets.UTF_8), r.rest())
    }
}
