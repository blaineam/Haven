package com.blaineam.haven.core

import android.util.Log
import com.blaineam.haven.BuildConfig

/**
 * `haven_no_net` — the demo / instrumented-test contract, enforced at the transports.
 *
 * The flag existed before this, in two ways that both fell short. It was read only *inside*
 * [DemoEnv]'s `haven_demo` branch, so asking for "offline" without also asking for the synthetic
 * dataset did nothing at all; and all it ever gated was `HavenNet.start()` — the iroh node.
 *
 * The node is not the only wire. The relay **HTTP** lane is a plain `HttpURLConnection` against
 * relay records already in prefs: no node, no discovery, no handshake. So is S3/pre-signed media,
 * the push worker, the moderation ledger, the WebSocket call hairpin, the music search, and the
 * mailbox prefetch [SyncWorker] runs from `HavenApplication.onCreate` — which fires in the
 * **instrumented-test process too**, on a device that carries a real identity. `connectedDebugAndroidTest`
 * was therefore free to poll a real mailbox and drain a real backup queue while asserting on local
 * crypto. Apple had the identical gap on the same lane and fixed it the same way
 * (`apple/Shared/OfflineGate.swift`): gate where the bytes leave, not only where the node starts.
 *
 *  - `HavenNet.httpUrlsFor` reports no usable URLs, which retires the whole relay HTTP lane through
 *    the branch every caller already handles — "this relay is iroh-only". Nothing is marked bad and
 *    no health is recorded, so a harness run leaves the persisted relay state untouched.
 *  - `relayHttpGet` / `relayHttpPut` / `relayHttpListDelta` refuse behind that, so a route built
 *    from a base and token some other way still cannot reach the wire.
 *  - `relayClientFor` (iroh dial), [NearbyTransport], [CallHairpin], [Presign], [Moderation],
 *    [MusicSearch], the push registration and [SyncWorker] each refuse at their own entry point.
 *  - The schedulers that would seal envelopes for a lane that will drop them — the node start, the
 *    sync fan-out, the mailbox polls and the backup drain — don't run.
 *
 * **DEBUG builds only, deliberately** — and unlike Apple, which honours its env var in release too.
 * The difference is the input: iOS reads a process environment variable that nothing outside the
 * test harness can set, whereas this reads an Intent extra on an **exported** activity, which any
 * app on the device can put there. A release build that could be launched permanently silent by a
 * third party is a worse bug than the one this closes.
 */
object HavenOffline {

    @Volatile
    private var offline = false

    /** True when this process must talk to nothing. Consulted on hot paths — keep it a field read. */
    val enabled: Boolean get() = offline

    /**
     * Arm or disarm the gate. No-op in a release build (see the class note).
     *
     * Called from [DemoEnv.configure] for the launch-intent path, and directly from the
     * instrumented-test runner — which is how `connectedDebugAndroidTest` becomes hermetic without
     * every test having to remember, the same role `launchEnvironment` plays for the iOS UI tests.
     */
    fun set(on: Boolean) {
        if (!BuildConfig.DEBUG) return
        if (offline == on) return
        offline = on
        Log.i("HavenOffline", if (on) "offline: this process talks to nothing" else "offline: cleared")
    }
}
