package com.blaineam.haven.core

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * circleId -> ordered relay node hexes, safe to READ while another thread WRITES.
 *
 * `HavenNet.relayNodes` was a plain HashMap of ArrayLists, read on Dispatchers.IO (relaysFor from
 * backfillMailbox / mailbox polls / live-call puts) while relay announces, host toggles and
 * self-sync mutated it on other threads. An iteration that raced an `add` threw
 * ConcurrentModificationException and killed the process mid-call (e2e screenshare [again],
 * 2026-09-29: `relaysFor` ← `backfillMailbox` ← `handleRelayNode`). Lists are copy-on-write —
 * relay lists are a handful of entries and written rarely, so every iteration walks a snapshot.
 */
object RelayNodeMap {
    fun newMap(): ConcurrentHashMap<String, MutableList<String>> = ConcurrentHashMap()
    fun newList(from: Collection<String> = emptyList()): MutableList<String> = CopyOnWriteArrayList(from)

    /** Remove `hex` from a relay list ATOMICALLY. Kotlin's `MutableList.removeAll { }` is an
     *  index-walking extension (size read once, then get/removeAt) — on a list another thread is
     *  shrinking it throws IndexOutOfBounds; the stress test caught exactly that. `removeIf` is the
     *  CopyOnWriteArrayList member, which swaps the array under its lock. */
    fun removeRelay(list: MutableList<String>, hex: String): Boolean = list.removeIf { it == hex }

    /** A point-in-time copy to iterate (persistence, UI, logs) — never walk the live map while others write. */
    fun snapshot(map: Map<String, List<String>>): Map<String, List<String>> =
        map.entries.associate { (k, v) -> k to v.toList() }

    /**
     * Which of a circle's relay entries a newly learned relay SUPERSEDES: entries equal to a member's
     * (or my own) ACCOUNT id — pre-device-seed leftovers nothing serves. Never one that has announced
     * its own HTTP interface or ever answered us: a Mac hosting a relay under its account id is a live relay, and
     * superseding it made two relays evict each other on every announce (e2e fleet: the stub's
     * `fe263256` re-"learned" ~30×/min, each time re-exporting history, fsyncing prefs and polling —
     * the churn that also raced relaysFor into a crash).
     */
    fun supersededAccountRelays(
        entries: List<String>,
        learned: String,
        accountIds: Set<String>,
        isLiveRelay: (String) -> Boolean,
    ): List<String> = entries.filter { a ->
        a.length == 64 && a != learned && a in accountIds && !isLiveRelay(a)
    }
}
