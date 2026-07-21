# Embedded iroh-relay + circle gossip

**Branch:** `feature/iroh-relay-gossip`  
**Status:** R0 landed (endpoint chokepoint + `RelayBook.derp_url`). R1–R3 in progress.  
**Design parent:** [`RESILIENCE-DESIGN.md`](RESILIENCE-DESIGN.md) R0–R2, [`DECENTRALIZED-DISCOVERY.md`](DECENTRALIZED-DISCOVERY.md),  
[`CLOUDFLARE-TUNNEL.md`](CLOUDFLARE-TUNNEL.md#later-embed-open-source-iroh-relay-behind-the-same-tunnel).

## Why

n0's public DERP + DNS are free and fine as **fallback**. They must not be the only path:

1. **NAT fallback** — two cross-NAT peers need *some* HTTPS/WebSocket relay when hole-punch fails.  
   Answer: embed open-source **iroh-relay** in `haven-relay`, fronted by cloudflared / Manual.
2. **Finding the relay URL** — trycloudflare hostnames are **ephemeral**. A static map is wrong.  
   Answer: **circle gossip** of the current public URL (`RelayBook.derp_url`, gen LWW).

If n0 dies, a circle with ≥1 live Haven relay (mailbox + DERP + announce) keeps working for members
who can still reach that relay's public front door.

## R0 (done on this branch)

| Piece | Location |
|---|---|
| `haven_endpoint_builder()` | `core/haven-net/src/endpoint_builder.rs` |
| All four bind sites routed through it | `lib.rs`, `blobstore.rs`, `s3tunnel.rs` (×2) |
| `EndpointPolicy` (flags default OFF → n0) | same module |
| `RelayEntry.derp_url` + `upsert(..., derp_url)` | `discovery.rs` |
| `derp_urls_from_book` / `apply_book_to_policy` | `endpoint_builder.rs` |

Default behavior is **byte-identical to stock N0** until `prefer_custom_relays` is set and the book
has DERP URLs.

## R1 — embed iroh-relay (next)

- Add optional server role in `haven-relay` (`iroh-relay` crate `server` feature).
- Bind **its own** listen socket (HTTP/HTTPS or plain for CF to TLS-terminate) — **not** a second
  iroh `Endpoint` under the relay's node key (same-key scar).
- Front with the same CF/Manual URL as `:8674` (path routing or sibling hostname).
- Operator flag: `--derp` / config; announce `derp_url` into circle book on host start.

## R2 — gossip the map

- Frame 19 / sealed relay announce carries `derp_url` + http base.
- Members merge into `RelayBook` (existing LWW rules).
- Tunnel restart → new trycloudflare name → `upsert` higher gen; dead names fall out of `live()`.
- Call `apply_book_to_policy(&book, true)` before next endpoint rebind (hot-reload of live endpoints
  is a later refinement; iroh maps are largely bind-time today).

## R3 — AddressLookup over HVD1

- Wire existing `discovery::AddrRecord` publish/resolve as an iroh `AddressLookup`.
- n0 DNS stays as concurrent fallback until R5.

## Ephemeral tunnels (product rule)

- **Never** bake trycloudflare names into the app binary.
- Host **re-publishes** on every start into the **circle**.
- Peers online learn via gossip; offline peers learn when they next sync.
- Prefer named CF tunnel / Manual domain for always-on operators.

## Scar guards

- DERP server ≠ second endpoint under node key  
- All binds through `haven_endpoint_builder`  
- Discovery answers are hints; QUIC identity is end-to-end  
