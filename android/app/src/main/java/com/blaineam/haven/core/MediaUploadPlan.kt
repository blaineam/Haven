package com.blaineam.haven.core

import java.security.MessageDigest

/**
 * Which 8 MB windows of a chunked media upload still have to cross the wire — and, just as
 * important, when skipping a window is SAFE.
 *
 * ---- Why resume at all -----------------------------------------------------------------------
 *
 * A large sealed video rides as 8 MB windows written IN ORDER to `haven/media/<ref>.p/<i>`, followed
 * by an `HVCHUNK1` manifest at `haven/media/<ref>`. The uploader used to re-send every window from 0
 * on each attempt, and on a phone leaving the app IS an interruption: a 600 MB video (≈75 windows)
 * would push maybe 20, get suspended, and start again at window 0 next time. It never converges —
 * the blob is simply larger than one uninterrupted session can push, and no amount of retrying fixes
 * that when every retry throws the progress away. That is the difference between "slow" and "never",
 * and it is why an upload could sit on the same indicator for hours. Chunk keys are content-addressed
 * and idempotent, so a window already stored never needs to cross the wire again.
 *
 * ---- Why the probe is a PREFIX scan ----------------------------------------------------------
 *
 * Windows are written strictly in order and the loop stops at the first failure, so a destination's
 * progress is always a PREFIX of the windows — never a hole in the middle. Probing sequentially and
 * stopping at the first miss therefore costs exactly (skipped + 1) probes: one probe when there is no
 * prior progress at all, which is what keeps this cheap on the common path. Probing every window
 * would cost a full download per window on the destinations that have no cheap existence check.
 *
 * ---- Why a probe is NOT enough: the silent-corruption trap -----------------------------------
 *
 * This is the correctness half, and it is not optional. Sealing is NOT byte-stable: the envelope
 * carries per-recipient key material (so its length moves as device rosters arrive) AND a fresh nonce
 * — so for an IDENTICAL recipient set the bytes differ while the length matches EXACTLY. iOS meets
 * this by re-sealing per upload attempt; here the at-rest file IS the seal, but it is still rewritten
 * for an existing ref: a ref is the digest of the PLAINTEXT, so re-storing the same photo re-seals it
 * under the same ref with a new nonce, and a local wipe + re-post or a repair of a stored blob that
 * won't decrypt does the same.
 *
 * Splice windows from one seal onto windows from another and the blob reassembles to precisely the
 * right length and decrypts to nothing. The equal-length case is the COMMON one, so it corrupts
 * SILENTLY, presents as "media won't open", and — the key being content-addressed and write-once — is
 * then frozen in place. One such blob is already in the field.
 *
 * The trap is that asking the destination "do you hold window i?" cannot tell "present" from "present
 * AND sliced from these bytes". Two ways to get a YES that must NOT be trusted:
 *
 *  * the seal was replaced PART-WAY through an upload. The destination now holds a mix: the leading
 *    windows this attempt rewrote, and a tail left over from the old seal. Every one of them probes
 *    present.
 *  * another device of the same account uploaded the same ref. Same plaintext, same ref, an entirely
 *    different seal — and own-device media sync makes this an ordinary occurrence, not a corner case.
 *
 * So a window is skipped only when WE wrote it, from THESE bytes: [trustedPrefix] caps the skip at the
 * high-water mark recorded for that destination under this exact fingerprint, and the probe then
 * confirms the bytes are still there (a relay may have swept them). Both must agree. The asymmetry is
 * the whole point — a cap that is too LOW costs a re-upload of bytes that were fine, while one that is
 * too high is permanent corruption. When in doubt, re-send.
 */
object MediaUploadPlan {

    /** 8 MB — well under the relay's 256 MB MAX_BLOB, and memory-safe on a low-heap phone. */
    const val CHUNK_BYTES = 8 * 1024 * 1024

    /** Byte ranges of each window over a blob of [size] bytes: (from, toExclusive), in wire order. */
    fun windows(size: Int, chunkBytes: Int = CHUNK_BYTES): List<Pair<Int, Int>> {
        val out = ArrayList<Pair<Int, Int>>()
        var off = 0
        while (off < size) {
            val end = minOf(off + chunkBytes, size)
            out.add(off to end)
            off = end
        }
        return out
    }

    /**
     * Identity of the exact sealed bytes an upload is made of. Hashing a few hundred MB costs about a
     * second — trivial next to the tens of windows of network the resume decision is gating, and this
     * runs only when a reachable destination actually needs the blob.
     */
    fun sealFingerprint(blob: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(blob).joinToString("") { "%02x".format(it) }

    /**
     * How many leading windows this destination may be ASKED about — the count we ourselves wrote to
     * it from these exact sealed bytes, and nothing beyond. Windows past this point may well be
     * present; they are simply not provably ours (see the two YES-you-must-not-trust cases above).
     *
     * [force] is the recovery path, whose whole purpose is to OVERWRITE what is stored, so it trusts
     * nothing. A destination with no record for this ref (first attempt, another device's upload, or
     * an eviction from the bounded record) also trusts nothing and re-sends everything — the safe
     * direction, and the only one that is safe.
     */
    fun trustedPrefix(force: Boolean, recordedFp: String?, currentFp: String, recordedWindows: Int, total: Int): Int {
        if (force || recordedFp == null || recordedFp != currentFp) return 0
        return recordedWindows.coerceIn(0, total)
    }

    /**
     * Index of the first window that still has to be sent, given the probe answers gathered so far
     * (see the prefix argument above). Anything after the first miss is ignored even if it is `true`:
     * a gap means our "progress is a prefix" assumption did not hold, and re-sending is the safe
     * reading of that.
     */
    fun skipCount(probed: List<Boolean>): Int {
        var n = 0
        while (n < probed.size && probed[n]) n++
        return n
    }
}
