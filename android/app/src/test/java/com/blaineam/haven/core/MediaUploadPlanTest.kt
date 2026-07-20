package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * The resume decision for a chunked media upload. Two things are being locked down here, and they
 * fail in very different ways:
 *
 *  * the WINDOW LAYOUT must stay byte-identical to iOS/desktop, or the three platforms slice the same
 *    sealed blob differently and can't read each other's chunks;
 *  * the TRUST rule must never let windows from two different seals be spliced together. That failure
 *    is silent — the blob reassembles to exactly the right length and decrypts to nothing — and
 *    because the key is content-addressed and write-once, the corruption is permanent. A test that
 *    only checked "already-stored windows get skipped" would pass on the broken version, because the
 *    broken version skips MORE.
 */
class MediaUploadPlanTest {

    private val chunk = MediaUploadPlan.CHUNK_BYTES

    // ---- Window layout -----------------------------------------------------------------------

    @Test fun windows_cover_the_blob_exactly_with_a_short_tail() {
        val size = chunk * 3 + 12345
        val w = MediaUploadPlan.windows(size)
        assertEquals(4, w.size)
        assertEquals(0, w.first().first)
        assertEquals(size, w.last().second)
        // Contiguous, no gaps or overlaps — a hole here is a corrupt blob on the far side.
        for (i in 1 until w.size) assertEquals(w[i - 1].second, w[i].first)
        assertEquals(12345, w.last().second - w.last().first)
    }

    @Test fun an_exact_multiple_produces_no_empty_trailing_window() {
        assertEquals(2, MediaUploadPlan.windows(chunk * 2).size)
    }

    @Test fun an_empty_blob_produces_no_windows() {
        assertEquals(0, MediaUploadPlan.windows(0).size)
    }

    // ---- Which windows get skipped -------------------------------------------------------------

    @Test fun the_leading_run_already_stored_is_skipped() {
        assertEquals(3, MediaUploadPlan.skipCount(listOf(true, true, true, false)))
    }

    @Test fun nothing_stored_means_nothing_skipped() {
        assertEquals(0, MediaUploadPlan.skipCount(listOf(false)))
    }

    @Test fun a_gap_stops_the_skip_rather_than_jumping_it() {
        // Progress is a prefix by construction (windows are written in order, and the loop breaks at
        // the first failure). A hole means that invariant did not hold, so re-send from the hole —
        // skipping past it would leave a window that never gets written.
        assertEquals(2, MediaUploadPlan.skipCount(listOf(true, true, false, true, true)))
    }

    // ---- The seal-stability guard --------------------------------------------------------------

    @Test fun windows_we_wrote_from_these_bytes_may_be_skipped() {
        val fp = MediaUploadPlan.sealFingerprint(ByteArray(64) { it.toByte() })
        assertEquals(20, MediaUploadPlan.trustedPrefix(force = false, recordedFp = fp, currentFp = fp,
            recordedWindows = 20, total = 75))
    }

    @Test fun a_reseal_of_the_SAME_LENGTH_must_not_be_resumed_across() {
        // The trap: sealing carries a fresh nonce, so re-sealing the same plaintext to the same
        // recipients produces bytes that DIFFER while the length matches exactly. Resuming across that
        // boundary yields a blob of precisely the right size that decrypts to nothing.
        val first = ByteArray(1024) { 7 }
        val resealed = ByteArray(1024) { 7 }.also { it[0] = 9 }   // same length, different bytes
        assertEquals(first.size, resealed.size)
        val a = MediaUploadPlan.sealFingerprint(first)
        val b = MediaUploadPlan.sealFingerprint(resealed)
        assertNotEquals("a same-length re-seal must not fingerprint the same", a, b)
        assertEquals(0, MediaUploadPlan.trustedPrefix(force = false, recordedFp = a, currentFp = b,
            recordedWindows = 40, total = 75))
    }

    @Test fun a_destination_we_have_never_uploaded_to_gets_everything() {
        // Covers the first attempt AND the case that a probe alone would get wrong: ANOTHER device of
        // this account uploaded the same ref. Same plaintext, same ref, a completely different seal —
        // its windows all probe present, and trusting them would splice two seals together.
        val fp = MediaUploadPlan.sealFingerprint(ByteArray(8))
        assertEquals(0, MediaUploadPlan.trustedPrefix(force = false, recordedFp = null, currentFp = fp,
            recordedWindows = 0, total = 75))
    }

    @Test fun trust_never_exceeds_the_windows_that_exist() {
        // A record left over from a LARGER earlier blob must not authorise skipping past the end.
        val fp = MediaUploadPlan.sealFingerprint(ByteArray(8))
        assertEquals(3, MediaUploadPlan.trustedPrefix(force = false, recordedFp = fp, currentFp = fp,
            recordedWindows = 900, total = 3))
        assertEquals(0, MediaUploadPlan.trustedPrefix(force = false, recordedFp = fp, currentFp = fp,
            recordedWindows = -1, total = 3))
    }

    @Test fun the_recovery_overwrite_never_resumes() {
        // `force` exists to REPLACE what a destination is holding (the 1.0.7 frozen-blob repair).
        // Skipping windows it already has would leave exactly the bytes we came to overwrite.
        val fp = MediaUploadPlan.sealFingerprint(ByteArray(8))
        assertEquals(0, MediaUploadPlan.trustedPrefix(force = true, recordedFp = fp, currentFp = fp,
            recordedWindows = 40, total = 75))
    }
}
