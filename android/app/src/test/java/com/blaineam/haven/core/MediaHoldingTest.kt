package com.blaineam.haven.core

import com.blaineam.haven.core.MediaHolding.Fetch
import com.blaineam.haven.core.MediaHolding.Head
import com.blaineam.haven.core.MediaHolding.Verdict
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * rc.3 field report: after "Load history from your relays" the phone re-downloaded every recovered
 * photo from the relay it had just downloaded it from, and recovered own posts looked unbacked.
 * Apple MediaHoldingTests parity.
 */
class MediaHoldingTest {
    private val relay = "a".repeat(64)
    private val other = "b".repeat(64)

    @Test fun restore_marks_the_serving_relay_only_on_a_complete_opened_download() {
        assertEquals(relay, MediaHolding.holderToRecord(relay, complete = true, opened = true))
        assertEquals("s3:bucket", MediaHolding.holderToRecord("s3:bucket", complete = true, opened = true))
        assertNull("partial", MediaHolding.holderToRecord(relay, complete = false, opened = true))
        assertNull("undecryptable", MediaHolding.holderToRecord(relay, complete = true, opened = false))
        assertNull(MediaHolding.holderToRecord(null, complete = true, opened = true))
    }

    private class FakeRelay {
        val store = HashMap<String, ByteArray>()
        var speaksHead = true
        var heads = 0
        val gets = ArrayList<String>()
        fun head(k: String): Head { heads++; return if (!speaksHead) Head.UNSUPPORTED else if (k in store) Head.PRESENT else Head.ABSENT }
        fun get(k: String): Fetch { gets.add(k); return store[k]?.let { Fetch.Data(it) } ?: Fetch.Miss }
    }
    private val magic = "HVCHUNK1\n".toByteArray()
    private fun manifest(n: Int) = magic + "{\"chunks\":$n}".toByteArray()
    private fun chunks(b: ByteArray): Int? =
        if (b.size > magic.size && b.copyOf(magic.size).contentEquals(magic))
            Regex("\"chunks\":(\\d+)").find(String(b))?.groupValues?.get(1)?.toInt() else null
    private fun probe(r: FakeRelay) = runBlocking {
        MediaHolding.probe("m", { "m.p/$it" }, { r.head(it) }, { r.get(it) }, { chunks(it) })
    }

    @Test fun probe_of_an_unchunked_photo_downloads_nothing() {
        val r = FakeRelay().apply { store["m"] = ByteArray(3_000_000) }
        val p = probe(r)
        assertEquals(Verdict.COMPLETE, p.verdict)
        assertEquals(0, p.fullGets)
        assertTrue("the old probe GET the whole photo", r.gets.isEmpty())
    }

    @Test fun probe_of_a_chunked_blob_reads_only_the_manifest() {
        val r = FakeRelay().apply { store["m"] = manifest(3); for (i in 0 until 3) store["m.p/$i"] = ByteArray(8) }
        val p = probe(r)
        assertEquals(Verdict.COMPLETE, p.verdict)
        assertEquals(listOf("m"), r.gets)
    }

    @Test fun probe_still_catches_a_missing_tail() {
        val r = FakeRelay().apply { store["m"] = manifest(3); store["m.p/0"] = ByteArray(8) }
        assertEquals(Verdict.INCOMPLETE, probe(r).verdict)
    }

    @Test fun absent_is_one_head() {
        val r = FakeRelay()
        assertEquals(Verdict.ABSENT, probe(r).verdict)
        assertEquals(1, r.heads)
        assertTrue(r.gets.isEmpty())
    }

    @Test fun a_relay_without_head_falls_back_to_the_old_get_probe() {
        val r = FakeRelay().apply { speaksHead = false; store["m"] = ByteArray(10) }
        val p = probe(r)
        assertEquals(Verdict.COMPLETE, p.verdict)
        assertEquals(1, p.fullGets)
    }

    @Test fun refusal_is_not_absence() = runBlocking {
        assertEquals(Verdict.REFUSED, MediaHolding.probe("m", { "$it" }, { Head.REFUSED }, { Fetch.Miss }, { null }).verdict)
        assertEquals(Verdict.REFUSED, MediaHolding.probe("m", { "$it" }, { Head.UNSUPPORTED }, { Fetch.Refused }, { null }).verdict)
        assertEquals(Verdict.UNREACHABLE, MediaHolding.probe("m", { "$it" }, { Head.UNREACHABLE }, { Fetch.Miss }, { null }).verdict)
    }

    @Test fun backfill_skips_refs_the_ledger_confirms_on_every_wanted_relay() {
        assertFalse(MediaHolding.needsBackfill(listOf(relay), setOf(relay), heldRemotely = true))
        assertTrue("a second relay still gets its copy", MediaHolding.needsBackfill(listOf(relay, other), setOf(relay), heldRemotely = true))
        assertTrue(MediaHolding.needsBackfill(listOf(relay), emptySet(), heldRemotely = false))
        assertFalse(MediaHolding.needsBackfill(emptyList(), setOf(other), heldRemotely = true))
    }

    @Test fun mirror_classification() {
        assertTrue(MediaHolding.isBackgroundMirror(false, heldRemotely = false))
        assertTrue(MediaHolding.isBackgroundMirror(null, heldRemotely = false))
        assertTrue("my post already on a relay", MediaHolding.isBackgroundMirror(true, heldRemotely = true))
        assertFalse("my only copy", MediaHolding.isBackgroundMirror(true, heldRemotely = false))
    }
}
