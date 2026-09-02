import Foundation

/// `HAVEN_NO_NET=1` — the demo / UI-test harness contract, enforced at the transports.
///
/// The flag used to mean only "don't bring the iroh node up" (`FeedStore.configureForCurrentIdentity`
/// returned before `bringOnline()`), and that was never the whole app. The relay **HTTP** lane is a
/// plain `URLSession` against relay records already on disk — it needs no node, no discovery and no
/// handshake — so a simulator that had ever run a real identity kept talking to the world with the
/// flag set. A captured `HavenUITests` run logged `hello http-put OK to=… relay=…`,
/// `hello fan-out circle=default accounts=5`, and an inbound
/// `hello claim HELD (held-for-approval) from=…` that raised a live "wants to connect" request from
/// a stranger's account *mid-test*. The leak was structural, not a missed call site: the timers that
/// drive the fan-out are re-armed by `setForeground(true) → armHeartbeats()`, which runs on every
/// foreground transition and never passed through the launch-time guard at all.
///
/// That made the rig a coin flip — any UI test could be perturbed by whatever another Haven client
/// on the network chose to say to it, and it is what turned a real ActivityStore ordering bug
/// (fixed in 7d96a0fe) into an intermittent one. So the flag is now enforced **where the bytes
/// leave**, not only where the node starts:
///
///  - `RelayMailboxStore.httpInterface` reports no usable HTTP interface, which retires the entire
///    relay HTTP lane (hello put/fetch, mailbox LIST/GET, announce, self-sync, media) through the
///    path the code already handles — "this relay is iroh-only". No relay is marked unreachable and
///    no health is recorded, so nothing about the persisted relay state changes on a harness run.
///  - The raw `SharedStore` HTTP primitives refuse anyway, so a future caller that builds a base URL
///    and token some other way still cannot reach the wire.
///  - Every other outbound transport — S3/pre-signed URLs, the push relay, the moderation ledger,
///    the WebSocket call hairpin, cloudflared, the hosted relay server, Multipeer discovery, and the
///    notification extension's mailbox prefetch — refuses at its own entry point.
///  - The schedulers that would otherwise seal envelopes for a lane that will drop them
///    (`armMailboxTimer`, `startSyncTimer`, `syncWithContacts`) simply don't arm, so the diagnostic
///    log stays quiet and the harness isn't paying CPU for hybrid-PQ seals nobody will send.
///
/// Deliberately **not** gated: `LinkUI`'s `WKWebView` and the `LinkSafety` resolve behind it. Those
/// are the in-app browser, reached only by a deliberate tap on a link the user chose to open — a
/// browser that cannot load anything is a broken feature, not a hermetic one.
///
/// Honoured in release builds too, exactly as the original `HavenApp` checks were: on iOS nothing
/// outside the harness can set the process environment, and "launched with `HAVEN_NO_NET` and
/// silently online" would be the surprising reading.
enum HavenNet {
    /// True when this process must talk to nothing. Read once — this is consulted on hot paths.
    static let offline: Bool = ProcessInfo.processInfo.environment["HAVEN_NO_NET"] == "1"
}
