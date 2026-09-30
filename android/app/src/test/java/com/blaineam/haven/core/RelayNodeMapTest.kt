package com.blaineam.haven.core

import org.junit.Assert.assertEquals
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
                    if (i % 3 == 0) RelayNodeMap.removeRelay(list, hex)
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

    private val acct = "f".repeat(64)
    private val device = "d".repeat(64)

    @Test
    fun aDeadAccountIdEntryIsSupersededByALearnedDeviceRelay() {
        val out = RelayNodeMap.supersededAccountRelays(listOf(acct), device, setOf(acct)) { false }
        assertEquals(listOf(acct), out)
    }

    @Test
    fun anAccountIdRelayThatAnnouncedItsOwnInterfaceIsNeverSuperseded() {
        // The flip-flop: the Mac hosts relay `acct`; learning `device` must not evict it, or its
        // next announce re-adds it and the two evict each other forever.
        val out = RelayNodeMap.supersededAccountRelays(listOf(acct, device), device, setOf(acct)) { it == acct }
        assertTrue(out.isEmpty())
    }

    @Test
    fun theLearnedRelayAndNonAccountEntriesAreNeverSuperseded() {
        val other = "e".repeat(64)
        assertTrue(RelayNodeMap.supersededAccountRelays(listOf(acct, other), acct, setOf(acct)) { false }.isEmpty())
        assertTrue(RelayNodeMap.supersededAccountRelays(listOf(other), device, setOf(acct)) { false }.isEmpty())
    }

    /** The second crash: `saveRelayNodes` (called from `ensureRelayEntry` ← `handleRelayNode` on
     *  Dispatchers.IO) serialising relay state while announces on other workers kept writing. Several
     *  announce handlers + several savers at once, the way `onInbound` fans frames out. */
    @Test
    fun announceHandlersAndSaversRunConcurrentlyWithoutThrowing() {
        val map = RelayNodeMap.newMap()
        val suppressed: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()
        val forgotAt = java.util.concurrent.ConcurrentHashMap<String, Long>()
        val failure = AtomicReference<Throwable?>(null)
        val threads = (0 until 6).map { t ->
            thread {
                try {
                    repeat(5_000) { i ->
                        if (t % 2 == 0) {
                            // handleRelayNode: learn, supersede, suppress, forget
                            val hex = ((i + t) % 40).toString().padStart(64, '0')
                            val list = map.getOrPut("c${i % 4}") { RelayNodeMap.newList() }
                            for (a in RelayNodeMap.supersededAccountRelays(list.toList(), hex, setOf("0".repeat(64))) { false }) {
                                if (list.remove(a)) suppressed.add(a)
                            }
                            if (!list.contains(hex)) list.add(hex)
                            if (i % 5 == 0) { RelayNodeMap.removeRelay(list, hex); forgotAt[hex] = i.toLong(); suppressed.remove(hex) }
                            if (i % 11 == 0) map.entries.removeAll { it.value.isEmpty() }
                        } else {
                            // saveRelayNodes
                            val o = org.json.JSONObject()
                            for ((k, v) in RelayNodeMap.snapshot(map)) o.put(k, org.json.JSONArray().apply { v.forEach { put(it) } })
                            org.json.JSONArray().apply { suppressed.toList().forEach { put(it) } }
                            org.json.JSONObject().apply { forgotAt.toMap().forEach { (k, v) -> put(k, v) } }
                            o.toString()
                        }
                    }
                } catch (e: Throwable) { failure.compareAndSet(null, e) }
            }
        }
        threads.forEach { it.join() }
        assertTrue("concurrent announce/save threw: ${failure.get()}", failure.get() == null)
    }
}
