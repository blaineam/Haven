package com.blaineam.haven.core

/**
 * The pure half of "which relay holds which media blob" — the decisions behind the backup ledger
 * (`HavenNet.markBackedUp`), Apple `MediaHolding.swift` parity. No Android imports: plain JVM tests.
 *
 * Field report (2.0.0-rc.3, iPhone; the same pattern existed here): after "Load history from your
 * relays" pulled hundreds of posts and their media, the phone got hot and stayed hot.
 *   1. The ledger was written only on the upload/probe paths — a blob just downloaded, complete and
 *      opened, from relay X was not recorded as held by X.
 *   2. So the backfill re-offered every one of those refs, and the probe asked each relay "do you hold
 *      it?" with a FULL GET of the blob — re-downloading each recovered photo from the relay it had
 *      just come from — then re-sealed and uploaded it to any relay that lacked it.
 *   3. That mirroring of media this device did not author was gated only at SERIOUS thermal.
 */
object MediaHolding {

    // ---- Download → ledger ----

    /**
     * The ledger destination to record as HOLDING a ref after a download from [source] (a relay node
     * hex or an `s3:` pseudo-relay id) — ONLY when the blob was complete AND opened. A partial or an
     * undecryptable copy proves nothing about what the source holds, and a ledger entry is permanent.
     */
    fun holderToRecord(source: String?, complete: Boolean, opened: Boolean): String? =
        if (complete && opened && !source.isNullOrEmpty()) source else null

    // ---- The "does this relay hold it?" probe ----

    /** One `HEAD /k/<key>` answer. [UNSUPPORTED] = 400/405/501 (an old relay or a proxy) → fall back to GET. */
    enum class Head { PRESENT, ABSENT, UNSUPPORTED, REFUSED, UNREACHABLE }

    /** One GET answer (the fallback probe, and the tiny manifest read). */
    sealed class Fetch {
        class Data(val bytes: ByteArray) : Fetch()
        object Miss : Fetch()
        object Refused : Fetch()
        object Unreachable : Fetch()
    }

    enum class Verdict { COMPLETE, INCOMPLETE, ABSENT, REFUSED, UNREACHABLE }

    data class Probe(val verdict: Verdict, val fullGets: Int)

    /**
     * Does a relay hold a COMPLETE copy, as cheaply as possible? HEAD the manifest key (absent →
     * ABSENT); HEAD chunk 0 (absent → unchunked, presence is completeness); chunked → GET the ~100-byte
     * manifest for the window count and HEAD the LAST window (the `holdsCompleteBlob` tail check).
     * A relay that won't answer HEAD gets exactly the old GET probe. [Probe.fullGets] counts GETs of a
     * key that may be a whole blob (the QA "probeGet" counter); the tiny manifest GET is not one.
     */
    suspend fun probe(
        manifestKey: String,
        chunkKey: (Int) -> String,
        head: suspend (String) -> Head,
        get: suspend (String) -> Fetch,
        chunkCount: (ByteArray) -> Int?,
    ): Probe {
        return when (head(manifestKey)) {
            Head.REFUSED -> Probe(Verdict.REFUSED, 0)
            Head.UNREACHABLE -> Probe(Verdict.UNREACHABLE, 0)
            Head.ABSENT -> Probe(Verdict.ABSENT, 0)
            Head.UNSUPPORTED -> legacyProbe(manifestKey, chunkKey, get, chunkCount)
            Head.PRESENT -> when (head(chunkKey(0))) {
                Head.ABSENT -> Probe(Verdict.COMPLETE, 0)
                Head.REFUSED -> Probe(Verdict.REFUSED, 0)
                Head.UNREACHABLE -> Probe(Verdict.UNREACHABLE, 0)
                Head.UNSUPPORTED -> legacyProbe(manifestKey, chunkKey, get, chunkCount)
                Head.PRESENT -> when (val m = get(manifestKey)) {
                    is Fetch.Refused -> Probe(Verdict.REFUSED, 0)
                    is Fetch.Unreachable -> Probe(Verdict.UNREACHABLE, 0)
                    is Fetch.Miss -> Probe(Verdict.ABSENT, 0)
                    is Fetch.Data -> {
                        val n = chunkCount(m.bytes)
                        if (n == null || n <= 0) Probe(Verdict.COMPLETE, 0)
                        else when (head(chunkKey(n - 1))) {
                            Head.PRESENT -> Probe(Verdict.COMPLETE, 0)
                            Head.ABSENT -> Probe(Verdict.INCOMPLETE, 0)
                            Head.REFUSED -> Probe(Verdict.REFUSED, 0)
                            Head.UNREACHABLE, Head.UNSUPPORTED -> Probe(Verdict.UNREACHABLE, 0)
                        }
                    }
                }
            }
        }
    }

    private suspend fun legacyProbe(
        manifestKey: String, chunkKey: (Int) -> String,
        get: suspend (String) -> Fetch, chunkCount: (ByteArray) -> Int?,
    ): Probe = when (val m = get(manifestKey)) {
        is Fetch.Refused -> Probe(Verdict.REFUSED, 1)
        is Fetch.Unreachable -> Probe(Verdict.UNREACHABLE, 1)
        is Fetch.Miss -> Probe(Verdict.ABSENT, 1)
        is Fetch.Data -> {
            val n = chunkCount(m.bytes)
            if (n == null || n <= 0) Probe(Verdict.COMPLETE, 1)
            else {
                val tail = get(chunkKey(n - 1))
                if (tail is Fetch.Data && tail.bytes.isNotEmpty()) Probe(Verdict.COMPLETE, 2)
                else Probe(Verdict.INCOMPLETE, 2)
            }
        }
    }

    // ---- Backfill ----

    /** Whether the backfill should offer [ref] at all: not when the ledger already confirms every
     *  relay the circle publishes to. [wanted] empty → the old "held anywhere remote" test. */
    fun needsBackfill(wanted: Collection<String>, held: Set<String>, heldRemotely: Boolean): Boolean =
        if (wanted.isEmpty()) !heldRemotely else !held.containsAll(wanted)

    /**
     * Backfill of media this device is NOT the only safe holder of — someone else's post, or my own
     * post whose blob already sits on a relay another device can read (the history-recovery case) —
     * is MIRRORING: background priority ([HeavyWorkPolicy.backupAllowed] with `mirror`). [mine] null =
     * unknown (a job re-offered from the persisted queue): treated as mirroring; the next backfill
     * sweep re-offers my own media tagged.
     */
    fun isBackgroundMirror(mine: Boolean?, heldRemotely: Boolean): Boolean = mine != true || heldRemotely

    /** Mirror refs one backfill sweep may offer per circle — small, so a recovered history trickles. */
    const val MIRROR_PER_SWEEP = 12
}
