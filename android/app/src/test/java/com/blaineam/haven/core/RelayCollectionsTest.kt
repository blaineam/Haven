package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * HavenNet's relay config is mutated by relay announces while mailbox passes iterate it. With a
 * plain HashMap / ArrayList that threw ConcurrentModificationException out of `relaysFor` /
 * `saveRelayNodes` and killed the app (e2e gate 2026-09-30). These run the same shapes of access
 * — the writer mirrors handleRelayNode / eraseRelayNow, the readers mirror relaysFor,
 * allRelays and saveRelayNodes — concurrently and require that nothing throws.
 */
class RelayCollectionsTest {

    private fun hex(i: Int) = i.toString(16).padStart(64, '0')

    @Test
    fun announcesDuringReadsNeverThrow() {
        val nodes = RelayCollections.associations()
        val suppressed = RelayCollections.set()
        val forgotAt = RelayCollections.map<Long>()
        val failure = AtomicReference<Throwable?>(null)
        val stop = CountDownLatch(1)
        val writer = thread {
            try {
                for (i in 0 until 20_000) {
                    val cid = "c${i % 7}"
                    val list = nodes.getOrPut(cid) { RelayCollections.list() }
                    val h = hex(i % 13)
                    if (!list.contains(h)) list.add(h)
                    if (i % 5 == 0) list.remove(hex((i + 3) % 13))
                    if (i % 11 == 0) { suppressed.add(h); forgotAt[h] = i.toLong() }
                    if (i % 17 == 0) { suppressed.remove(h); forgotAt.remove(h) }
                    if (i % 97 == 0) {
                        for (l in nodes.values) l.removeIf { it == h }
                        nodes.entries.removeIf { it.value.isEmpty() }
                    }
                }
            } catch (t: Throwable) { failure.compareAndSet(null, t) } finally { stop.countDown() }
        }
        val readers = (0 until 3).map {
            thread {
                try {
                    while (stop.count > 0) {
                        // relaysFor
                        (nodes["c3"] ?: emptyList()).filter { it !in suppressed }.toMutableList()
                        // allRelays
                        nodes.values.flatten().distinct()
                        // saveRelayNodes
                        nodes.forEach { (_, v) -> v.forEach { it.length } }
                        suppressed.forEach { it.length }
                        forgotAt.forEach { (k, v) -> k.length + v }
                    }
                } catch (t: Throwable) { failure.compareAndSet(null, t) }
            }
        }
        writer.join(); readers.forEach { it.join() }
        failure.get()?.let { throw AssertionError("concurrent relay-config access threw", it) }
    }

    @Test
    fun listsKeepInsertionOrderAndRemoveIfIsExact() {
        val nodes = RelayCollections.associations()
        val list = nodes.getOrPut("c") { RelayCollections.list() }
        list.add("b"); list.add("a"); list.add("c")
        assertEquals(listOf("b", "a", "c"), nodes["c"])
        list.removeIf { it == "a" }
        assertEquals(listOf("b", "c"), nodes["c"])
        list.removeIf { true }
        nodes.entries.removeIf { it.value.isEmpty() }
        assertTrue(nodes.isEmpty())
    }
}
