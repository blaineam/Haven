package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * HavenNet's shared state is written by inbound handlers on IO while mailbox passes, saves and the
 * UI iterate it. As plain HashMap/HashSet/ArrayList that threw ConcurrentModificationException
 * and killed the app. These run the same shapes of access concurrently — the writer mirrors
 * handleRelayNode / forget / eraseRelay / hint learning, the readers mirror saveRelayNodes, the
 * initiated-TTL sweep, relay stats and the mailbox pass — and require that nothing throws.
 */
class SharedCollectionsTest {

    private fun hex(i: Int) = i.toString(16).padStart(64, '0')

    @Test
    fun writesDuringIterationNeverThrow() {
        val suppressed = SharedCollections.set()
        val forgotAt = SharedCollections.map<Long>()
        val hints = SharedCollections.map<List<String>>()
        val failure = AtomicReference<Throwable?>(null)
        val done = CountDownLatch(1)
        val writer = thread {
            try {
                for (i in 0 until 50_000) {
                    val h = hex(i % 257)
                    if (i % 3 == 0) { suppressed.add(h); forgotAt[h] = i.toLong() } else { suppressed.remove(h); forgotAt.remove(h) }
                    hints[h] = listOf(hex(i), hex(i + 1)).takeLast(8)
                    if (i % 1000 == 0) forgotAt.entries.removeIf { it.value < i - 500 }
                }
            } catch (t: Throwable) { failure.compareAndSet(null, t) } finally { done.countDown() }
        }
        val readers = (0 until 3).map {
            thread {
                try {
                    var sink = 0L
                    while (done.count > 0) {
                        suppressed.forEach { sink += it.length }                  // saveRelayNodes
                        for ((k, v) in forgotAt) sink += k.length + v             // tombstone export
                        for ((k, v) in hints) sink += k.length + v.size           // saveDeviceHints
                        sink += HashMap(forgotAt).size + suppressed.toList().size // snapshots
                    }
                    assertTrue(sink >= 0)
                } catch (t: Throwable) { failure.compareAndSet(null, t) }
            }
        }
        writer.join(); readers.forEach { it.join() }
        failure.get()?.let { throw AssertionError("concurrent shared-state access threw", it) }
    }

    @Test
    fun seenMarksDrainWhileAnotherPassAdds() {
        // Two overlapping mailbox passes: one flushes its seen-marks while the other still adds.
        val pending = ConcurrentLinkedQueue<String>()
        val marked = SharedCollections.set()
        val failure = AtomicReference<Throwable?>(null)
        val adder = thread {
            try { for (i in 0 until 20_000) pending.add("k$i") } catch (t: Throwable) { failure.compareAndSet(null, t) }
        }
        val flusher = thread {
            try {
                while (adder.isAlive || pending.isNotEmpty()) {
                    while (true) marked.add(pending.poll() ?: break)
                }
            } catch (t: Throwable) { failure.compareAndSet(null, t) }
        }
        adder.join(); flusher.join()
        failure.get()?.let { throw AssertionError("drain threw", it) }
        assertEquals("every mark lands exactly once — none lost to a clear", 20_000, marked.size)
        assertTrue(pending.isEmpty())
    }

    @Test
    fun synchronizedCompoundOpsStillWorkOnTheCollection() {
        // seenMailbox keeps its synchronized(seenMailbox) { add / retainAll } blocks.
        val seen = SharedCollections.set()
        val inserted = synchronized(seen) { seen.add("put:a|k") }
        val again = synchronized(seen) { seen.add("put:a|k") }
        seen.add("x/__live__/y")
        val removed = synchronized(seen) { val b = seen.size; seen.retainAll { it.contains("/__live__/") }; b - seen.size }
        assertTrue(inserted); assertTrue(!again); assertEquals(1, removed); assertEquals(setOf("x/__live__/y"), seen)
    }
}
