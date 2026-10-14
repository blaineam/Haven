package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import java.io.File
import java.security.MessageDigest

/**
 * Peer-to-peer media over frames 3 / 5: the receive side reassembling 32 KB sealed chunks that arrive out of order
 * (every field bounds-checked, because they are peer-controlled), and the serve side streaming a held blob chunk by
 * chunk. The wire transport itself needs the iroh node; what is checked is what is sealed and what is stored.
 */
class HavenNetMediaChunksTest {
    private val env = NetEnv()
    private val peer = "c3".repeat(32)
    private val chunk = 32 * 1024
    private val plain = ByteArray(chunk * 2 + 4464) { (it * 31 % 251).toByte() }   // 3 chunks
    private lateinit var ref: String
    private val refBytes get() = ref.toByteArray()
    private val tag = "HVE1".toByteArray()

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
    private fun piece(i: Int) = plain.copyOfRange(i * chunk, minOf(plain.size, (i + 1) * chunk))
    private fun frame(i: Int, total: Int = 3, r: String = ref, body: ByteArray = piece(i)) =
        ChunkFrame.encode(r.toByteArray(), i, total, byteArrayOf(7) + body)
    private fun deliver(f: ByteArray) = NetEnv.call("handleMediaChunk", f)
    @Suppress("UNCHECKED_CAST") private fun incoming() = NetEnv.field("incomingMedia").get(HavenNet) as MutableMap<String, *>

    @Before fun setUp() {
        env.up()
        ReassemblyStore.init(env.ctx)
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 1u))
        env.social.openPeer = { s -> if (s.isNotEmpty() && s[0] == 7.toByte()) s.copyOfRange(1, s.size) else null }
        env.social.sealPeer = { _, d -> byteArrayOf(7) + d }
        env.social.sealFile = { _, i, o -> File(o).writeBytes(tag + File(i).readBytes()); true }
        env.social.sealMedia = { _, d -> tag + d }
        ref = "img_" + sha(plain)
    }
    @After fun tearDown() { env.down() }

    // ---- receive ------------------------------------------------------------------------------------

    @Test fun chunks_arriving_out_of_order_reassemble_into_the_stored_blob() {
        deliver(frame(2))
        deliver(frame(0))
        assertFalse("not complete yet", LocalMedia.has(ref))
        assertEquals(1, incoming().size)
        deliver(frame(1))
        assertTrue(LocalMedia.has(ref))
        assertArrayEquals(tag + plain, LocalMedia.rawSealed(ref))
        assertTrue("the reassembly is over", incoming().isEmpty())
    }

    @Test fun a_duplicate_chunk_is_harmless_and_a_finished_blob_ignores_late_chunks() {
        deliver(frame(0)); deliver(frame(0))
        assertEquals(1, incoming().size)
        deliver(frame(1)); deliver(frame(2))
        assertTrue(LocalMedia.has(ref))
        deliver(frame(0))
        assertTrue("already held: the late chunk starts nothing", incoming().isEmpty())
    }

    @Test fun peer_controlled_fields_are_bounds_checked_before_they_size_anything() {
        deliver(ChunkFrame.encode(refBytes, 0, 0, byteArrayOf(7, 1)))                        // no chunks
        deliver(ChunkFrame.encode(refBytes, 0, MediaResume.MAX_CHUNKS + 1, byteArrayOf(7, 1)))
        deliver(ChunkFrame.encode(refBytes, 3, 3, byteArrayOf(7, 1)))                        // index past the end
        deliver(ChunkFrame.encode(refBytes, -1, 3, byteArrayOf(7, 1)))
        deliver(ChunkFrame.encode(ByteArray(0), 0, 3, byteArrayOf(7, 1)))                    // no ref
        deliver(ChunkFrame.encode(refBytes, 0, 3, byteArrayOf(9, 1)))                        // does not open
        deliver(ChunkFrame.encode(refBytes, 0, 3, byteArrayOf(7)))                           // opens to nothing
        deliver(ChunkFrame.encode(refBytes, 0, 3, byteArrayOf(7) + ByteArray(chunk + 1)))    // would spill into the next slot
        deliver(byteArrayOf(1))                                                              // too short for a header
        assertTrue(incoming().isEmpty())
        assertFalse(LocalMedia.has(ref))
    }

    @Test fun a_sender_that_changes_the_total_mid_transfer_starts_the_reassembly_clean() {
        deliver(frame(0, total = 3))
        deliver(frame(0, total = 5))
        val entry = incoming().values.single()!!
        val got = entry.javaClass.getDeclaredField("got").apply { isAccessible = true }.get(entry) as Set<*>
        assertEquals("the old partial's indices pointed at a different file", setOf(0), got)
    }

    @Test fun bytes_that_do_not_account_for_the_ref_are_rejected_when_complete() {
        val wrongRef = "img_" + "ab".repeat(32)
        for (i in 0..2) deliver(frame(i, r = wrongRef))
        assertFalse(LocalMedia.has(wrongRef))
        assertTrue("and the reassembly record is gone with the part file", incoming().isEmpty())
    }

    @Test fun a_bad_write_position_cannot_corrupt_a_neighbour() {
        deliver(frame(1))
        val entry = incoming().values.single()!!
        val part = entry.javaClass.getDeclaredField("part").apply { isAccessible = true }.get(entry) as File
        assertEquals("written at its own offset, nothing before it", (chunk * 2).toLong(), part.length())
    }

    // ---- serve --------------------------------------------------------------------------------------

    private fun serve(file: File, missing: Set<Int>? = null) =
        NetEnv.call("sendMediaChunks", ref, file, peer, missing)

    @Test fun a_held_blob_is_sealed_to_the_requester_one_chunk_at_a_time() {
        val f = File(env.ctx.filesDir, "plain.bin").apply { writeBytes(plain) }
        serve(f)
        assertEquals(listOf(chunk, chunk, 4464), env.social.sealedPeer.map { it.second })
        assertTrue(env.social.sealedPeer.all { it.first == peer })
    }

    @Test fun a_resume_request_serves_only_the_holes() {
        val f = File(env.ctx.filesDir, "plain.bin").apply { writeBytes(plain) }
        serve(f, missing = setOf(2))
        assertEquals(listOf(4464), env.social.sealedPeer.map { it.second })
    }

    @Test fun a_seal_failure_abandons_the_transfer_rather_than_sending_garbage() {
        env.social.sealPeer = { _, _ -> null }
        env.social.sealedPeer.clear()
        val f = File(env.ctx.filesDir, "plain.bin").apply { writeBytes(plain) }
        serve(f)
        assertEquals("stopped at the first failure", 1, env.social.sealedPeer.size)
    }

    @Test fun serving_an_empty_file_still_counts_as_one_chunk() {
        val f = File(env.ctx.filesDir, "empty.bin").apply { writeBytes(ByteArray(0)) }
        serve(f)
        assertTrue(env.social.sealedPeer.isEmpty())
    }
}
