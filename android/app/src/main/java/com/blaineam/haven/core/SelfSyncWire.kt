package com.blaineam.haven.core

import org.json.JSONObject

/**
 * The pure half of [SelfSyncCoordinator]: the byte encodings that must match iOS, and the
 * last-writer-wins resolution of the "removed / re-added" record pairs. Split out so it can be
 * tested without the engine, the transports, or any Android object.
 */
internal object SelfSyncWire {
    /** The winning verdict for one id: [ts] is the winning side's timestamp. */
    data class Resolved(val id: String, val ts: Long, val removed: Boolean)

    /**
     * Resolve `<removedPrefix><id>` against `<readdPrefix><id>` records (each an 8-byte LE ms). Per id
     * the NEWEST side wins; [tieRemoves] says whether an exact tie goes to the removal (contacts,
     * circles) or to the re-add (relays). Records that aren't exactly 8 bytes, or have an empty id, are
     * ignored. [legacyPrefix] (1-byte 1/0 records from pre-LWW builds) counts as ts=1 so it loses to
     * any real write. [normalize] canonicalises an id before grouping.
     */
    fun resolve(
        entries: Iterable<Pair<String, ByteArray>>,
        removedPrefix: String,
        readdPrefix: String,
        tieRemoves: Boolean,
        legacyPrefix: String? = null,
        normalize: (String) -> String = { it },
    ): List<Resolved> {
        val removedMs = LinkedHashMap<String, Long>()
        val readdMs = LinkedHashMap<String, Long>()
        for ((key, value) in entries) {
            when {
                key.startsWith(removedPrefix) && value.size == 8 -> bump(removedMs, key.removePrefix(removedPrefix), normalize, int64LEValue(value))
                key.startsWith(readdPrefix) && value.size == 8 -> bump(readdMs, key.removePrefix(readdPrefix), normalize, int64LEValue(value))
                legacyPrefix != null && key.startsWith(legacyPrefix) && value.size == 1 ->
                    bump(if (value[0].toInt() == 1) removedMs else readdMs, key.removePrefix(legacyPrefix), normalize, 1L)
            }
        }
        val out = ArrayList<Resolved>()
        for (id in removedMs.keys + readdMs.keys) {
            val rem = removedMs[id] ?: 0L
            val readd = readdMs[id] ?: 0L
            val removed = (if (tieRemoves) rem >= readd else rem > readd) && rem > 0L
            if (removed) out.add(Resolved(id, rem, true))
            else if (readd > 0L) out.add(Resolved(id, readd, false))
        }
        return out.distinctBy { it.id }
    }

    private fun bump(into: MutableMap<String, Long>, rawId: String, normalize: (String) -> String, ts: Long) {
        if (rawId.isEmpty()) return
        val id = normalize(rawId)
        into[id] = maxOf(into[id] ?: 0L, ts)
    }

    /** Circle severance ids are `<circleId>|<memberHex>`; the member hex is case-folded so two
     *  devices that spelled it differently still agree. */
    fun normalizeSeveranceId(entry: String): String {
        val bar = entry.indexOf('|'); if (bar < 0) return entry
        return entry.substring(0, bar) + "|" + entry.substring(bar + 1).lowercase()
    }

    /** Split a severance id into (circleId, memberHex), or null when malformed. */
    fun splitSeveranceId(key: String): Pair<String, String>? {
        val bar = key.indexOf('|')
        if (bar <= 0 || bar >= key.length - 1) return null
        return key.substring(0, bar) to key.substring(bar + 1)
    }

    /** Stable Android contact JSON. Need NOT match iOS (structs differ) — just stable on Android. */
    fun encodeContact(c: Contact): ByteArray =
        JSONObject().apply {
            put("id_hex", c.idHex)
            put("name", c.name)
            put("verify", c.verifyHex)
        }.toString().toByteArray(Charsets.UTF_8)

    fun decodeContact(bytes: ByteArray): Contact? = runCatching {
        val o = JSONObject(String(bytes, Charsets.UTF_8))
        Contact(o.getString("id_hex"), o.optString("name", ""), o.optString("verify", ""))
    }.getOrNull()

    fun int32LE(v: Int): ByteArray = byteArrayOf(
        (v and 0xFF).toByte(),
        ((v ushr 8) and 0xFF).toByte(),
        ((v ushr 16) and 0xFF).toByte(),
        ((v ushr 24) and 0xFF).toByte(),
    )

    fun int32LEValue(b: ByteArray): Int =
        (b[0].toInt() and 0xFF) or
            ((b[1].toInt() and 0xFF) shl 8) or
            ((b[2].toInt() and 0xFF) shl 16) or
            ((b[3].toInt() and 0xFF) shl 24)

    /** 8-byte little-endian encoding of an unsigned ms timestamp (byte-identical to iOS's LE UInt64). */
    fun int64LE(v: Long): ByteArray = ByteArray(8) { i -> ((v ushr (i * 8)) and 0xFF).toByte() }

    fun int64LEValue(b: ByteArray): Long {
        var v = 0L
        for (i in 0 until 8) v = v or ((b[i].toLong() and 0xFF) shl (i * 8))
        return v
    }

    /** 1 byte, `1` = true. Empty = no value. */
    fun boolValue(v: ByteArray?): Boolean? {
        if (v == null || v.isEmpty()) return null
        return v[0].toInt() == 1
    }

    fun toHex(b: ByteArray): String =
        b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    fun fromHex(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        val out = ByteArray(hex.length / 2)
        var i = 0
        while (i < hex.length) {
            val byte = hex.substring(i, i + 2).toIntOrNull(16) ?: return null
            out[i / 2] = byte.toByte()
            i += 2
        }
        return out
    }
}
