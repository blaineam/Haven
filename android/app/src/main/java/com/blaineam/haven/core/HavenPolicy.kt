package com.blaineam.haven.core

import org.json.JSONObject

/**
 * Small decision rules lifted out of [HavenNet] so they can be tested with plain values: how often to
 * poll, who to ask for media, how many relay hints one requester gets, what a push banner carries and
 * how a direct media chunk is framed.
 */
internal object PollCadence {
    // android.os.PowerManager.THERMAL_STATUS_* (inlined constants; kept numeric so this stays JVM-testable).
    private const val MODERATE = 2
    private const val SEVERE = 3

    /**
     * Multiplier on a base poll interval. Idle users are polled less (x3 after 3 min, x6 after 15),
     * a hot phone is polled less (x2 from SEVERE up, x1.5 at MODERATE) and so is data-saver mode
     * (x1.5). [thermalStatus] null = unknown/unsupported. Never below 1.
     */
    fun multiplier(idleMs: Long, thermalStatus: Int?, dataSaver: Boolean): Long {
        var mult = when {
            idleMs < 180_000 -> 1L
            idleMs < 900_000 -> 3L
            else -> 6L
        }
        when {
            thermalStatus == null -> {}
            thermalStatus >= SEVERE -> mult *= 2
            thermalStatus == MODERATE -> mult = (mult * 3) / 2
        }
        if (dataSaver) mult = (mult * 3) / 2
        return mult.coerceAtLeast(1L)
    }

    /** Foreground polling never stretches past twice the base cadence. */
    fun mailboxInterval(full: Long, base: Long, foreground: Boolean): Long =
        if (foreground) minOf(full, base * 2) else full
}

internal object MediaAsk {
    const val SELF_AUTHOR = "<me>"

    /**
     * Who, among my friends, a direct media ask goes to: the AUTHOR first (they hold it by
     * definition); my own media -> no friend; once [askNumber] exceeds [targetedBeforeBroadcast], or the
     * author is unknown, widen to everyone so media whose author is offline can come from another holder.
     */
    fun targets(all: List<String>, askNumber: Int, author: String?, targetedBeforeBroadcast: Int): List<String> {
        if (askNumber > targetedBeforeBroadcast || author == null) return all
        if (author == SELF_AUTHOR) return emptyList()
        return all.firstOrNull { it.startsWith(author, ignoreCase = true) }?.let { listOf(it) } ?: all
    }
}

/** At most [max] relay hints per (media ref, requester) per [windowMs]; the table is bounded. */
internal class RelayHintBudget(
    private val windowMs: Long,
    private val max: Int,
    private val capacity: Int = 2000,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val sent = HashMap<String, Pair<Int, Long>>()

    fun count(ref: String, requester: String): Int = synchronized(sent) {
        val e = sent["$ref|$requester"] ?: return 0
        if (now() - e.second >= windowMs) 0 else e.first
    }

    /** Record one hint; false once the window's budget is spent (the caller stays quiet). */
    fun note(ref: String, requester: String): Boolean = synchronized(sent) {
        val key = "$ref|$requester"
        val t = now()
        var e = sent[key] ?: (0 to t)
        if (t - e.second >= windowMs) e = 0 to t
        if (e.first >= max) return false
        sent[key] = (e.first + 1) to e.second
        if (sent.size > capacity) sent.clear()
        true
    }
}

internal object PushBannerJson {
    /** The sealed banner a push carries. [senderName] blank -> "Someone". Optional fields omitted. */
    fun encode(senderName: String, copy: PushBanner.Copy, circleId: String): ByteArray? = runCatching {
        val o = JSONObject()
            .put("t", senderName.ifBlank { "Someone" })
            .put("b", copy.body)
            .put("bp", copy.privateBody)
            .put("c", circleId)
            .put("k", copy.kind)
        copy.emoji?.let { o.put("e", it) }
        copy.postId?.takeIf { it.isNotEmpty() }?.let { o.put("p", it) }
        o.toString().toByteArray(Charsets.UTF_8)
    }.getOrNull()
}

/** Direct media chunk (frame 5): `[u16 LE refLen][ref][u32 LE index][u32 LE total][sealed chunk]`. */
internal object ChunkFrame {
    class Parsed(val ref: String, val index: Int, val total: Int, val sealed: ByteArray)

    fun encode(refBytes: ByteArray, index: Int, total: Int, sealed: ByteArray): ByteArray {
        val out = ArrayList<Byte>(2 + refBytes.size + 8 + sealed.size)
        out.add((refBytes.size and 0xFF).toByte()); out.add(((refBytes.size ushr 8) and 0xFF).toByte())
        refBytes.forEach { out.add(it) }
        for (v in intArrayOf(index, total)) {
            out.add((v and 0xFF).toByte()); out.add(((v ushr 8) and 0xFF).toByte())
            out.add(((v ushr 16) and 0xFF).toByte()); out.add(((v ushr 24) and 0xFF).toByte())
        }
        sealed.forEach { out.add(it) }
        return out.toByteArray()
    }

    /** Null when the frame is too short to hold its own header. Bounds on the fields are the caller's. */
    fun decode(body: ByteArray): Parsed? {
        if (body.size < 2) return null
        val refLen = (body[0].toInt() and 0xFF) or ((body[1].toInt() and 0xFF) shl 8)
        if (body.size < 2 + refLen + 8) return null
        val ref = String(body.copyOfRange(2, 2 + refLen), Charsets.UTF_8)
        var off = 2 + refLen
        fun u32(): Int {
            val v = (body[off].toInt() and 0xFF) or ((body[off + 1].toInt() and 0xFF) shl 8) or
                ((body[off + 2].toInt() and 0xFF) shl 16) or ((body[off + 3].toInt() and 0xFF) shl 24)
            off += 4; return v
        }
        val index = u32(); val total = u32()
        return Parsed(ref, index, total, body.copyOfRange(off, body.size))
    }
}
