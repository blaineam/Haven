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
}
