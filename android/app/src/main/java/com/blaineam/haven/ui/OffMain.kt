package com.blaineam.haven.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import com.blaineam.haven.core.conflatedReads
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * `remember(key) { read() }` for a read that goes through the ENGINE — computed OFF the main thread.
 *
 * Every engine read takes the engine lock. In a `remember` it ran during composition, on main, so
 * it waited behind whatever background work held that lock (an ingest burst, a whole-state export)
 * — and the reads that were keyed on `feedVersion` re-ran on every ingested event. The e2e gate
 * (2026-10-01) caught main blocked for over a minute and the app ANR'd. Here the read runs on
 * [Dispatchers.Default] through [conflatedReads] (one read in flight, newest key wins, every
 * finished read published), and composition shows [initial] — then the last result — meanwhile.
 *
 * [key] must capture every input the read depends on (use a data class or a Pair). The result is
 * returned with the key it was read for, so a caller can refuse a result that belongs to a
 * different subject (e.g. the previous circle) instead of flashing it.
 */
@Composable
fun <K, R> rememberOffMain(key: K, initial: R, read: (K) -> R): Pair<K?, R> {
    val currentKey = rememberUpdatedState(key)
    val currentRead = rememberUpdatedState(read)
    val state by produceState<Pair<K?, R>>(initialValue = null to initial) {
        conflatedReads(snapshotFlow { currentKey.value },
            read = { k -> withContext(Dispatchers.Default) { runCatching { currentRead.value(k) } } },
            publish = { k, r -> r.onSuccess { value = k to it } })
    }
    return state
}
