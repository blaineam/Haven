package com.blaineam.haven.core

import java.util.concurrent.ConcurrentHashMap

/**
 * Containers for HavenNet state that coroutines on Dispatchers.IO / Default and the main thread
 * all touch with no common lock: relay tombstones and cool-downs, the erased-relay archive, relay
 * health, pending handshakes, device dial hints, enrollment tickets, roster-publish stamps, the
 * mailbox seen-set, media request throttles and upload-resume progress.
 *
 * As plain HashMap / HashSet an iteration that raced a write threw
 * ConcurrentModificationException, and an uncaught exception on an IO coroutine kills the app —
 * the emulator's dropbox holds six such kills in two days (relaysFor / saveRelayNodes /
 * handleRelayNode), one seconds before the 2026-09-30 gate's android launch step. A racing
 * HashMap write can also corrupt the table outright. Concurrent maps and key-sets make every
 * read and iteration safe without a lock (iteration is weakly consistent — a snapshot-ish walk).
 * Existing `synchronized(x)` blocks that make a compound read-modify-write atomic still work:
 * they lock on the collection object as before. `relayNodes` has its own [RelayNodeMap].
 *
 * Neither map keys nor values may be null — ConcurrentHashMap rejects them.
 */
object SharedCollections {
    fun <V : Any> map(): ConcurrentHashMap<String, V> = ConcurrentHashMap()
    fun set(): MutableSet<String> = ConcurrentHashMap.newKeySet()
}
