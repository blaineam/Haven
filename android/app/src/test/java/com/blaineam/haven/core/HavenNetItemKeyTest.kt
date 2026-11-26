package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import com.blaineam.haven.core.HistoryHandoffWire as HW

/** Reading one blob's key off the relays (D27): the end of the blob, the whole blob only when the
 *  end is not enough, and never "missing" while something did not answer. */
class HavenNetItemKeyTest {
    private val env = NetEnv()
    private val tail = HW.KEY_TAIL_BYTES
    /** The stand-in for the engine: the key is in the bytes when they hold the 4-byte marker. */
    private val marker = byteArrayOf(0x4B, 0x45, 0x59, 0x21)
    private val unwrapped = mutableListOf<Int>()
    private fun unwrap(bytes: ByteArray): ByteArray? {
        unwrapped.add(bytes.size)
        val found = (0..bytes.size - marker.size).any { i -> marker.indices.all { bytes[i + it] == marker[it] } }
        return if (found) byteArrayOf(42) else null
    }

    private fun blob(size: Int, markerAt: Int) = ByteArray(size).also { marker.copyInto(it, markerAt) }
    private fun find(ref: String) = runBlocking { HavenNet.findItemKey("default", ref, ::unwrap) }
    private fun gets() = env.relay.hits.filter { it.method == "GET" && it.path.startsWith("/k/") }

    @Before fun setUp() { env.up(); env.bindCircleRelay("default") }
    @After fun tearDown() { env.down() }

    @Test fun only_the_end_of_a_blob_is_read() {
        env.relay.store["haven/media/img_a"] = blob(300_000, 299_000)
        val r = find("img_a")
        assertArrayEquals(byteArrayOf(42), (r as ItemKeyResult.Found).entry)
        assertEquals(listOf("bytes=-$tail"), gets().map { it.range })
        assertEquals(listOf(tail), unwrapped)
    }

    @Test fun a_key_outside_the_tail_falls_back_to_the_whole_blob() {
        env.relay.store["haven/media/img_a"] = blob(300_000, 10)
        assertTrue(find("img_a") is ItemKeyResult.Found)
        assertEquals(listOf("bytes=-$tail", null), gets().map { it.range })
        assertEquals(listOf(tail, 300_000), unwrapped)
    }

    @Test fun a_relay_without_ranges_sends_the_whole_blob_once() {
        env.relay.honorsRange = false
        env.relay.store["haven/media/img_a"] = blob(300_000, 10)
        assertTrue(find("img_a") is ItemKeyResult.Found)
        assertEquals(1, gets().size)
    }

    @Test fun a_short_last_chunk_takes_the_end_of_the_one_before() {
        env.relay.store["haven/media/vid_b"] = HavenKeys.makeManifest(listOf(200_000, 900))
        env.relay.store[HavenKeys.mediaChunkKey("vid_b", 0)] = blob(200_000, 199_000)
        env.relay.store[HavenKeys.mediaChunkKey("vid_b", 1)] = ByteArray(900)
        assertTrue(find("vid_b") is ItemKeyResult.Found)
        assertEquals(listOf(tail), unwrapped)
        assertTrue("every read asked for a tail", gets().all { it.range == "bytes=-$tail" })
        assertEquals(3, gets().size)
    }

    @Test fun a_chunked_blob_falls_back_to_all_of_its_chunks() {
        env.relay.store["haven/media/vid_b"] = HavenKeys.makeManifest(listOf(200_000, 900))
        env.relay.store[HavenKeys.mediaChunkKey("vid_b", 0)] = blob(200_000, 10)
        env.relay.store[HavenKeys.mediaChunkKey("vid_b", 1)] = ByteArray(900)
        assertTrue(find("vid_b") is ItemKeyResult.Found)
        assertEquals(listOf(tail, 200_900), unwrapped)
    }

    @Test fun a_blob_the_relay_does_not_hold_is_missing() {
        assertEquals(ItemKeyResult.Missing, find("img_none"))
        env.relay.store["haven/media/img_other"] = ByteArray(1000)
        assertEquals("held, but sealed without my account", ItemKeyResult.Missing, find("img_other"))
    }

    @Test fun a_relay_that_did_not_answer_never_makes_a_blob_missing() {
        env.relay.forceStatus = 500
        assertEquals(ItemKeyResult.Unreachable, find("img_a"))
        // Its address is now parked as failing: not asking it is not it lacking the blob.
        env.relay.forceStatus = null
        assertEquals(ItemKeyResult.Unreachable, find("img_a"))
        assertEquals(1, gets().size)
    }

    @Test fun a_refusal_is_not_a_miss_and_a_standing_down_relay_is_not_asked() {
        env.relay.forceStatus = 403
        repeat(4) { assertEquals(ItemKeyResult.Unreachable, find("img_a")) }
        val asked = gets().size
        assertEquals("the refusing relay is left alone, and still counts as unanswered",
            ItemKeyResult.Unreachable, find("img_a"))
        assertEquals(asked, gets().size)
    }

    @Test fun with_no_destination_at_all_nothing_is_given_up() {
        env.entries().clear()
        HavenNet.setDefaultRelay(null)
        (NetEnv.field("relayNodes").get(HavenNet) as MutableMap<*, *>).clear()
        assertEquals(ItemKeyResult.Unreachable, find("img_a"))
    }

    @Test fun a_second_relay_that_holds_the_blob_answers_for_a_dead_one() {
        val other = FakeRelayServer().start()
        try {
            val hex = "cd".repeat(32)
            env.addRelay(hex, other.base)
            env.bindCircleRelay("default", hex)
            env.relay.forceStatus = 500
            other.store["haven/media/img_a"] = blob(100, 5)
            assertTrue(find("img_a") is ItemKeyResult.Found)
            assertEquals("one dead relay still holds a blob nobody else has", ItemKeyResult.Unreachable, find("img_z"))
        } finally {
            other.stop()
        }
    }

    @Test fun a_blob_too_big_to_hold_is_never_pulled_whole() {
        env.relay.store["haven/media/vid_b"] = HavenKeys.makeManifest(listOf(200_000, 200_000))
        env.relay.store[HavenKeys.mediaChunkKey("vid_b", 0)] = blob(200_000, 10)
        env.relay.store[HavenKeys.mediaChunkKey("vid_b", 1)] = ByteArray(200_000)
        val reader = object : ItemKeyLookup.Reader {
            override suspend fun tail(key: String) =
                HavenNet.relayHttpGetTail(env.relay.base, env.token, key).getOrThrow()
            override suspend fun whole(key: String) =
                HavenNet.relayHttpGet(env.relay.base, env.token, key).getOrThrow()
        }
        assertEquals(null, runBlocking { ItemKeyLookup.fromDestination(reader, "vid_b", 250_000L, ::unwrap) })
        assertTrue(unwrapped.all { it <= 200_000 })
    }
}
