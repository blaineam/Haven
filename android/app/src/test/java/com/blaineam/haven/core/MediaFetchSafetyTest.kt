package com.blaineam.haven.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * The guards that keep one fetch of a ref from getting it quarantined: single-flight per ref, an
 * empty body as a miss, and atomic replacement on disk (desktop 85dd646b, ported).
 */
class MediaFetchSafetyTest {
    /** Two lanes fetching the same ref at once must cost ONE download, and both get its answer. */
    @Test fun concurrent_callers_for_one_ref_share_a_single_run() = runTest {
        val flights = SingleFlight<Boolean>()
        val runs = AtomicInteger()
        val gate = CompletableDeferred<Unit>()
        val callers = (0 until 3).map {
            async { flights.run("abc") { runs.incrementAndGet(); gate.await(); true } }
        }
        yield()
        assertTrue(flights.inFlight("abc"))
        gate.complete(Unit)
        assertEquals(listOf(true, true, true), callers.awaitAll())
        assertEquals("joiners must await the leader, not download again", 1, runs.get())
        assertFalse("a finished run must not be joined later", flights.inFlight("abc"))
    }

    /** A cancelled leader (the prefetch timeout) must never wedge the ref: the waiter runs itself. */
    @Test fun a_cancelled_leader_hands_its_waiter_its_own_turn() = runTest {
        val flights = SingleFlight<Boolean>()
        val runs = AtomicInteger()
        val leader = launch { flights.run("abc") { runs.incrementAndGet(); CompletableDeferred<Unit>().await(); true } }
        yield()
        val waiter = async { flights.run("abc") { runs.incrementAndGet(); true } }
        yield()
        leader.cancel(CancellationException("prefetch timed out"))
        assertTrue(waiter.await())
        assertEquals(2, runs.get())
        assertFalse(flights.inFlight("abc"))
    }

    @Test fun different_refs_do_not_wait_on_each_other() = runTest {
        val flights = SingleFlight<Int>()
        val gate = CompletableDeferred<Unit>()
        val slow = async { flights.run("slow") { gate.await(); 1 } }
        yield()
        assertEquals(2, flights.run("fast") { 2 })
        gate.complete(Unit)
        assertEquals(1, slow.await())
    }

    /** "found (0B) but OPEN FAILED": an empty body writes nothing and reports a miss. */
    @Test fun empty_body_is_a_miss_not_a_stored_copy() {
        val dir = Files.createTempDirectory("haven-media").toFile()
        val dst = java.io.File(dir, "beef")
        assertFalse(MediaFiles.writeAtomic(dst, ByteArray(0)))
        assertFalse("an empty relay body must not become a held (\"corrupt\") blob", dst.exists())
        assertTrue(MediaFiles.writeAtomic(dst, "sealed".toByteArray()))
        assertArrayEquals("sealed".toByteArray(), dst.readBytes())
        assertEquals(listOf("beef"), dir.list()!!.toList())
        dir.deleteRecursively()
    }

    /** The satellite-preview race: a reader polling the blob while writers rewrite it must only
     *  ever see it whole — never truncated, never missing — and no scratch may be left behind. */
    @Test fun raw_write_is_atomic_under_concurrent_writers() {
        val dir = Files.createTempDirectory("haven-media").toFile()
        val dst = java.io.File(dir, "cafef00d")
        val blob = ByteArray(64 * 1024) { 0x5a }
        assertTrue(MediaFiles.writeAtomic(dst, blob))
        val stop = AtomicBoolean(false)
        val failures = AtomicInteger()
        val writers = (0 until 3).map {
            Thread { while (!stop.get()) if (!MediaFiles.writeAtomic(dst, blob)) failures.incrementAndGet() }
        }
        writers.forEach { it.start() }
        repeat(2000) {
            assertEquals("a reader saw a truncated or missing blob", blob.size, dst.readBytes().size)
        }
        stop.set(true)
        writers.forEach { it.join() }
        assertEquals(0, failures.get())
        assertEquals(listOf("cafef00d"), dir.list()!!.toList())
        dir.deleteRecursively()
    }

    /** Adopting a reassembled part replaces the target in one step and consumes the part. */
    @Test fun replace_moves_the_part_over_an_existing_blob() {
        val dir = Files.createTempDirectory("haven-media").toFile()
        val dst = java.io.File(dir, "abc").apply { writeBytes("old seal".toByteArray()) }
        val part = MediaFiles.scratchFor(dst, "part").apply { writeBytes("new seal".toByteArray()) }
        assertTrue(part.name.startsWith("incoming_"))
        assertTrue(MediaFiles.replace(dst, part))
        assertArrayEquals("new seal".toByteArray(), dst.readBytes())
        assertFalse(part.exists())
        dir.deleteRecursively()
    }
}
