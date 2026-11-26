package com.blaineam.haven.core

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import com.blaineam.haven.core.HistoryHandoffWire as HW

/** The bytes Android shares with Apple `HistoryHandoffWire.swift` and core `historyhandoff.rs` /
 *  `mediakeys.rs`. */
class HistoryHandoffWireTest {
    private val acct = "AB".repeat(32)

    @Test fun every_key_sits_on_the_own_account_lane_in_lower_case() {
        val lane = "haven/self/${"ab".repeat(32)}/"
        assertEquals("${lane}history-req/cd", HW.requestKey(acct, "CD"))
        assertEquals("${lane}history-m/cd/ef", HW.manifestKey(acct, "CD", "EF"))
        assertEquals("${lane}history/cd/ef/17/3", HW.pageKey(acct, "CD", "EF", "17", 3))
        assertEquals("${lane}history-need/cd/ef/17/", HW.needPrefix(acct, "CD", "EF", "17"))
        assertEquals("${lane}history/cd/ef/17/m/img_a_b/2", HW.mediaChunkKey(acct, "CD", "EF", "17", "img:a.b", 2))
        assertEquals("${lane}history/cd/ef/17/mready/4", HW.mediaReadyKey(acct, "CD", "EF", "17", 4))
        assertEquals("${lane}media-keys-req/cd", HW.keysRequestKey(acct, "CD"))
        assertEquals("${lane}media-keys-m/cd/ef", HW.keysManifestKey(acct, "CD", "EF"))
        assertEquals("${lane}media-keys/cd/ef/7/0", HW.keysBatchKey(acct, "CD", "EF", "7", 0))
        assertEquals("__etc", HW.keySafe("..etc"))
    }

    @Test fun a_page_is_apples_bytes() {
        val page = HW.encodePage("fam", listOf(byteArrayOf(4, 1)), listOf(HW.MediaItem("img_a", 258)))
        val expected = "HVH2".toByteArray() + byteArrayOf(3, 0) + "fam".toByteArray() +
            byteArrayOf(1, 0, 0, 0, 2, 0, 0, 0, 4, 1, 1, 0, 0, 0, 5, 0) + "img_a".toByteArray() +
            byteArrayOf(2, 1, 0, 0, 0, 0, 0, 0)
        assertArrayEquals(expected, page)
        val back = HW.decodePage(page)!!
        assertEquals("fam", back.circleId)
        assertArrayEquals(byteArrayOf(4, 1), back.envelopes.single())
        assertEquals(listOf(HW.MediaItem("img_a", 258)), back.media)
        for (cut in 0 until page.size) assertNull("cut at $cut", HW.decodePage(page.copyOf(cut)))
        assertNull(HW.decodePage("NOPE000000".toByteArray()))
    }

    @Test fun records_use_the_shared_field_names() {
        val m = HW.Manifest("17", "ab", 5, 3, false, 9, 40, 12)
        val o = JSONObject(String(m.encode()))
        assertEquals(setOf("v", "run", "source", "forRequest", "pages", "complete", "updatedAt", "totalEvents",
            "servedEvents"), o.keys().asSequence().toSet())
        assertEquals(m, HW.Manifest.decode(m.encode()))
        // The core writes no field it does not have.
        val r = HW.Request.decode("""{"v":1,"device":"dd","at":1764000000000,"roster":"AAEC"}""".toByteArray())!!
        assertEquals(1_764_000_000_000L, r.at)
        assertNull(r.done); assertNull(r.cancelled)
        assertEquals("AAEC", r.roster)
        assertEquals(true, HW.Request.decode("""{"v":1,"device":"d","at":1,"done":true}""".toByteArray())!!.done)
        assertNull(HW.Request.decode("not json".toByteArray()))
        assertEquals(HW.KeysRequest("d", 2), HW.KeysRequest.decode("""{"v":1,"device":"d","at":2}""".toByteArray()))
        val k = HW.KeysManifest("1", "s", 2, 3, true, 4, 5, 6, 7)
        assertEquals(setOf("v", "run", "source", "forRequest", "batches", "complete", "updatedAt", "total",
            "done", "missing"), JSONObject(String(k.encode())).keys().asSequence().toSet())
        assertEquals(k, HW.KeysManifest.decode(k.encode()))
    }

    @Test fun blob_refs_expand_every_marker_once_and_skip_pins() {
        val entries = listOf("vid_v", "poster:vid_v:img_p", "thumb:img_a:img_t", "preview:img_a:img_w",
            "orig:vid_v:vid_o", "geo:1,2,Home", "img_a")
        assertEquals(listOf("vid_v", "img_p", "img_a", "img_t", "img_w", "vid_o"), HW.blobRefs(entries))
    }

    @Test fun the_tail_of_a_chunked_blob_spans_a_short_last_chunk() {
        val before = ByteArray(HW.KEY_TAIL_BYTES * 2) { 1 }
        val joined = HW.joinTail(before, ByteArray(100) { 2 })
        assertEquals(HW.KEY_TAIL_BYTES, joined.size)
        assertTrue(joined.copyOf(joined.size - 100).all { it == 1.toByte() })
        assertTrue(joined.copyOfRange(joined.size - 100, joined.size).all { it == 2.toByte() })
        assertEquals(HW.KEY_TAIL_BYTES, HW.joinTail(ByteArray(10), ByteArray(HW.KEY_TAIL_BYTES)).size)
        assertEquals(5, HW.joinTail(null, ByteArray(5)).size)
    }

    @Test fun a_finished_send_stops_showing_as_sending() {
        assertTrue(HW.stillSending(true, false, 0, 10))
        assertTrue(HW.stillSending(false, true, 0, 10))
        assertTrue(HW.stillSending(false, false, 1_000, 1_000 + HW.SENDING_LINGER_MS - 1))
        assertFalse(HW.stillSending(false, false, 1_000, 1_000 + HW.SENDING_LINGER_MS))
        assertFalse(HW.stillSending(false, false, 0, 10))
    }

    @Test fun a_cancel_declines_that_request_only_and_queues_the_stop_record() {
        val l = HandoffCancelLedger()
        fun req(at: Long, cancelled: Boolean? = null, done: Boolean? = null) =
            HW.Request("CD", at, done, null, cancelled)
        assertEquals(HandoffCancelLedger.Verdict.SERVE, l.verdict("cd", req(5)))
        assertEquals(HandoffCancelLedger.Verdict.CANCELLED_BY_TARGET, l.verdict("cd", req(5, cancelled = true)))
        l.cancelAsSource(acct, "EF", listOf(HandoffCancelLedger.Run("CD", 5, "9", 2, 40, 10)), false, 100)
        assertEquals(HandoffCancelLedger.Verdict.DECLINED, l.verdict("cd", req(5)))
        assertEquals("a new ask starts over", HandoffCancelLedger.Verdict.SERVE, l.verdict("cd", req(6)))
        assertEquals(HandoffCancelLedger.Verdict.FINISHED, l.verdict("cd", req(5, done = true)))
        val stop = HW.Manifest.decode(l.pending.single().body)!!
        assertEquals(true, stop.cancelled)
        assertEquals(HW.manifestKey(acct, "cd", "ef"), l.pending.single().key)
        // It survives a relaunch.
        val again = HandoffCancelLedger().apply { load(JSONObject(l.toJson().toString())) }
        assertEquals(l.declined, again.declined)
        assertEquals(l.pending, again.pending)
        assertEquals(HandoffCancelLedger.Banner.BY_THIS_DEVICE, again.banner)
    }
}
