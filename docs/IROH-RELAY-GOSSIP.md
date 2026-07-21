# Embedded iroh-relay + circle gossip

**Branch:** `feature/iroh-relay-gossip`  
**Status:** R0–R2 client fabric path landed. In-app Mac/desktop DERP process still CLI-primary.  
**Design parent:** [`RESILIENCE-DESIGN.md`](RESILIENCE-DESIGN.md) R0–R2, [`DECENTRALIZED-DISCOVERY.md`](DECENTRALIZED-DISCOVERY.md),  
[`CLOUDFLARE-TUNNEL.md`](CLOUDFLARE-TUNNEL.md#later-embed-open-source-iroh-relay-behind-the-same-tunnel).

## Why

n0's public DERP + DNS are free and fine as **fallback**. They must not be the only path:

1. **NAT fallback** — two cross-NAT peers need *some* HTTPS/WebSocket relay when hole-punch fails.  
   Answer: embed open-source **iroh-relay** in `haven-relay`, fronted by cloudflared / Manual.
2. **Finding the relay URL** — trycloudflare hostnames are **ephemeral**. A static map is wrong.  
   Answer: **circle gossip** of the current public URL (`RelayBook.derp_url` / frame 19 `derp`).

If n0 dies, a circle with ≥1 live Haven relay (mailbox + DERP + announce) keeps working for members
who can still reach that relay's public front door.

## Policy (shipping)

| Fabric known? | iroh `RelayMap` | WebRTC ICE |
|---|---|---|
| No Haven DERP URL | n0 public fleet | Google STUN |
| ≥1 Haven DERP URL | **Haven only** (n0 off) | Host candidates only (no Google) |

Full TURN on haven-relay is future work; empty ICE when fabric is active is intentional until then.

## R0 (done)

| Piece | Location |
|---|---|
| `haven_endpoint_builder()` | `core/haven-net/src/endpoint_builder.rs` |
| All four bind sites routed through it | `lib.rs`, `blobstore.rs`, `s3tunnel.rs` (×2) |
| `EndpointPolicy` + `apply_derp_urls` (Haven-first) | same module |
| `RelayEntry.derp_url` + `upsert(..., derp_url)` | `discovery.rs` |

## R1 — embed iroh-relay (done in CLI)

- `haven-relay` embeds `iroh-relay` server (`--derp` default ON for local disk; `--no-derp` to opt out).
- Bind **its own** listen socket (default `127.0.0.1:3340`) — **not** a second iroh `Endpoint`
  under the relay's node key (same-key scar).
- Public URL: `--derp-url` or inherit media front-door URL (named tunnel / Manual preferred).
- Writes `<data>/interface.json` + prints a one-line JSON for the app to paste.

```sh
haven-relay run --link <code> --http-url https://relay.example.com --derp-url https://relay.example.com
# → paste the printed {"node","urls","token","derp"} into Haven Storage → Connect external relay
```

Point the tunnel/proxy so the public URL reaches both `:8674` (media) and `:3340` (DERP), via
path rules or sibling hostnames. Free trycloudflare is one origin — use Manual/named for dual roles.

## R2 — gossip the map (done on clients)

- Frame 19 JSON: `{"node","urls","token","derp","addedAt"}`.
- **Apple / Android / desktop** learn `derp` on announce; re-announce on adopt/host.
- Adopt accepts bare 64-hex **or** the CLI interface JSON (media + fabric in one paste).
- Desktop: `apply_derp_urls` + `haven-fabric` event → WebView `__havenFabricDerp`.
- Apple: `HavenFabric` + `WebRTCCall`; Android: `haven.fabric` prefs + `CallManager.iceServers()`.

## R3 — AddressLookup over HVD1 (next)

- Wire existing `discovery::AddrRecord` publish/resolve as an iroh `AddressLookup`.
- n0 DNS stays as concurrent fallback until R5.

## In-app host (Mac / desktop GUI)

In-app host serves the **HTTP mailbox** (+ cloudflared). Full **iroh-relay** is currently the
**CLI / headless** path. GUI may announce a stable (non-trycloudflare) public URL as a DERP
hint when the operator path-routes DERP; for real fabric prefer `haven-relay` on the same box.

## Ephemeral tunnels (product rule)

- **Never** bake trycloudflare names into the app binary.
- Host **re-publishes** on every start into the **circle** (frame 19).
- Peers online learn via gossip; offline peers learn when they next sync.
- Prefer named CF tunnel / Manual domain for always-on operators.

## Scar guards

- DERP server ≠ second endpoint under node key  
- All binds through `haven_endpoint_builder`  
- Discovery answers are hints; QUIC identity is end-to-end  
