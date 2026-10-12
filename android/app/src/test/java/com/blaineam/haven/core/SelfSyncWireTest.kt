package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The self-sync byte encodings (must match iOS) and the removed-vs-re-added LWW resolution. */
class SelfSyncWireTest {
    private val W = SelfSyncWire
    private fun ts(v: Long) = W.int64LE(v)

    @Test fun int64_is_little_endian_and_round_trips() {
        assertArrayEquals(byteArrayOf(1, 0, 0, 0, 0, 0, 0, 0), W.int64LE(1))
        assertArrayEquals(byteArrayOf(0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0), W.int64LE(0x12345678L))
        for (v in listOf(0L, 1L, 1_760_000_000_000L, Long.MAX_VALUE)) assertEquals(v, W.int64LEValue(W.int64LE(v)))
    }

    @Test fun int32_is_little_endian_and_round_trips_including_negatives() {
        assertArrayEquals(byteArrayOf(0x44, 0x33, 0x22, 0x11), W.int32LE(0x11223344))
        for (v in listOf(0, 7, 365, -1, Int.MIN_VALUE, Int.MAX_VALUE)) assertEquals(v, W.int32LEValue(W.int32LE(v)))
    }

    @Test fun bool_is_one_byte_and_empty_means_absent() {
        assertEquals(true, W.boolValue(byteArrayOf(1)))
        assertEquals(false, W.boolValue(byteArrayOf(0)))
        assertNull(W.boolValue(byteArrayOf())); assertNull(W.boolValue(null))
    }

    @Test fun hex_round_trips_and_rejects_bad_input() {
        val b = byteArrayOf(0, 1, 0x7f, -1, -128)
        assertEquals("00017fff80", W.toHex(b))
        assertArrayEquals(b, W.fromHex("00017FFF80"))
        assertNull(W.fromHex("abc")); assertNull(W.fromHex("zz"))
        assertArrayEquals(byteArrayOf(), W.fromHex(""))
    }

    @Test fun contact_encoding_round_trips_and_garbage_is_null() {
        val c = Contact("ab".repeat(32), "Ana \"A\" Ramos", "verify-1")
        assertEquals(c, W.decodeContact(W.encodeContact(c)))
        assertNull(W.decodeContact("nope".toByteArray()))
        assertNull(W.decodeContact("{\"name\":\"no id\"}".toByteArray()))
        assertEquals(Contact("x", "", ""), W.decodeContact("{\"id_hex\":\"x\"}".toByteArray()))
    }

    private fun resolve(vararg e: Pair<String, ByteArray>, tie: Boolean = true, legacy: String? = null,
                        norm: (String) -> String = { it }) =
        W.resolve(e.toList(), "rm:", "add:", tie, legacy, norm).associateBy { it.id }

    @Test fun newest_side_wins_per_id() {
        val r = resolve("rm:a" to ts(10), "add:a" to ts(20), "rm:b" to ts(30), "add:b" to ts(5))
        assertEquals(SelfSyncWire.Resolved("a", 20, false), r["a"])
        assertEquals(SelfSyncWire.Resolved("b", 30, true), r["b"])
    }

    @Test fun an_exact_tie_goes_to_the_removal_or_the_readd_as_asked() {
        val e = arrayOf("rm:a" to ts(10), "add:a" to ts(10))
        assertEquals(true, resolve(*e, tie = true)["a"]!!.removed)
        assertEquals(false, resolve(*e, tie = false)["a"]!!.removed)
    }

    @Test fun one_sided_records_resolve_and_zero_timestamps_do_not() {
        val r = resolve("rm:only-removed" to ts(4), "add:only-added" to ts(6), "rm:zero" to ts(0))
        assertEquals(true, r["only-removed"]!!.removed)
        assertEquals(false, r["only-added"]!!.removed)
        assertTrue("a zero timestamp says nothing", "zero" !in r)
    }

    @Test fun malformed_records_are_ignored() {
        val r = resolve("rm:short" to byteArrayOf(1, 2, 3), "rm:" to ts(9), "add:long" to ByteArray(9), "other:x" to ts(1))
        assertTrue(r.isEmpty())
    }

    @Test fun duplicate_keys_keep_the_max_timestamp() {
        val r = resolve("rm:a" to ts(10), "rm:a" to ts(40), "add:a" to ts(20))
        assertEquals(SelfSyncWire.Resolved("a", 40, true), r["a"])
    }

    @Test fun legacy_one_byte_records_lose_to_any_real_write() {
        val legacy = "removal:"
        // legacy removal (ts=1) vs a real re-add -> re-add wins
        assertEquals(false, resolve("removal:a" to byteArrayOf(1), "add:a" to ts(5), legacy = legacy)["a"]!!.removed)
        // legacy re-add (0) vs a real removal -> removal wins
        assertEquals(true, resolve("removal:a" to byteArrayOf(0), "rm:a" to ts(5), legacy = legacy)["a"]!!.removed)
        // a legacy removal alone is honoured
        assertEquals(SelfSyncWire.Resolved("a", 1, true), resolve("removal:a" to byteArrayOf(1), legacy = legacy)["a"])
        // legacy records are ignored when the caller doesn't ask for them
        assertTrue(resolve("removal:a" to byteArrayOf(1)).isEmpty())
    }

    @Test fun severance_ids_fold_member_case_and_split_safely() {
        assertEquals("circ|abcdef", W.normalizeSeveranceId("circ|ABCDEF"))
        assertEquals("nobar", W.normalizeSeveranceId("nobar"))
        val r = resolve("rm:c|AB" to ts(3), "add:c|ab" to ts(9), norm = W::normalizeSeveranceId)
        assertEquals(SelfSyncWire.Resolved("c|ab", 9, false), r["c|ab"])
        assertEquals("c" to "ab", W.splitSeveranceId("c|ab"))
        assertNull(W.splitSeveranceId("|ab")); assertNull(W.splitSeveranceId("c|")); assertNull(W.splitSeveranceId("nobar"))
    }
}
