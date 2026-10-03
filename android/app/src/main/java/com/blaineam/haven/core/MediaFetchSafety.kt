package com.blaineam.haven.core

import kotlinx.coroutines.CompletableDeferred
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

// The guards behind "one fetch of a ref must never get it judged corrupt and quarantined" (desktop
// fix 85dd646b, ported; Apple MediaFetchSafety.swift). JVM-only, so they unit-test without a device.
//
// The failure they close: the serialized media lane and the relay-history resync can fetch the same
// ref at once, and the verify sweep reads held blobs whenever it likes. A plain writeBytes truncates
// the live file before refilling it, so a concurrent reader saw 0 bytes or half a blob, failed to
// open it and QUARANTINED the ref — persisted, with the bytes kept and `has()` answering true, so
// nothing ever fetched it again. A relay answering 200 with an empty body did the same thing
// directly: an empty file on disk that "opens for no circle".

/**
 * One in-flight run per key. A caller that finds a run for the same key already going awaits the
 * LEADER's result instead of starting a second download into the same files.
 *
 * A leader that is cancelled (or throws) hands its joiners `null`, and each of them then takes its
 * own turn — a timed-out or cancelled fetch can never wedge a ref as permanently "in flight".
 */
class SingleFlight<T : Any> {
    private val flights = ConcurrentHashMap<String, CompletableDeferred<T?>>()

    suspend fun run(key: String, block: suspend () -> T): T {
        while (true) {
            val mine = CompletableDeferred<T?>()
            val running = flights.putIfAbsent(key, mine)
            if (running != null) {
                running.await()?.let { return it }
                continue   // the leader never finished — take our own turn
            }
            var result: T? = null
            try {
                result = block()
                return result
            } finally {
                flights.remove(key, mine)
                mine.complete(result)
            }
        }
    }

    fun inFlight(key: String): Boolean = flights.containsKey(key)
}

object MediaFiles {
    private val seq = AtomicLong()

    /** A per-call scratch file beside [dst] named `incoming_*` — the prefix every inventory and
     *  `has()` lookup already skips, and the orphan sweep reclaims if one is ever leaked. */
    fun scratchFor(dst: File, tag: String): File =
        File(dst.parentFile, "incoming_${dst.name}.${System.nanoTime()}-${seq.incrementAndGet()}.$tag.part")

    /**
     * Write [bytes] to [dst] ATOMICALLY: temp file + rename, so a reader sees the old file or the new
     * one, never a truncated one. Returns false (and writes nothing) for an EMPTY body — nothing
     * sealed is zero bytes, so the caller treats that as a miss, not as a stored copy.
     */
    fun writeAtomic(dst: File, bytes: ByteArray): Boolean {
        if (bytes.isEmpty()) return false
        val tmp = scratchFor(dst, "raw")
        return try {
            tmp.writeBytes(bytes)
            replace(dst, tmp)
        } catch (_: Exception) {
            false
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }

    /**
     * Move [src] over [dst] in ONE step. rename(2) replaces an existing target atomically on the
     * same filesystem, so this never deletes first — the old delete-then-rename left a window in
     * which the ref looked absent. Falls back to copy only when a rename is impossible.
     */
    fun replace(dst: File, src: File): Boolean {
        if (src.renameTo(dst)) return true
        return runCatching {
            src.copyTo(dst, overwrite = true)
            src.delete()
            true
        }.getOrDefault(false)
    }
}
