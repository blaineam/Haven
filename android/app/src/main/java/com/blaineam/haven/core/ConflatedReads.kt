package com.blaineam.haven.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * Re-read on every key change WITHOUT ever abandoning a read in flight.
 *
 * The feed used to be a `produceState(version, …)`: every key change cancelled the producer and
 * started a new one. But the read is `engine.feed()` — a blocking JNI decode of the whole circle
 * that cancellation cannot stop — so a cancel only THREW AWAY the finished result and started a
 * second decode alongside the first. While a backlog lands (launch, a busy circle) feedVersion
 * bumps on every ingested event and media arrival, faster than one decode completes under load, so
 * no read was ever published and the decodes piled up on the Default pool:
 *  - e2e gate 2026-09-30: Android's first feed painted 26.7 s after launch (budget 8 s; median 1.1 s),
 *  - and later the app sat at 124 % CPU until the emulator's system_server hit its watchdog and
 *    took the app — and the QA dump channel — down with it.
 *
 * Here at most ONE [read] runs at a time, every completed read is [publish]ed, and keys that
 * arrive meanwhile collapse into one follow-up read of the newest key (never a stale one).
 */
suspend fun <K, R> conflatedReads(keys: Flow<K>, read: suspend (K) -> R, publish: (K, R) -> Unit) {
    keys.distinctUntilChanged().conflate().collect { k -> publish(k, read(k)) }
}
