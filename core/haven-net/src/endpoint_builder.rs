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
/// Default = n0-only. Not a runtime hot-reload of existing endpoints (iroh binds map at
/// construct time); a full rebind is still required to apply a new map today.
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
    Endpoint::builder(N0)
        .relay_mode(policy.relay_mode())
        .transport_config(
            QuicTransportConfig::builder()
                .max_concurrent_multipath_paths(16)
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

/// Apply a circle's live relay book to the process policy (opt-in flag must be set by caller).
/// Does **not** rebind existing endpoints — next spawn picks up the map.
pub fn apply_book_to_policy(book: &crate::discovery::RelayBook, prefer_custom: bool) {
    let urls = derp_urls_from_book(book);
    let mut p = endpoint_policy();
    p.custom_derp_urls = urls;
    p.prefer_custom_relays = prefer_custom && !p.custom_derp_urls.is_empty();
    set_endpoint_policy(p);
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
