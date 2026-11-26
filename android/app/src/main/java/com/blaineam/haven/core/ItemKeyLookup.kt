package com.blaineam.haven.core

/** What looking for one blob's content key came to (DECISIONS D27). */
sealed class ItemKeyResult {
    class Found(val entry: ByteArray) : ItemKeyResult()
    /** Every destination answered and none gave a key for it. */
    object Missing : ItemKeyResult()
    /** Something did not answer: try again later rather than give the blob up. */
    object Unreachable : ItemKeyResult()
}

/**
 * One blob's key from ONE destination, reading as little of the blob as that destination allows:
 * its last 64 KB where the destination honors a suffix range, all of it where the key is not in
 * those bytes (more recipients than the tail holds, an old JSON envelope). Core `mediakeys.rs`
 * `item_key_over_http` / Apple `SharedStore.itemKeyOverHttp`.
 */
object ItemKeyLookup {
    /** [partial] = [bytes] are only the end of the object. */
    class Tail(val bytes: ByteArray, val partial: Boolean)

    /** One destination. Both reads return null when it ANSWERED and does not hold the key, and
     *  throw when it did not answer. */
    interface Reader {
        suspend fun tail(key: String): Tail?
        suspend fun whole(key: String): ByteArray?
    }

    /** A destination that can only hand over whole objects (S3, an iroh dial, our own store). */
    class WholeReader(private val get: suspend (String) -> ByteArray?) : Reader {
        override suspend fun tail(key: String): Tail? = get(key)?.let { Tail(it, false) }
        override suspend fun whole(key: String): ByteArray? = get(key)
    }

    /**
     * The key entry for [ref], or null when this destination answered and has none to give.
     * [unwrap] is the engine (`itemKeyFromTail`). A blob over [maxWholeBytes] is never pulled
     * whole into memory.
     */
    suspend fun fromDestination(
        reader: Reader,
        ref: String,
        maxWholeBytes: Long,
        unwrap: (ByteArray) -> ByteArray?,
    ): ByteArray? {
        val mediaKey = HavenKeys.mediaKey(ref)
        val head = reader.tail(mediaKey) ?: return null
        val chunks = HavenKeys.parseManifest(head.bytes)
        var tail = head.bytes
        var partial = head.partial
        if (chunks != null) {
            if (chunks <= 0) return null
            val last = reader.tail(HavenKeys.mediaChunkKey(ref, chunks - 1)) ?: return null
            tail = last.bytes
            var cut = last.partial
            var used = 1
            if (tail.size < HistoryHandoffWire.KEY_TAIL_BYTES && chunks > 1) {
                // A short last chunk: the entries run back into the one before it.
                val before = reader.tail(HavenKeys.mediaChunkKey(ref, chunks - 2)) ?: return null
                cut = cut || before.partial || before.bytes.size > HistoryHandoffWire.KEY_TAIL_BYTES - tail.size
                tail = HistoryHandoffWire.joinTail(before.bytes, tail)
                used = 2
            }
            partial = cut || chunks > used
        }
        unwrap(tail)?.let { return it }
        if (!partial) return null
        // More recipients than the tail holds, or an old JSON envelope: read it whole.
        if (chunks == null) {
            val all = reader.whole(mediaKey) ?: return null
            return unwrap(all)
        }
        val all = java.io.ByteArrayOutputStream()
        for (i in 0 until chunks) {
            val c = reader.whole(HavenKeys.mediaChunkKey(ref, i)) ?: return null
            if (all.size().toLong() + c.size > maxWholeBytes) return null
            all.write(c)
        }
        return unwrap(all.toByteArray())
    }
}
