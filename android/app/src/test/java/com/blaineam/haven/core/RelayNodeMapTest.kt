package com.blaineam.haven.core

import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/** The relay map must survive the exact access pattern that crashed Android mid-call: `relaysFor`
 *  iterating (filter / flatten / contains) on one thread while announces add and forgets remove on
 *  another. With the old HashMap<ArrayList> this throws ConcurrentModificationException. */
class RelayNodeMapTest {
    @Test
    fun readersNeverSeeAConcurrentModificationWhileWritersMutate() {
        val map = RelayNodeMap.newMap()
        map.getOrPut("default") { RelayNodeMap.newList() }.add("a".repeat(64))
        val failure = AtomicReference<Throwable?>(null)
        val done = CountDownLatch(2)
        val writer = thread {
            try {
                repeat(20_000) { i ->
                    val hex = (i % 50).toString().padStart(64, '0')
                    val list = map.getOrPut("c${i % 5}") { RelayNodeMap.newList() }
                    if (!list.contains(hex)) list.add(hex)
                    if (i % 3 == 0) list.removeAll { it == hex }
                    if (i % 7 == 0) map.entries.removeAll { it.value.isEmpty() }
                }
            } catch (t: Throwable) { failure.compareAndSet(null, t) } finally { done.countDown() }
        }
        val reader = thread {
            try {
                repeat(20_000) { i ->
                    (map["c${i % 5}"] ?: emptyList()).filter { it.isNotEmpty() }.toMutableList()
                    map.values.flatten().distinct()
                    map.toMap().filterValues { it.contains("a".repeat(64)) }
                }
            } catch (t: Throwable) { failure.compareAndSet(null, t) } finally { done.countDown() }
        }
        done.await(); writer.join(); reader.join()
        assertTrue("concurrent read threw: ${failure.get()}", failure.get() == null)
    }
}
