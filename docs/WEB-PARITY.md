# Web client — ABANDONED (2026-06-22)

**Decision: there is no Haven web client.** A browser tab cannot be a peer on Haven's
network, so the effort was dropped. `web/` is now just a static **invite-landing /
app-promo** page (`web/index.html`) that parses `haven://` invites and points people to
the native app. The WASM client and `web/engine/` were removed. (Android will be a
**native** UniFFI → Kotlin client, not WASM — see [`ANDROID-PARITY.md`](ANDROID-PARITY.md).)

## Why a browser can't be a Haven peer (the hard constraint)
Browsers **cannot accept inbound connections or do raw UDP/QUIC.** A native iroh node
joins the mesh because it can *listen* and NAT-hole-punch; a browser tab cannot. The only
way a web client could work is as a thin client of a **publicly-hosted relay** (a
WSS/WebRTC → iroh bridge) — which means every circle would need a public relay just for
web to function at all. That reintroduces exactly the "a server everyone depends on"
shape Haven exists to avoid, for a half-broken UX. Not worth it.

## What replaced the web ambitions
- **Reach:** the invite-landing page covers the "I got a link without the app" case
  (parse `haven://` → open/install the native app). No engine, no keys, no data.
- **Always-on relay:** the "open a tab to keep your circle warm" idea is served instead
  by the **in-app RelayHost** and the standalone **`haven-relay`** daemon (a real iroh
  peer that can listen) — see [`RELAY-AND-DEPLOY.md`](RELAY-AND-DEPLOY.md) and
  [`HAVEN-NET-RELAY.md`](HAVEN-NET-RELAY.md).
- **Second platform:** **native Android** (Jetpack Compose + the same Rust core via
  UniFFI Kotlin), which *is* a real iroh peer.

## Leftover note
The `core/haven-wasm` crate has been **deleted** (2026-07 security audit) — it was dead
code that, among other things, recommended storing the seed in `localStorage`. No WASM
crate remains in the workspace.
