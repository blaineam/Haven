//! **Single chokepoint for every Haven iroh `Endpoint` bind.**
//!
//! Today all four bind sites used `Endpoint::builder(N0)` independently
//! (`lib.rs` Node, `blobstore` BlobServer + BlobClient, `s3tunnel` server + client).
//! That made n0's DERP + DNS/pkarr the *only* transport plane, with no place to inject:
//!
//! - a **custom `RelayMap`** of circle-hosted iroh-relay URLs (R1), or
//! - layered **AddressLookup** providers for relay-gossip discovery (R2).
//!
//! Routing every bind through [`haven_endpoint_builder`] means:
//!
//! 1. Multipath / transport invariants never diverge between sites (scar surface).
//! 2. Feature flags default **OFF** — behavior is identical to `N0` until opt-in.
//! 3. When circle gossip fills a `RelayBook` with `derp_url`s, one place builds
//!    `RelayMode::Custom` (or Custom ∪ Default later) without hunting call sites.
//!
//! See `docs/RESILIENCE-DESIGN.md` R0–R2 and `docs/DECENTRALIZED-DISCOVERY.md`.

use std::sync::Arc;

use iroh::{
    endpoint::{presets::N0, Builder, Endpoint, QuicTransportConfig},
    RelayConfig, RelayMap, RelayMode, RelayUrl,
};

/// Process-wide transport plane policy for Haven endpoints.
///
/// Default is **stock n0** (`use_n0_relays = true`, empty custom map) so shipping apps
/// change nothing until a circle hosts a DERP URL and the flag is flipped.
#[derive(Clone, Debug)]
pub struct EndpointPolicy {
    /// Keep n0's public DERP fleet in the map (default **true**).
    pub use_n0_relays: bool,
    /// Extra Haven-operated DERP base URLs (HTTPS), e.g. from circle `RelayBook.derp_url`.
    /// Empty by default. Ephemeral trycloudflare names belong here only after a **live**
    /// announce — never hardcode them.
    pub custom_derp_urls: Vec<String>,
    /// When true **and** `custom_derp_urls` is non-empty, prefer a map that includes the
    /// custom URLs (still unions n0 if `use_n0_relays`). When false, custom URLs are
    /// ignored at bind time (stored for later hot-reload work).
    pub prefer_custom_relays: bool,
}

impl Default for EndpointPolicy {
    fn default() -> Self {
        Self {
            use_n0_relays: true,
            custom_derp_urls: Vec::new(),
            prefer_custom_relays: false,
        }
    }
}

impl EndpointPolicy {
    /// Opt-in: use only the given Haven DERP URLs (n0 out). For tests / R1 soak.
    pub fn haven_only(urls: impl IntoIterator<Item = String>) -> Self {
        Self {
            use_n0_relays: false,
            custom_derp_urls: urls.into_iter().collect(),
            prefer_custom_relays: true,
        }
    }

    /// Stock n0 (default).
    pub fn n0() -> Self {
        Self::default()
    }

    /// Resolve the iroh [`RelayMode`] for this policy.
    pub fn relay_mode(&self) -> RelayMode {
        let customs: Vec<String> = if self.prefer_custom_relays {
            self.custom_derp_urls.clone()
        } else {
            Vec::new()
        };
        if customs.is_empty() {
            // No usable custom map — always n0 Default. haven_only with an empty list is a
            // misconfig; falling back avoids bricking transport with zero relays.
            return RelayMode::Default;
        }
        let map = if self.use_n0_relays {
            RelayMode::Default.relay_map()
        } else {
            RelayMap::empty()
        };
        for url in &customs {
            let Ok(relay_url) = url.parse::<RelayUrl>() else { continue };
            let cfg = Arc::new(RelayConfig::new(relay_url.clone(), None));
            map.insert(relay_url, cfg);
        }
        if map.is_empty() {
            return RelayMode::Default;
        }
        RelayMode::Custom(map)
    }
}

/// Global policy slot. Apps / tests set this **before** the first endpoint bind.
///
/// **Bind-time limit (honest):** iroh takes `RelayMode` / `RelayMap` when the `Endpoint` is
/// constructed. Calling [`apply_derp_urls`] after `HavenNode` / `Node::spawn` has already bound
/// does **not** retarget that live endpoint's DERP map — only the **next**
/// [`haven_endpoint_builder`]`.bind()` (process restart, cold secondary bind, or a future soft
/// rebind) picks up the new map. Discovery (`AddressLookup`) can hot-add; RelayMap cannot today.
/// We still apply process-wide policy as soon as derp URLs are learned so (1) late binds and
/// (2) the next `Node::start` after prefs load are Haven-first without an architecture rewrite.
static POLICY: std::sync::RwLock<EndpointPolicy> = std::sync::RwLock::new(EndpointPolicy {
    use_n0_relays: true,
    custom_derp_urls: Vec::new(),
    prefer_custom_relays: false,
});

/// Replace the process-wide endpoint policy (call before spawn in tests / opt-in).
pub fn set_endpoint_policy(policy: EndpointPolicy) {
    if let Ok(mut g) = POLICY.write() {
        *g = policy;
    }
}

/// Snapshot of the current policy.
pub fn endpoint_policy() -> EndpointPolicy {
    POLICY.read().map(|g| g.clone()).unwrap_or_default()
}

/// Build an iroh [`Builder`] with Haven's transport policy applied.
///
/// Always starts from the `N0` preset (discovery + defaults), then **overrides**
/// `relay_mode` when custom DERP URLs are active. Multipath is enabled here so every
/// bind site shares the same scar-fix (cross-NAT multipath negotiation).
pub fn haven_endpoint_builder() -> Builder {
    let policy = endpoint_policy();
    // Multipath must stay ON (iroh path manager assumes it). We previously set 16, which
    // multiplied hole-punch / path-probe UDP on phones — field log: ~350k UDP packets + ~0.5GB
    // in ~5 minutes, thermal HIGH_TEMP_ACTIVE, multi-% battery burn.
    //
    // iroh's QuicTransportConfigBuilder **ignores** values below 9
    // (`MAX_MULTIPATH_PATHS + 1` where `MAX_MULTIPATH_PATHS = 8` in iroh 1.0.2) and leaves the
    // builder default (8). So "cap at 4" is a silent no-op. Explicitly set the floor (9) —
    // the lowest value iroh will actually honor — globally. That is still multipath-on and
    // well below the old 16.
    const MAX_MP: u32 = 9;
    Endpoint::builder(N0)
        .relay_mode(policy.relay_mode())
        .transport_config(
            QuicTransportConfig::builder()
                .max_concurrent_multipath_paths(MAX_MP)
                .build(),
        )
}

/// Collect live DERP HTTPS URLs from a [`crate::discovery::RelayBook`].
pub fn derp_urls_from_book(book: &crate::discovery::RelayBook) -> Vec<String> {
    let mut urls: Vec<String> = book
        .live()
        .into_iter()
        .filter_map(|e| {
            let u = e.derp_url.trim();
            if u.is_empty() {
                None
            } else {
                Some(u.to_string())
            }
        })
        .collect();
    urls.sort();
    urls.dedup();
    urls
}

/// Apply a circle's live relay book to the process policy.
///
/// **Haven-first fabric:** when any live `derp_url` is known, n0 is **disabled** and the
/// custom map is preferred. When the book has no DERP URLs, n0 remains the only NAT fallback.
/// Does **not** rebind existing endpoints — next spawn / restart picks up the map.
pub fn apply_book_to_policy(book: &crate::discovery::RelayBook, _prefer_custom: bool) {
    apply_derp_urls(derp_urls_from_book(book));
}

/// Install known Haven DERP HTTPS URLs as the process-wide fabric policy.
/// Empty → n0 only. Non-empty → Haven only (no n0).
///
/// Call **before** [`haven_endpoint_builder`] / `Node::spawn` / `HavenNode::start` whenever
/// possible. Safe to call again after learn (frame 19 / adopt) so subsequent binds are Haven-first;
/// does not rebind already-live endpoints (see module docs on the process policy slot).
pub fn apply_derp_urls(urls: Vec<String>) {
    let mut cleaned: Vec<String> = urls
        .into_iter()
        .map(|u| u.trim().trim_end_matches('/').to_string())
        .filter(|u| !u.is_empty())
        .collect();
    cleaned.sort();
    cleaned.dedup();

    let mut p = EndpointPolicy::default();
    if cleaned.is_empty() {
        // No circle-hosted DERP: keep stock n0.
        p.use_n0_relays = true;
        p.prefer_custom_relays = false;
        p.custom_derp_urls.clear();
    } else {
        // UNION with n0, never REPLACE it.
        //
        // Dropping the n0 relays the moment a circle announced its own DERP made the circle's
        // hostname a single point of failure for the entire transport — and with free tunnels that
        // hostname changes on every relay restart. The instant it moved, iroh held a relay map of
        // exactly one dead URL: no rendezvous, no hole-punching, no address discovery. Two devices
        // on the SAME WI-FI then could not connect, because peers still have to exchange addresses
        // before a direct path can form. Everything — posts, DMs, stories, call signaling — went
        // dark together, which is exactly the shape of a transport with nowhere to meet.
        //
        // A circle relay is an ADDITION (lower latency, self-hosted, private), never a substitute
        // for the free public fallback. Keeping n0 means the worst case for a dead circle DERP is
        // "slower rendezvous", not "no communication at all". iroh prefers the lowest-RTT path
        // anyway, so a healthy circle relay still wins on merit, and a same-LAN pair still ends up
        // on a direct path with no relay in the data path at all.
        p.use_n0_relays = true;
        p.prefer_custom_relays = true;
        p.custom_derp_urls = cleaned;
    }
    set_endpoint_policy(p);
}

/// Union extra DERP HTTPS URLs into the process fabric (e.g. one discovery `AddrRecord` hint)
/// without dropping URLs already known from the circle relay book.
pub fn merge_derp_urls(extra: impl IntoIterator<Item = String>) {
    let mut all = if haven_fabric_active() {
        endpoint_policy().custom_derp_urls
    } else {
        Vec::new()
    };
    for u in extra {
        let t = u.trim().trim_end_matches('/').to_string();
        if !t.is_empty() && !all.iter().any(|x| x == &t) {
            all.push(t);
        }
    }
    apply_derp_urls(all);
}

/// True when at least one Haven DERP URL is active (n0 is not the sole fabric).
pub fn haven_fabric_active() -> bool {
    let p = endpoint_policy();
    p.prefer_custom_relays && !p.custom_derp_urls.is_empty()
}

/// Snapshot of active custom DERP URLs (empty when fabric is off / n0-only).
pub fn active_derp_urls() -> Vec<String> {
    let p = endpoint_policy();
    if p.prefer_custom_relays {
        p.custom_derp_urls
    } else {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::discovery::{RelayBook, RelayEntry};

    #[test]
    fn default_policy_is_n0_default_mode() {
        let p = EndpointPolicy::default();
        assert!(p.use_n0_relays);
        assert!(!p.prefer_custom_relays);
        assert!(matches!(p.relay_mode(), RelayMode::Default));
    }

    #[test]
    fn haven_only_empty_falls_back_to_default() {
        let p = EndpointPolicy::haven_only(std::iter::empty::<String>());
        assert!(matches!(p.relay_mode(), RelayMode::Default));
    }

    #[test]
    fn custom_url_with_flag_builds_custom_mode() {
        let p = EndpointPolicy {
            use_n0_relays: false,
            custom_derp_urls: vec!["https://relay.example.com.".into()],
            prefer_custom_relays: true,
        };
        match p.relay_mode() {
            RelayMode::Custom(map) => assert!(!map.is_empty()),
            other => panic!("expected Custom, got {other:?}"),
        }
    }

    #[test]
    fn apply_derp_urls_haven_first_disables_n0() {
        apply_derp_urls(vec!["https://relay.example.com".into()]);
        let p = endpoint_policy();
        assert!(!p.use_n0_relays);
        assert!(p.prefer_custom_relays);
        assert!(haven_fabric_active());
        assert_eq!(active_derp_urls(), vec!["https://relay.example.com".to_string()]);
        // Reset so other tests see defaults.
        apply_derp_urls(vec![]);
        assert!(!haven_fabric_active());
        assert!(endpoint_policy().use_n0_relays);
        assert!(active_derp_urls().is_empty());
    }

    #[test]
    fn merge_derp_urls_unions_without_dropping() {
        apply_derp_urls(vec!["https://a.example.com".into()]);
        merge_derp_urls(vec!["https://b.example.com".into(), "https://a.example.com/".into()]);
        let urls = active_derp_urls();
        assert_eq!(urls, vec!["https://a.example.com".to_string(), "https://b.example.com".to_string()]);
        apply_derp_urls(vec![]);
    }

    #[test]
    fn apply_derp_urls_trims_and_dedups() {
        apply_derp_urls(vec![
            " https://x.example.com/ ".into(),
            "https://x.example.com".into(),
            "".into(),
        ]);
        assert_eq!(active_derp_urls(), vec!["https://x.example.com".to_string()]);
        apply_derp_urls(vec![]);
    }

    #[test]
    fn custom_urls_ignored_when_flag_off() {
        let p = EndpointPolicy {
            use_n0_relays: true,
            custom_derp_urls: vec!["https://relay.example.com.".into()],
            prefer_custom_relays: false,
        };
        assert!(matches!(p.relay_mode(), RelayMode::Default));
    }

    #[test]
    fn derp_urls_from_book_skips_empty_and_tombstones() {
        let mut b = RelayBook::default();
        b.upsert("aa", "h:8674", "home", "https://live.example.com");
        b.upsert("bb", "h:8674", "dead", "");
        b.remove("bb");
        // After remove, bb is tombstone; live() excludes it.
        let urls = derp_urls_from_book(&b);
        assert_eq!(urls, vec!["https://live.example.com".to_string()]);
    }

    #[test]
    fn upsert_preserves_derp_url() {
        let mut b = RelayBook::default();
        b.upsert("aa", "127.0.0.1:8674", "mac", "https://abc.trycloudflare.com");
        assert_eq!(b.entries["aa"].derp_url, "https://abc.trycloudflare.com");
        // Bump with a new ephemeral hostname (tunnel restart).
        b.upsert("aa", "127.0.0.1:8674", "mac", "https://xyz.trycloudflare.com");
        assert_eq!(b.entries["aa"].derp_url, "https://xyz.trycloudflare.com");
        assert!(b.entries["aa"].gen >= 2);
    }

    #[test]
    fn relay_entry_default_derp_is_empty() {
        let e = RelayEntry {
            node_hex: "x".into(),
            http: "h".into(),
            derp_url: String::new(),
            label: String::new(),
            present: true,
            gen: 1,
        };
        assert!(e.derp_url.is_empty());
    }
}
