//! Embedded **iroh-relay (DERP)** role for the Haven circle fabric.
//!
//! Cross-NAT peers that cannot hole-punch need an HTTPS/WebSocket packet relay. When a circle
//! hosts this role, clients put its public URL in their iroh `RelayMap` and **stop depending on
//! n0's public fleet** (n0 remains only when no Haven DERP URL is known).
//!
//! ## Scar guard
//!
//! The DERP process binds **its own** listen socket. It must **not** open a second iroh
//! `Endpoint` under the host's node key (`reference_iroh_same_key_second_endpoint`). Peers
//! connect *to* this server; the Haven messaging node remains the only endpoint under that key.
//!
//! ## Front door
//!
//! Listens on plain HTTP (default `127.0.0.1:3340`). Cloudflare / Manual terminates TLS and
//! reverse-proxies to this bind — usually via the local **path router** (`:8675`) so one public
//! origin fronts media + DERP (`/relay` → here). Prefer a stable hostname for production.
//! Sibling-hostname mode still supports a dedicated DERP front door without the path router.

use std::net::SocketAddr;

use anyhow::{anyhow, Context, Result};
use iroh_relay::server::{RelayConfig as IrohRelayConfig, Server, ServerConfig};

/// Default local bind for the embedded DERP HTTP listener.
pub const DEFAULT_DERP_BIND: &str = "127.0.0.1:3340";

/// Config for the optional DERP role.
#[derive(Clone, Debug)]
pub struct DerpConfig {
    /// Master switch.
    pub enabled: bool,
    /// Local bind for iroh-relay HTTP (TLS off — front door terminates).
    pub bind: String,
    /// Public HTTPS base peers put in their `RelayMap` / gossip as `derp_url`.
    /// Empty = caller fills after tunnel start.
    pub public_url: String,
}

impl Default for DerpConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            bind: DEFAULT_DERP_BIND.into(),
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
            .with_context(|| format!("invalid derp bind {}", cfg.bind))?;

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
        Ok(Some(Self {
            public_url,
            local_addr,
            _server: server,
        }))
    }

    /// Local TCP port the DERP HTTP listener bound.
    pub fn local_port(&self) -> u16 {
        self.local_addr.port()
    }
}
