package com.blaineam.haven.core

/**
 * A point-in-time copy of a [java.util.Collections.synchronizedSet]. The wrapper only locks its
 * single calls — `HashSet(wrapper)` iterates it unlocked, so a concurrent `add` from another inbound
 * coroutine throws ConcurrentModificationException. Held-media handling hit that on a fresh install's
 * first backfill and killed the process mid-sync (the message that was arriving was dropped with it).
 * Copying inside `synchronized(set)` is the lock the wrapper's own docs require for iteration.
 */
internal fun <T> snapshotOf(set: Set<T>): HashSet<T> = synchronized(set) { HashSet(set) }
