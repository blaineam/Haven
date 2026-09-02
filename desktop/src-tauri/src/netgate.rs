//! `HAVEN_NO_NET=1` — the demo / capture harness contract, enforced at the transports.
//!
//! The flag used to mean only "don't bring the iroh node up": `lib.rs` skipped `Engine::start`, and
//! that was the whole of it. But the node is not the only wire. The relay **HTTP** lane is a plain
//! `reqwest` client against relay records already in prefs — no node, no discovery, no handshake —
//! and it is reachable from any Tauri command the UI can invoke. So was S3, the push worker, the
//! moderation ledger and the iTunes lookups behind song suggestions. A capture run driving a
//! synthetic cast through a live UI could still put bytes on someone else's relay.
//!
//! Apple hit the same gap and fixed it the same way (`apple/Shared/OfflineGate.swift`): gate where
//! the bytes leave, not only where the node starts.
//!
//!  - `Engine::relay_http_reachable` reports no usable HTTP interface, which retires the whole relay
//!    HTTP lane through the branch every caller already handles — "this relay is iroh-only". Nothing
//!    is marked bad and no health is recorded, so a harness run leaves prefs untouched.
//!  - `http_get` / `http_put` / `http_list_delta` refuse behind that, so a route built from a base
//!    and token some other way still cannot reach the wire.
//!  - `relay_client_for` (iroh dial), `s3_client`, the push worker's `/notify` and `/flag`, and the
//!    iTunes search/lookup each refuse at their own entry point.
//!  - `Engine::start` and `start_hosting` refuse, which also covers the mailbox/sync loop — it is
//!    spawned by `start`.
//!
//! Deliberately **debug-only**, unlike Apple. On iOS nothing outside the harness can set the
//! process environment; on a desktop the environment is inherited from a shell or a session manager,
//! where a stray `HAVEN_NO_NET` would silently and invisibly disconnect a real user's app. This
//! keeps the module's existing contract (`lib.rs::no_net` was already always-false in release) —
//! there was never a release behaviour here to preserve, only a debug one to make honest.
//!
//! Unlike `demo.rs` this module is compiled into every build, so a `netgate::offline()` call is
//! valid anywhere without a `#[cfg]` dance at each site.

/// True when this process must talk to nothing. `HAVEN_DEMO` implies it: a synthetic cast must never
/// reach a real peer. Read once — this is consulted on hot paths.
pub fn offline() -> bool {
    #[cfg(debug_assertions)]
    {
        static OFFLINE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        *OFFLINE.get_or_init(|| {
            decide(std::env::var("HAVEN_NO_NET").ok().as_deref(), std::env::var("HAVEN_DEMO").ok().as_deref())
        })
    }
    #[cfg(not(debug_assertions))]
    {
        false
    }
}

/// The rule itself, kept pure so it is testable — `offline()` caches its answer in a `OnceLock`, so
/// a test that set env vars around it would depend on which test happened to run first.
///
/// `"1"` exactly, not "anything truthy": these flags are set by harness scripts, and a typo that
/// silently disconnected the app would be worse than one that visibly did nothing.
#[cfg(debug_assertions)]
fn decide(no_net: Option<&str>, demo: Option<&str>) -> bool {
    no_net == Some("1") || demo == Some("1")
}

#[cfg(test)]
mod tests {
    use super::decide;

    #[test]
    fn only_an_exact_1_arms_the_gate() {
        assert!(decide(Some("1"), None));
        assert!(!decide(None, None));
        assert!(!decide(Some("0"), None));
        assert!(!decide(Some("true"), None), "harness flags are `1`, not truthy strings");
        assert!(!decide(Some(""), None));
    }

    #[test]
    fn demo_implies_offline() {
        // Rule 3 of `demo.rs`: a synthetic cast must never reach a real peer, whether or not the
        // capture script remembered to pass the second flag.
        assert!(decide(None, Some("1")));
        assert!(decide(Some("0"), Some("1")));
    }
}
