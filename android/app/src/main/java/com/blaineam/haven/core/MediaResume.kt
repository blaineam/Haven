package com.blaineam.haven.core

/**
 * The frame-33 (media RESUME request) wire format and the chunk bitmap it wraps — a byte-exact port
 * of iOS `ReassemblyStore.encodeResume/decodeResume` (apple/HavenApp/MediaReassembly.swift). This
 * MUST stay identical to iOS/desktop or a cross-platform resume silently asks for the wrong chunks,
 * so it lives here as PURE functions with unit tests and touches no Android API.
 *
 * WHY IT EXISTS: a serve is slow by construction — 32 KB chunks, a KEM seal each — so a 50 MB video
 * is 1,600 sealed sends and any interruption in that window used to throw all of it away and restart
 * at chunk 0. That is why large media "never loaded": it wasn't failing once, it was restarting
 * forever. Frame 33 lets the requester say what it already holds so the serve sends only the holes.
 *
 *   `[hex64 requester][u16 LE refLen][ref utf8][u32 LE total][bitmap]`
 *
 * Bitmap: bit i of byte i/8 set = chunk i is already on the requester's disk. 1,600 chunks is 200
 * bytes — cheap to keep and cheap to send.
 */
object MediaResume {

    /** A peer controls the declared chunk count, so it is bounded at the parse: 4M chunks is ~128 GB,
     *  far past any real media, and a frame claiming 4.2 billion must be REFUSED rather than
     *  allocated for (Kotlin reads that u32 as a negative Int, which is its own trap — see [decode]). */
    const val MAX_CHUNKS: Int = 4_000_000

    /** Bytes a bitmap for [total] chunks must be, exactly. Anything else is malformed. */
    fun bitmapSize(total: Int): Int = (total + 7) / 8

    fun bitmap(got: Set<Int>, total: Int): ByteArray {
        val bits = ByteArray(bitmapSize(maxOf(0, total)))
        for (i in got) {
            if (i < 0 || i >= total) continue
            bits[i / 8] = (bits[i / 8].toInt() or (1 shl (i % 8))).toByte()
        }
        return bits
    }

    fun indices(bits: ByteArray, total: Int): Set<Int> {
        val out = HashSet<Int>()
        for (i in 0 until maxOf(0, total)) {
            val b = i / 8
            if (b >= bits.size) break
            if (bits[b].toInt() and (1 shl (i % 8)) != 0) out.add(i)
        }
        return out
    }

    /**
     * A parsed frame 33. [bitmap] stays RAW — deliberately not expanded into a set of chunk indices.
     *
     * [MAX_CHUNKS] is 4 million, so expanding at parse time would let a peer spend a ~500 KB frame to
     * make us build a 4M-entry `HashSet<Int>` — boxed Integers, hundreds of megabytes, on a phone,
     * before anything had even checked we hold the ref. The caller expands only after the declared
     * total matches the one IT computes from its own file, which bounds the work by a file we actually
     * have rather than by a number the sender chose.
     */
    data class Request(val requesterHex: String, val ref: String, val total: Int, val bitmap: ByteArray)

    fun encode(myHex: String, ref: String, total: Int, got: Set<Int>): ByteArray {
        val refBytes = ref.toByteArray(Charsets.UTF_8)
        val bits = bitmap(got, total)
        val out = ArrayList<Byte>(64 + 2 + refBytes.size + 4 + bits.size)
        myHex.toByteArray(Charsets.UTF_8).forEach { out.add(it) }
        out.add((refBytes.size and 0xFF).toByte()); out.add(((refBytes.size ushr 8) and 0xFF).toByte())
        refBytes.forEach { out.add(it) }
        out.add((total and 0xFF).toByte()); out.add(((total ushr 8) and 0xFF).toByte())
        out.add(((total ushr 16) and 0xFF).toByte()); out.add(((total ushr 24) and 0xFF).toByte())
        bits.forEach { out.add(it) }
        return out.toByteArray()
    }

    /**
     * Null for anything malformed. EVERY field here is peer-controlled, so every one is bounded before
     * it is used: the ref length must fit inside the buffer it claims to index, the declared total must
     * be plausible ([MAX_CHUNKS]), and the bitmap must be EXACTLY the size that total implies — which
     * is what makes a "4.2 billion chunks" frame a rejection rather than an allocation.
     */
    fun decode(body: ByteArray): Request? {
        if (body.size < 64 + 2) return null
        val requesterHex = String(body.copyOfRange(0, 64), Charsets.UTF_8)
        var off = 64
        val refLen = (body[off].toInt() and 0xFF) or ((body[off + 1].toInt() and 0xFF) shl 8)
        off += 2
        if (body.size < off + refLen + 4) return null
        val ref = String(body.copyOfRange(off, off + refLen), Charsets.UTF_8)
        off += refLen
        // Read the u32 into a LONG first: at 4.2 billion this lands in Kotlin's signed Int as a
        // negative, which would sail past a naive `total <= MAX_CHUNKS` check and then be handed to
        // an allocation. Bound it while it is still unsigned.
        val total = ((body[off].toInt() and 0xFF).toLong()) or
            ((body[off + 1].toInt() and 0xFF).toLong() shl 8) or
            ((body[off + 2].toInt() and 0xFF).toLong() shl 16) or
            ((body[off + 3].toInt() and 0xFF).toLong() shl 24)
        off += 4
        if (requesterHex.length != 64 || ref.isEmpty()) return null
        if (total < 1 || total > MAX_CHUNKS) return null
        val bits = body.copyOfRange(off, body.size)
        if (bits.size != bitmapSize(total.toInt())) return null
        return Request(requesterHex, ref, total.toInt(), bits)
    }
}
