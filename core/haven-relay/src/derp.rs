//! Optional **iroh-relay (DERP)** role for the Haven circle relay.
//!
//! ## Why this file exists
//!
//! Cross-NAT peers that cannot hole-punch need an HTTPS/WebSocket packet relay. Today that is
//! n0's public fleet (via the `N0` preset). This module is the home for hosting the **open-source**
//! `iroh-relay` server *next to* the mailbox + HVR1 roles, fronted by the same cloudflared /
//! Manual public URL the operator already uses for `:8674`.
//!
//! ## Scar guard (read before implementing the server)
//!
//! The DERP process must bind **its own** listen socket. It must **not** open a second iroh
//! `Endpoint` under the relay's node key — that is the same-key second-endpoint bug
//! (`reference_iroh_same_key_second_endpoint`). Peers connect *to* this server; the Haven
//! `RelayNode` remains the only endpoint under `cfg.seed`.
//!
//! ## Status
//!
//! Scaffold only on `feature/iroh-relay-gossip`. Wiring `iroh-relay` `server` + CF path routing
//! is the next commit series (R1 in `docs/IROH-RELAY-GOSSIP.md`).

#![allow(dead_code)] // R1 will call spawn from runner; kept linked so the type surface is stable.

use anyhow::Result;

/// Config for the optional DERP role.
#[derive(Clone, Debug, Default)]
pub struct DerpConfig {
    /// Master switch. Default **false** — operator must opt in.
    pub enabled: bool,
    /// Local bind for the iroh-relay HTTP(S) listener (e.g. `127.0.0.1:3340`).
    /// cloudflared / Manual should proxy a public hostname to this address.
    pub bind: String,
    /// Public HTTPS base peers put in their `RelayMap` (and we gossip as `RelayEntry.derp_url`).
    /// May equal the mailbox public URL when path-routed, or a sibling hostname.
    pub public_url: String,
}

impl DerpConfig {
    pub fn is_active(&self) -> bool {
        self.enabled && !self.public_url.trim().is_empty()
    }
}

/// Guard for a running DERP server. Drop stops it.
pub struct DerpServer {
    pub public_url: String,
}

impl DerpServer {
    /// Start the embedded iroh-relay when `cfg.enabled`.
    ///
    /// Currently a **no-op placeholder** that returns `Ok(None)` so the binary still links and
    /// operators can begin wiring config/CLI. R1 replaces this with a real `iroh_relay::server`.
    pub async fn spawn(cfg: &DerpConfig) -> Result<Option<Self>> {
        if !cfg.is_active() {
            return Ok(None);
        }
        // R1: spawn iroh-relay server on cfg.bind; do not touch the Haven Endpoint.
        tracing_or_eprintln(
            "derp: enabled in config but server not yet linked — public_url will still be gossiped when R1 lands",
        );
        let _ = &cfg.bind;
        Ok(Some(Self {
            public_url: cfg.public_url.trim().trim_end_matches('/').to_string(),
        }))
    }
}

fn tracing_or_eprintln(msg: &str) {
    // haven-relay deliberately avoids a heavy log stack in the happy path; stderr is enough for
    // an operator running in a terminal / systemd journal.
    eprintln!("  note: {msg}");
}
