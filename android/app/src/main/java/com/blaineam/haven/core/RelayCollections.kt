package com.blaineam.haven.core

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The containers HavenNet keeps its relay configuration in (circle → relay list, forget / clear
 * tombstones, erased-relay archive, per-URL cool-downs).
 *
 * That state is read and written from many coroutines at once — every inbound relay announce
 * (`handleRelayNode` on Dispatchers.IO), each mailbox pass and backfill (`relaysFor`), selfsync,
 * the settings UI — with no common lock. As plain HashMap / ArrayList they threw
 * ConcurrentModificationException out of `relaysFor` and `saveRelayNodes` whenever an announce
 * landed during a read, and an uncaught exception on an IO coroutine kills the process: the e2e
 * gate saw Android die that way right before its `launch` step, and five times over two days.
 *
 * Concurrent maps plus copy-on-write lists make every read a consistent snapshot and every
 * iteration CME-free. The lists are tiny (a handful of relays per circle) and written rarely, so
 * copy-on-write costs nothing that matters. Use `removeIf` on these lists — it is atomic on a
 * CopyOnWriteArrayList, where Kotlin's `removeAll(predicate)` is an index walk.
 */
object RelayCollections {
    /** circleId → ORDERED relay node hexes; every value MUST come from [list]. */
    fun associations(): ConcurrentHashMap<String, MutableList<String>> = ConcurrentHashMap()
    fun list(): MutableList<String> = CopyOnWriteArrayList()
    fun <V : Any> map(): ConcurrentHashMap<String, V> = ConcurrentHashMap()
    fun set(): MutableSet<String> = ConcurrentHashMap.newKeySet()
}
