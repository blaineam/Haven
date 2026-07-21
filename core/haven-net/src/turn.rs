//! Embedded **TURN** role for circle WebRTC ICE (Haven fabric).
//!
//! When a circle hosts a Haven relay/fabric, peers prefer **circle TURN** for cross-NAT
//! calls instead of empty ICE or Google STUN. This is a separate UDP socket from iroh —
//! **not** a second `Endpoint` under the host's node key (same-key scar).
//!
//! ## Auth
//!
//! Long-lived shared secret (random hex, persisted like `http_token`). Clients use fixed
//! username [`DEFAULT_TURN_USER`] (`haven`) and that secret as the password. Credentials
//! travel only inside the sealed frame-19 announce / interface.json paste.
//!
//! ## Front door
//!
//! UDP (default bind `0.0.0.0:3478`). Unlike DERP (HTTP over cloudflared), free trycloudflare
//! cannot front UDP TURN — operators need LAN reachability, port-forward, or a public host
//! that routes UDP 3478. See `docs/IROH-RELAY-GOSSIP.md`.

use std::net::{IpAddr, SocketAddr};
use std::str::FromStr;
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use turn::auth::{generate_auth_key, AuthHandler};
use turn::relay::relay_static::RelayAddressGeneratorStatic;
use turn::server::config::{ConnConfig, ServerConfig};
use turn::server::Server;
use turn::Error as TurnError;
use webrtc_util::vnet::net::Net;

/// Default local bind for the embedded TURN UDP listener (server-facing).
pub const DEFAULT_TURN_BIND: &str = "0.0.0.0:3478";

/// Fixed TURN username announced to circle members (password = long-lived secret).
pub const DEFAULT_TURN_USER: &str = "haven";

/// STUN/TURN realm used when hashing long-term credentials.
pub const DEFAULT_TURN_REALM: &str = "haven";

/// Config for the optional TURN role.
#[derive(Clone, Debug)]
pub struct TurnConfig {
    /// Master switch.
    pub enabled: bool,
    /// Local UDP bind (default [`DEFAULT_TURN_BIND`]).
    pub bind: String,
    /// IP returned in ALLOCATE responses (what peers use as the relayed address).
    /// Empty → `127.0.0.1` (local-only testing).
    pub public_ip: String,
    /// Long-lived shared secret (password for [`DEFAULT_TURN_USER`]). Required when enabled.
    pub secret: String,
    /// Public TURN URLs to announce, e.g. `turn:host:3478`. Empty = caller fills later.
    pub public_urls: Vec<String>,
}

impl Default for TurnConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            bind: DEFAULT_TURN_BIND.into(),
            public_ip: String::new(),
            secret: String::new(),
            public_urls: Vec::new(),
        }
    }
}

impl TurnConfig {
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }
}

/// Auth: single static user + long-lived shared secret (password).
struct StaticAuth {
    username: String,
    key: Vec<u8>,
}

impl AuthHandler for StaticAuth {
    fn auth_handle(
        &self,
        username: &str,
        _realm: &str,
        _src_addr: SocketAddr,
    ) -> std::result::Result<Vec<u8>, TurnError> {
        if username == self.username {
            Ok(self.key.clone())
        } else {
            Err(TurnError::Other("unauthorized".into()))
        }
    }
}

/// Guard for a running TURN server. Drop stops accepting (tasks exit when the server is dropped).
pub struct TurnServer {
    /// Public TURN URLs clients should put in ICE (`turn:host:port`).
    pub public_urls: Vec<String>,
    /// Local bind actually used.
    pub local_addr: SocketAddr,
    /// Username for ICE (`haven`).
    pub username: String,
    /// Password = long-lived secret.
    pub password: String,
    /// IP advertised in allocations.
    pub public_ip: IpAddr,
    _server: Server,
}

impl TurnServer {
    /// Start embedded TURN when `cfg.enabled`.
    pub async fn spawn(cfg: &TurnConfig) -> Result<Option<Self>> {
        if !cfg.is_enabled() {
            return Ok(None);
        }
        let secret = cfg.secret.trim();
        if secret.is_empty() {
            return Err(anyhow!("turn secret is required when TURN is enabled"));
        }
        let bind: SocketAddr = cfg
            .bind
            .parse()
            .with_context(|| format!("invalid turn bind {}", cfg.bind))?;

        let public_ip_str = cfg.public_ip.trim();
        let public_ip: IpAddr = if public_ip_str.is_empty() {
            IpAddr::from_str("127.0.0.1").unwrap()
        } else {
            IpAddr::from_str(public_ip_str)
                .with_context(|| format!("invalid turn public_ip {public_ip_str}"))?
        };

        let conn = Arc::new(
            tokio::net::UdpSocket::bind(bind)
                .await
                .with_context(|| format!("bind turn UDP {bind}"))?,
        );
        let local_addr = conn.local_addr().unwrap_or(bind);

        let username = DEFAULT_TURN_USER.to_string();
        let key = generate_auth_key(&username, DEFAULT_TURN_REALM, secret);

        let server = Server::new(ServerConfig {
            conn_configs: vec![ConnConfig {
                conn,
                relay_addr_generator: Box::new(RelayAddressGeneratorStatic {
                    relay_address: public_ip,
                    address: "0.0.0.0".to_owned(),
                    net: Arc::new(Net::new(None)),
                }),
            }],
            realm: DEFAULT_TURN_REALM.to_owned(),
            auth_handler: Arc::new(StaticAuth {
                username: username.clone(),
                key,
            }),
            channel_bind_timeout: std::time::Duration::from_secs(0),
            alloc_close_notify: None,
        })
        .await
        .map_err(|e| anyhow!("turn server spawn: {e}"))?;

        let public_urls = if cfg.public_urls.is_empty() {
            // Local default so interface.json is never empty when TURN is up.
            vec![format!("turn:{}:{}", public_ip, local_addr.port())]
        } else {
            cfg.public_urls
                .iter()
                .map(|u| u.trim().to_string())
                .filter(|u| !u.is_empty())
                .collect()
        };

        Ok(Some(Self {
            public_urls,
            local_addr,
            username,
            password: secret.to_string(),
            public_ip,
            _server: server,
        }))
    }

    /// Local UDP port the TURN listener bound.
    pub fn local_port(&self) -> u16 {
        self.local_addr.port()
    }

    /// Best-effort graceful close.
    pub async fn close(self) -> Result<()> {
        self._server
            .close()
            .await
            .map_err(|e| anyhow!("turn close: {e}"))
    }
}

/// Build a standard TURN URI for ICE (`turn:host:port`).
pub fn turn_url(host: &str, port: u16) -> String {
    let h = host.trim().trim_start_matches('[').trim_end_matches(']');
    format!("turn:{h}:{port}")
}

/// Host component of an `http(s)://…` media/DERP URL, if parseable.
pub fn host_from_http_url(url: &str) -> Option<String> {
    let u = url.trim();
    let rest = u
        .strip_prefix("https://")
        .or_else(|| u.strip_prefix("http://"))?;
    let hostport = rest.split('/').next()?.split('?').next()?;
    // Strip port if present; IPv6 in brackets.
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

/// Suggest TURN announce URLs from media front-door host(s) + LAN IP.
///
/// Skips `trycloudflare.com` hosts (UDP cannot ride free CF quick tunnels).
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
    match v {
        serde_json::Value::Array(arr) => arr
            .iter()
            .filter_map(|x| x.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| s.starts_with("turn:") || s.starts_with("turns:"))
            .collect(),
        serde_json::Value::String(s) => {
            let t = s.trim();
            if t.starts_with("turn:") || t.starts_with("turns:") {
                vec![t.to_string()]
            } else {
                Vec::new()
            }
        }
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turn_url_formats() {
        assert_eq!(turn_url("relay.example.com", 3478), "turn:relay.example.com:3478");
        assert_eq!(turn_url("10.0.0.5", 3478), "turn:10.0.0.5:3478");
    }

    #[test]
    fn host_from_http_url_parses() {
        assert_eq!(
            host_from_http_url("https://relay.example.com/path"),
            Some("relay.example.com".into())
        );
        assert_eq!(
            host_from_http_url("https://relay.example.com:8443/"),
            Some("relay.example.com".into())
        );
        assert_eq!(host_from_http_url("not-a-url"), None);
    }

    #[test]
    fn suggest_skips_trycloudflare() {
        let urls = suggest_turn_urls(
            &[
                "https://abc.trycloudflare.com".into(),
                "https://relay.example.com".into(),
            ],
            Some("192.168.1.10"),
            3478,
        );
        assert!(urls.iter().any(|u| u.contains("relay.example.com")));
        assert!(urls.iter().any(|u| u.contains("192.168.1.10")));
        assert!(!urls.iter().any(|u| u.contains("trycloudflare")));
    }

    #[test]
    fn parse_turn_urls_array_and_string() {
        let a = serde_json::json!(["turn:h:3478", "http://nope", "turns:h:5349"]);
        assert_eq!(
            parse_turn_urls(&a),
            vec!["turn:h:3478".to_string(), "turns:h:5349".to_string()]
        );
        let s = serde_json::json!("turn:only:3478");
        assert_eq!(parse_turn_urls(&s), vec!["turn:only:3478".to_string()]);
    }
}
