//! Embedded **iroh-relay (DERP)** role for the Haven circle relay.
//!
//! Cross-NAT peers that cannot hole-punch need an HTTPS/WebSocket packet relay. When a circle
//! hosts this role, clients put its public URL in their iroh `RelayMap` and **stop depending on
//! n0's public fleet** (n0 remains only when no Haven DERP URL is known).
//!
//! ## Scar guard
//!
//! The DERP process binds **its own** listen socket. It must **not** open a second iroh
//! `Endpoint` under the relay's node key (`reference_iroh_same_key_second_endpoint`). Peers
//! connect *to* this server; the Haven `RelayNode` remains the only endpoint under `cfg.seed`.
//!
//! ## Front door
//!
//! Listens on plain HTTP (default `127.0.0.1:3340`). Cloudflare / Manual terminates TLS and
//! reverse-proxies to this bind — same pattern as the `:8674` media mailbox. Prefer a stable
//! hostname for production; free trycloudflare works if re-announced every restart.

use std::net::SocketAddr;

use anyhow::{anyhow, Context, Result};
use iroh_relay::server::{RelayConfig as IrohRelayConfig, Server, ServerConfig};

/// Config for the optional DERP role.
#[derive(Clone, Debug)]
pub struct DerpConfig {
    /// Master switch. Default **true** for local-disk always-on relays (the fabric path).
    pub enabled: bool,
    /// Local bind for the iroh-relay HTTP listener (TLS off — edge terminates).
    pub bind: String,
    /// Public HTTPS base peers put in their `RelayMap` / gossip as `derp_url`.
    /// Empty = inherit the media front-door public URL at runtime.
    pub public_url: String,
}

impl Default for DerpConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            bind: "127.0.0.1:3340".into(),
            public_url: String::new(),
        }
    }
}

impl DerpConfig {
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }
}

/// Guard for a running DERP server. Drop aborts the server task.
pub struct DerpServer {
    /// Public HTTPS URL clients should use (may match media URL or a sibling hostname).
    pub public_url: String,
    /// Local bind actually used.
    pub local_addr: SocketAddr,
    _server: Server,
}

impl DerpServer {
    /// Start the embedded iroh-relay when `cfg.enabled`.
    pub async fn spawn(cfg: &DerpConfig) -> Result<Option<Self>> {
        if !cfg.is_enabled() {
            return Ok(None);
        }
        let bind: SocketAddr = cfg
            .bind
            .parse()
            .with_context(|| format!("invalid --derp-bind {}", cfg.bind))?;

        // Plain HTTP; cloudflared / nginx supplies TLS. Access = allow all peers that can
        // reach the front door (circle membership is enforced by who learns the URL via
        // sealed announce — same trust model as n0 public relays, federated per circle).
        let mut config = ServerConfig::default();
        config.relay = Some(IrohRelayConfig::new(bind));
        config.quic = None;
        let server = Server::spawn(config)
            .await
            .map_err(|e| anyhow!("iroh-relay server spawn: {e:?}"))?;

        let local_addr = server.http_addr().unwrap_or(bind);

        let public_url = cfg.public_url.trim().trim_end_matches('/').to_string();
        eprintln!(
            "✓ iroh DERP (Haven fabric) listening on {local_addr}{}",
            if public_url.is_empty() {
                String::new()
            } else {
                format!(" → public {public_url}")
            }
        );
        eprintln!(
            "  peers use this as RelayMap entry (HTTPS). Prefer Manual/named tunnel for a stable hostname."
        );

        Ok(Some(Self {
            public_url,
            local_addr,
            _server: server,
        }))
    }
}
