package com.blaineam.haven.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * How many media items are being encoded right now, so the composer can say so.
 *
 * TWO problems, one object.
 *
 * The first is the one you can see: picking a video used to show NOTHING until the encode finished.
 * On iOS that silence cost real debugging time — "attaching a video never attaches anything" and
 * "attaching a video is slow" look identical from the outside, and the user reported it as the
 * former when it was the latter.
 *
 * The second is the one you can't, and it is worse. [readVideoBytes] runs a full
 * MediaExtractor → MediaCodec decode → encode → MediaMuxer pipeline, and every call site invoked it
 * DIRECTLY inside a `rememberLauncherForActivityResult` callback — which Android delivers on the
 * main thread. A 35-second transcode there is not jank, it is an ANR: the system kills the app after
 * 5 seconds of an unresponsive main looper. Attaching any real video to a post, a comment or a DM
 * would freeze Haven and then kill it. The encode is now dispatched off-main by [processing], and
 * this counter is what lets the UI stay honest while it runs.
 *
 * Counted rather than boolean because the picker takes up to 8 items and they are encoded in
 * sequence — the card must stay up for the whole run, not flicker once per item.
 */
object MediaProcessing {
    /** In-flight encodes. Read from composables; only ever mutated on the main thread. */
    var inFlight by mutableStateOf(0)
        private set

    val isBusy: Boolean get() = inFlight > 0

    /**
     * Run [body] off the main thread with the counter held up for its duration.
     *
     * The counter is bumped on the caller's (main) thread BEFORE dispatching and dropped in a
     * `finally` on the way back, so a throwing or cancelled encode cannot strand the card on screen
     * forever — which would be its own bug report.
     */
    suspend fun <T> processing(body: suspend () -> T): T {
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { inFlight += 1 }
        try {
            return kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) { body() }
        } finally {
            kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                    inFlight = (inFlight - 1).coerceAtLeast(0)
                }
            }
        }
    }
}
