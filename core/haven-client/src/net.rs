//! The slice of `haven-net` the client layer uses.
//!
//! Natively these are `haven-net`'s own items, re-exported. `haven-net` is the native node and the
//! relay's server side — sockets, listeners, child processes — and cannot build for a browser, so
//! on `wasm32` this module supplies:
//!
//! * [`portable`]: the handful of pure constants and parsers a client needs (relay keys, front-door
//!   mode, TURN URL parsing). They are re-implementations, so the native test run checks each one
//!   against `haven-net`'s original — they cannot drift unnoticed;
//! * [`hosting`]: stand-ins for relay hosting (DERP, TURN, path proxy, tunnel). A tab cannot listen,
//!   so starting any of them reports exactly that.

#[cfg(not(target_arch = "wasm32"))]
pub use haven_net::{
    active_derp_urls, apply_derp_urls, haven_fabric_active, host_from_http_url, parse_turn_urls, suggest_turn_urls,
    DerpConfig, DerpServer, PathRouter, PathRouterConfig, TurnConfig, TurnServer, DEFAULT_DERP_BIND,
    DEFAULT_PATH_ROUTER_BIND, DEFAULT_TURN_BIND, DEFAULT_TURN_USER,
};

#[cfg(not(target_arch = "wasm32"))]
pub mod blobstore {
    pub use haven_net::blobstore::{media_scope_key, MEDIA_SCOPE_BODY, RELAY_INTERFACE_KEY};
}
#[cfg(not(target_arch = "wasm32"))]
pub mod httprelay {
    pub use haven_net::httprelay::{auth_header, LIST_DIGEST_HEADER};
}
#[cfg(not(target_arch = "wasm32"))]
pub mod cfquicktunnel {
    pub use haven_net::cfquicktunnel::*;
}

#[cfg(target_arch = "wasm32")]
pub use hosting::*;
#[cfg(target_arch = "wasm32")]
pub use portable::{
    active_derp_urls, apply_derp_urls, haven_fabric_active, host_from_http_url, parse_turn_urls, suggest_turn_urls,
    DEFAULT_DERP_BIND, DEFAULT_PATH_ROUTER_BIND, DEFAULT_TURN_BIND, DEFAULT_TURN_USER,
};
#[cfg(target_arch = "wasm32")]
pub mod blobstore {
    pub use super::portable::{media_scope_key, MEDIA_SCOPE_BODY, RELAY_INTERFACE_KEY};
}
#[cfg(target_arch = "wasm32")]
pub mod httprelay {
    pub use super::portable::{auth_header, LIST_DIGEST_HEADER};
}
#[cfg(target_arch = "wasm32")]
pub mod cfquicktunnel {
    pub use super::hosting::{
        ensure_cloudflared, executable_dir, kill_orphan_cloudflareds, resolve_front_door, FrontDoorAction, QuickTunnel,
        TunnelSpec,
    };
    pub use super::portable::{normalize_public_url, FrontDoorMode};
}

/// Relay hosting, as seen from a browser: a tab cannot listen on a socket or run `cloudflared`, so
/// every way of starting a hosted role fails with [`NOT_IN_A_BROWSER`] (or reports "not started")
/// and none of these types is ever constructed. They exist so the engine's hosting code — which
/// the desktop app uses for real — compiles unchanged.
#[cfg(target_arch = "wasm32")]
pub mod hosting {
    use std::convert::Infallible;
    use std::path::{Path, PathBuf};

    use anyhow::{bail, Result};

    use super::portable::FrontDoorMode;

    pub const NOT_IN_A_BROWSER: &str = "hosting a relay is not possible in a browser — use a Haven app or haven-relay";

    #[derive(Clone, Debug)]
    pub struct DerpConfig {
        pub enabled: bool,
        pub bind: String,
        pub public_url: String,
    }

    pub struct DerpServer {
        pub public_url: String,
        pub local_addr: std::net::SocketAddr,
        never: Infallible,
    }

    impl DerpServer {
        pub async fn spawn(_cfg: &DerpConfig) -> Result<Option<Self>> {
            Ok(None)
        }
        pub fn local_port(&self) -> u16 {
            match self.never {}
        }
    }

    #[derive(Clone, Debug)]
    pub struct PathRouterConfig {
        pub bind: String,
        pub media_backend: String,
        pub derp_backend: String,
        pub http_token: String,
    }

    pub struct PathRouter {
        pub local_addr: std::net::SocketAddr,
        never: Infallible,
    }

    impl PathRouter {
        pub async fn spawn(_cfg: &PathRouterConfig) -> Result<Option<Self>> {
            Ok(None)
        }
        pub fn local_port(&self) -> u16 {
            match self.never {}
        }
    }

    #[derive(Clone, Debug)]
    pub struct TurnConfig {
        pub enabled: bool,
        pub bind: String,
        pub public_ip: String,
        pub secret: String,
        pub public_urls: Vec<String>,
    }

    pub struct TurnServer {
        pub local_addr: std::net::SocketAddr,
        pub public_urls: Vec<String>,
        pub username: String,
        pub password: String,
        #[allow(dead_code)]
        never: Infallible,
    }

    impl TurnServer {
        pub async fn spawn(_cfg: &TurnConfig) -> Result<Option<Self>> {
            Ok(None)
        }
    }

    #[derive(Clone, Debug)]
    pub enum TunnelSpec {
        Quick { local_http: String },
        NamedToken { token: String, public_url: String },
    }

    #[derive(Clone, Debug)]
    pub enum FrontDoorAction {
        Spawn(TunnelSpec),
        AnnounceOnly { public_url: String },
        LanOnly,
    }

    pub struct QuickTunnel {
        pub public_url: String,
        pub kind: &'static str,
        #[allow(dead_code)]
        never: Infallible,
    }

    impl QuickTunnel {
        pub fn start_spec(_cloudflared: &Path, _spec: TunnelSpec) -> Result<Self> {
            bail!(NOT_IN_A_BROWSER)
        }
    }

    pub fn resolve_front_door(
        _mode: FrontDoorMode,
        _public_url: Option<&str>,
        _tunnel_token: Option<&str>,
        _auto_quick: bool,
        _local_http: &str,
    ) -> Result<FrontDoorAction> {
        bail!(NOT_IN_A_BROWSER)
    }

    pub fn ensure_cloudflared(_search_dirs: &[PathBuf], _install_dir: &Path, _allow_download: bool) -> Result<PathBuf> {
        bail!(NOT_IN_A_BROWSER)
    }

    pub fn executable_dir() -> Result<PathBuf> {
        bail!(NOT_IN_A_BROWSER)
    }

    /// Nothing to reap: a tab never started one.
    pub fn kill_orphan_cloudflareds(_except: &[u32]) {}
}

/// Pure client-side pieces of the relay protocol, for targets that cannot link `haven-net`.
#[cfg(any(target_arch = "wasm32", test))]
pub mod portable {
    use std::sync::RwLock;

    pub const DEFAULT_DERP_BIND: &str = "127.0.0.1:3340";
    pub const DEFAULT_PATH_ROUTER_BIND: &str = "127.0.0.1:8675";
    pub const DEFAULT_TURN_BIND: &str = "0.0.0.0:3478";
    pub const DEFAULT_TURN_USER: &str = "haven";

    /// The body of a media scope marker. Content-free: the KEY is the information.
    pub const MEDIA_SCOPE_BODY: &[u8] = b"1";
    /// Reserved key under which a relay publishes its own current interface.
    pub const RELAY_INTERFACE_KEY: &str = "haven/relay/__interface__";
    /// LIST delta header (request and response): a digest of a prefix's sorted key set.
    pub const LIST_DIGEST_HEADER: &str = "X-Haven-List-Digest";

    /// The scope marker key that says media `reference` belongs to `circle`.
    pub fn media_scope_key(reference: &str, circle: &str) -> String {
        format!("haven/media/{reference}.c/{circle}")
    }

    /// The `Authorization: Haven …` value for one signed relay request, at the current time.
    pub fn auth_header(node_secret: &[u8; 32], token: &str, method: &str, key: &str, body: &[u8]) -> String {
        let ts = web_time::SystemTime::now().duration_since(web_time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        haven_p2p::httpauth::auth_header_at(node_secret, token, method, key, body, ts)
    }

    /// How the operator wants the public HTTPS front door to work.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum FrontDoorMode {
        Auto,
        Manual,
        Bundled,
    }

    impl FrontDoorMode {
        pub fn as_str(self) -> &'static str {
            match self {
                Self::Auto => "auto",
                Self::Manual => "manual",
                Self::Bundled => "bundled",
            }
        }

        /// Parse prefs / CLI / UI values. Unknown → `Auto`.
        pub fn parse(s: &str) -> Self {
            match s.trim().to_ascii_lowercase().as_str() {
                "manual" | "external" | "announce" => Self::Manual,
                "bundled" | "named" | "token" => Self::Bundled,
                _ => Self::Auto,
            }
        }
    }

    /// Normalize a user-entered public URL to `https://host[:port][/path]` without a trailing slash.
    pub fn normalize_public_url(raw: &str) -> anyhow::Result<String> {
        let t = raw.trim().trim_end_matches('/');
        if t.is_empty() {
            anyhow::bail!("public URL is empty");
        }
        let with_scheme =
            if t.starts_with("https://") || t.starts_with("http://") { t.to_string() } else { format!("https://{t}") };
        let host = with_scheme.split("://").nth(1).unwrap_or("").split('/').next().unwrap_or("");
        if host.is_empty() || !host.contains('.') {
            anyhow::bail!("public URL needs a real hostname (e.g. https://relay.example.com)");
        }
        Ok(with_scheme)
    }

    /// Host component of an `http(s)://…` media/DERP URL, if parseable.
    pub fn host_from_http_url(url: &str) -> Option<String> {
        let u = url.trim();
        let rest = u.strip_prefix("https://").or_else(|| u.strip_prefix("http://"))?;
        let hostport = rest.split('/').next()?.split('?').next()?;
        if let Some(inner) = hostport.strip_prefix('[') {
            let end = inner.find(']')?;
            return Some(inner[..end].to_string());
        }
        let host = hostport.split(':').next()?.trim();
        if host.is_empty() {
            None
        } else {
            Some(host.to_string())
        }
    }

    fn turn_url(host: &str, port: u16) -> String {
        let h = host.trim().trim_start_matches('[').trim_end_matches(']');
        format!("turn:{h}:{port}")
    }

    /// Suggest TURN announce URLs from media front-door host(s) + LAN IP (skips trycloudflare).
    pub fn suggest_turn_urls(media_urls: &[String], lan_ip: Option<&str>, port: u16) -> Vec<String> {
        let mut out = Vec::new();
        for u in media_urls {
            if let Some(h) = host_from_http_url(u) {
                if h.contains("trycloudflare.com") {
                    continue;
                }
                let url = turn_url(&h, port);
                if !out.contains(&url) {
                    out.push(url);
                }
            }
        }
        if let Some(ip) = lan_ip {
            let ip = ip.trim();
            if !ip.is_empty() && ip != "127.0.0.1" && ip != "::1" {
                let url = turn_url(ip, port);
                if !out.contains(&url) {
                    out.push(url);
                }
            }
        }
        out
    }

    /// Parse TURN URLs from a frame-19 / interface.json `turn` field (array or single string).
    pub fn parse_turn_urls(v: &serde_json::Value) -> Vec<String> {
        let ok = |s: &str| s.starts_with("turn:") || s.starts_with("turns:");
        match v {
            serde_json::Value::Array(arr) => {
                arr.iter().filter_map(|x| x.as_str()).map(|s| s.trim().to_string()).filter(|s| ok(s)).collect()
            }
            serde_json::Value::String(s) if ok(s.trim()) => vec![s.trim().to_string()],
            _ => Vec::new(),
        }
    }

    /// The circle-hosted DERP URLs this client knows — the fabric a browser node is bound to.
    static DERP_URLS: RwLock<Vec<String>> = RwLock::new(Vec::new());

    /// Install the known Haven DERP URLs (trimmed, de-duplicated, sorted). Empty = none.
    pub fn apply_derp_urls(urls: Vec<String>) {
        let mut cleaned: Vec<String> =
            urls.into_iter().map(|u| u.trim().trim_end_matches('/').to_string()).filter(|u| !u.is_empty()).collect();
        cleaned.sort();
        cleaned.dedup();
        if let Ok(mut g) = DERP_URLS.write() {
            *g = cleaned;
        }
    }

    pub fn active_derp_urls() -> Vec<String> {
        DERP_URLS.read().map(|g| g.clone()).unwrap_or_default()
    }

    pub fn haven_fabric_active() -> bool {
        !active_derp_urls().is_empty()
    }

    /// Each re-implementation above, checked against `haven-net`'s original.
    #[cfg(test)]
    mod parity {
        use super::*;

        #[test]
        fn constants_match_haven_net() {
            assert_eq!(DEFAULT_DERP_BIND, haven_net::DEFAULT_DERP_BIND);
            assert_eq!(DEFAULT_PATH_ROUTER_BIND, haven_net::DEFAULT_PATH_ROUTER_BIND);
            assert_eq!(DEFAULT_TURN_BIND, haven_net::DEFAULT_TURN_BIND);
            assert_eq!(DEFAULT_TURN_USER, haven_net::DEFAULT_TURN_USER);
            assert_eq!(MEDIA_SCOPE_BODY, haven_net::blobstore::MEDIA_SCOPE_BODY);
            assert_eq!(RELAY_INTERFACE_KEY, haven_net::blobstore::RELAY_INTERFACE_KEY);
            assert_eq!(LIST_DIGEST_HEADER, haven_net::httprelay::LIST_DIGEST_HEADER);
        }

        #[test]
        fn media_scope_key_matches_haven_net() {
            for (r, c) in [("abc123", "default"), ("", ""), ("ref.with.dots", "circle/with/slash")] {
                assert_eq!(media_scope_key(r, c), haven_net::blobstore::media_scope_key(r, c));
            }
        }

        #[test]
        fn front_door_mode_matches_haven_net() {
            use haven_net::cfquicktunnel::FrontDoorMode as Native;
            for s in ["auto", "manual", "external", "announce", "bundled", "named", "token", " MANUAL ", "", "nonsense"] {
                assert_eq!(FrontDoorMode::parse(s).as_str(), Native::parse(s).as_str(), "{s:?}");
            }
        }

        #[test]
        fn url_helpers_match_haven_net() {
            for u in [
                "relay.example.com", "https://relay.example.com/", "http://a.b:8080/x/", "", "  ", "localhost",
                "https://[::1]:3340/derp", "https://x.trycloudflare.com?q=1", "ftp://nope.example.com",
            ] {
                assert_eq!(
                    normalize_public_url(u).map_err(|e| e.to_string()),
                    haven_net::cfquicktunnel::normalize_public_url(u).map_err(|e| e.to_string()),
                    "{u:?}"
                );
                assert_eq!(host_from_http_url(u), haven_net::host_from_http_url(u), "{u:?}");
            }
            let media = vec![
                "https://relay.example.com".to_string(),
                "https://x.trycloudflare.com".to_string(),
                "https://relay.example.com/again".to_string(),
                "http://[2001:db8::1]:8674".to_string(),
            ];
            for lan in [None, Some("192.168.1.5"), Some("127.0.0.1"), Some("::1"), Some(" ")] {
                assert_eq!(suggest_turn_urls(&media, lan, 3478), haven_net::suggest_turn_urls(&media, lan, 3478));
            }
        }

        #[test]
        fn turn_url_parsing_matches_haven_net() {
            for v in [
                serde_json::json!(["turn:a:3478", " turns:b:5349 ", "stun:c:3478", 7]),
                serde_json::json!("turn:solo:3478"),
                serde_json::json!(" turn:padded:3478 "),
                serde_json::json!("http://not-turn"),
                serde_json::json!(null),
                serde_json::json!({"turn": "x"}),
            ] {
                assert_eq!(parse_turn_urls(&v), haven_net::parse_turn_urls(&v), "{v}");
            }
        }

        #[test]
        fn auth_header_verifies_like_haven_nets() {
            // Same builder underneath (`haven_p2p::httpauth`); the shapes must agree field for field.
            let ours = auth_header(&[9u8; 32], "tok", "GET", "haven/x", b"");
            let theirs = haven_net::httprelay::auth_header(&[9u8; 32], "tok", "GET", "haven/x", b"");
            let fields = |h: &str| h.strip_prefix("Haven ").unwrap().split('.').map(|p| p.len()).collect::<Vec<_>>();
            assert_eq!(fields(&ours), fields(&theirs));
            assert_eq!(ours.split('.').next(), theirs.split('.').next(), "same node id");
        }
    }
}
