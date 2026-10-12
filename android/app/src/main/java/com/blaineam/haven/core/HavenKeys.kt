package com.blaineam.haven.core

import org.json.JSONObject
import java.security.MessageDigest

/**
 * Pure key / id / framing helpers lifted out of the [HavenNet] god object so they can be tested
 * without an engine. Every format here is shared byte-for-byte with iOS/macOS and desktop — a
 * change that is not mirrored there silently strands data — so each is pinned by [HavenKeysTest].
 */
internal object HavenKeys {
    // ---- Relay mailbox / media store keys ----------------------------------------------------

    private fun sha256Hex(b: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    /** Content-addressed mailbox slot for a sealed event. */
    fun mailboxKey(circleId: String, env: ByteArray): String = "haven/mailbox/$circleId/${sha256Hex(env)}"

    /** `haven/mailbox/<circle>/__hello__/<toAcct>/<fromAcct>/<sha256>` — the layout the receiving
     *  poll claims. Content-addressed over the hello body so re-offers dedupe. */
    fun helloMailboxKey(circleId: String, toHex: String, fromHex: String, body: ByteArray): String =
        "haven/mailbox/$circleId/__hello__/${toHex.lowercase()}/${fromHex.lowercase()}/${sha256Hex(body)}"

    /** Control-plane keys rank first — they unlock everything else (iOS pullMailbox parity). */
    fun mailboxKeyRank(key: String): Int = when {
        key.contains("/__hello__/") -> 0
        key.contains("/__relay__/") -> 1
        else -> 2
    }

    fun mediaKey(ref: String) = "haven/media/$ref"
    // Chunks live in a SIBLING dir "<ref>.p/", never under the manifest key (a disk relay would need
    // "<ref>" to be both a manifest FILE and a chunk DIRECTORY).
    fun mediaChunkKey(ref: String, i: Int) = "haven/media/$ref.p/$i"
    fun mediaScopeKey(ref: String, circleId: String) = "haven/media/$ref.c/$circleId"

    // ---- Chunk manifest ----------------------------------------------------------------------

    // 9-byte ASCII magic marking a manifest. A sealed envelope is JSON starting with '{', so no collision.
    val manifestMagic: ByteArray = "HVCHUNK1\n".toByteArray(Charsets.US_ASCII)

    fun makeManifest(sizes: List<Int>): ByteArray {
        val json = JSONObject()
            .put("v", 1).put("chunks", sizes.size).put("total", sizes.sum())
            .put("sizes", org.json.JSONArray(sizes))
        return manifestMagic + json.toString().toByteArray(Charsets.UTF_8)
    }

    /** If [blob] is a chunk manifest, its chunk count; else null (a legacy/small single blob). */
    fun parseManifest(blob: ByteArray): Int? {
        if (blob.size <= manifestMagic.size) return null
        for (i in manifestMagic.indices) if (blob[i] != manifestMagic[i]) return null
        return runCatching {
            val body = String(blob, manifestMagic.size, blob.size - manifestMagic.size, Charsets.UTF_8)
            JSONObject(body).getInt("chunks").takeIf { it > 0 }
        }.getOrNull()
    }

    /** Identifies WHICH seal a manifest describes (same chunk count, different seal = different blob). */
    fun manifestFingerprint(head: ByteArray): String = sha256Hex(head).take(16)

    // ---- DM circle ids -----------------------------------------------------------------------

    /** Deterministic 1:1 DM circle id — identical on both sides (full sorted node ids). */
    fun dmCircleId(myHex: String, otherHex: String): String {
        val pair = listOf(myHex, otherHex).sorted()
        return "dm:${pair[0]}-${pair[1]}"
    }

    /** Deterministic GROUP-DM circle id: sorted, de-duplicated, lower-cased ids of everyone. */
    fun groupDmCircleId(myHex: String, otherHexes: List<String>): String {
        val all = (otherHexes + myHex).map { it.lowercase() }.distinct().sorted()
        return "dm:" + all.joinToString("-")
    }

    /** The member node ids encoded in a `dm:` circle id (includes me). */
    fun dmMemberHexes(circleId: String): List<String> =
        circleId.removePrefix("dm:").split("-").filter { it.length == 64 }

    /** A sender may speak in a DM circle only if it is one of the members encoded in the id. */
    fun dmAllows(circleId: String, nodeHex: String): Boolean {
        val parts = circleId.removePrefix("dm:").split("-")
        return parts.size >= 2 && parts.contains(nodeHex)
    }

    // ---- Friend-invite links -----------------------------------------------------------------

    /** Append `t=<ticket>` to an invite link: after any `?d=` hints, before the `#` fragment. */
    fun embedInviteTicket(link: String, ticket: String): String {
        val hash = link.indexOf('#').let { if (it < 0) link.length else it }
        val sep = if (link.substring(0, hash).contains('?')) "&" else "?"
        return link.substring(0, hash) + sep + "t=" + ticket + link.substring(hash)
    }

    /** The `t=` ticket from an invite link's query, or null. */
    fun extractInviteTicket(link: String): String? {
        val q = link.indexOf('?').takeIf { it >= 0 } ?: return null
        val end = link.indexOf('#').let { if (it < 0) link.length else it }
        if (q >= end) return null
        for (pair in link.substring(q + 1, end).split('&')) {
            val kv = pair.split('=', limit = 2)
            if (kv.size == 2 && kv[0] == "t" && kv[1].isNotEmpty()) return kv[1]
        }
        return null
    }

    // ---- Media-wanted / media-available frames (31/32) ----------------------------------------

    data class MediaFrame(val from: String, val ref: String, val circleId: String, val postId: String)

    /** Body of both frames: `[hex64 me][LP ref][LP circleId][LP postId]`. */
    fun mediaFrameBody(myHex: String, ref: String, circleId: String, postId: String): ByteArray {
        val out = ArrayList<Byte>()
        myHex.toByteArray(Charsets.UTF_8).forEach { out.add(it) }
        Wire.lpAppend(out, ref.toByteArray(Charsets.UTF_8))
        Wire.lpAppend(out, circleId.toByteArray(Charsets.UTF_8))
        Wire.lpAppend(out, postId.toByteArray(Charsets.UTF_8))
        return out.toByteArray()
    }

    /** Null if the frame is malformed. The sender is lower-cased. */
    fun parseMediaFrame(body: ByteArray): MediaFrame? {
        if (body.size <= 64) return null
        val from = runCatching { String(body.copyOfRange(0, 64), Charsets.UTF_8) }.getOrNull() ?: return null
        if (from.length != 64) return null
        val r = Wire.Reader(body, 64)
        val ref = r.lp()?.let { String(it, Charsets.UTF_8) } ?: return null
        val circleId = r.lp()?.let { String(it, Charsets.UTF_8) } ?: return null
        val postId = r.lp()?.let { String(it, Charsets.UTF_8) } ?: return null
        if (ref.isEmpty() || circleId.isEmpty()) return null
        return MediaFrame(from.lowercase(), ref, circleId, postId)
    }

    // ---- hex ---------------------------------------------------------------------------------

    fun hexToBytes32(hex: String): ByteArray? {
        if (hex.length != 64) return null
        return runCatching { ByteArray(32) { i -> hex.substring(i * 2, i * 2 + 2).toInt(16).toByte() } }.getOrNull()
    }

    fun bytesToHex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
}
