# Embedded iroh-relay + circle gossip

**Branch:** `feature/iroh-relay-gossip`  
**Status:** R0–R2 + in-app host DERP + dual free tunnels + dedicated DERP URL pref.  
**Design parent:** [`RESILIENCE-DESIGN.md`](RESILIENCE-DESIGN.md) R0–R2, [`DECENTRALIZED-DISCOVERY.md`](DECENTRALIZED-DISCOVERY.md),  
[`CLOUDFLARE-TUNNEL.md`](CLOUDFLARE-TUNNEL.md#later-embed-open-source-iroh-relay-behind-the-same-tunnel).

## Why

n0's public DERP + DNS are free and fine as **fallback**. They must not be the only path:

1. **NAT fallback** — two cross-NAT peers need *some* HTTPS/WebSocket relay when hole-punch fails.  
   Answer: embed open-source **iroh-relay** in `haven-relay` / in-app host, fronted by cloudflared / Manual.
2. **Finding the relay URL** — trycloudflare hostnames are **ephemeral**. A static map is wrong.  
   Answer: **circle gossip** of the current public URL (`RelayBook.derp_url` / frame 19 `derp`).

If n0 dies, a circle with ≥1 live Haven relay (mailbox + DERP + announce) keeps working for members
who can still reach that relay's public front door.

## Policy (shipping)

| Fabric known? | iroh `RelayMap` | WebRTC ICE |
|---|---|---|
| No Haven DERP URL | n0 public fleet | Google STUN |
| ≥1 Haven DERP URL | **Haven only** (n0 off) | **Host candidates only** (empty ICE server list; no Google) |

### WebRTC when fabric is active (read this)

Empty ICE is **intentional**, not a missing wire-up:

- Live **messaging** rides iroh QUIC; with fabric active it uses circle DERP instead of n0.
- **Calls** are a separate WebRTC path. Without STUN/TURN, only host (and same-LAN) candidates work.
- Cross-NAT **calls** may fail while fabric is active until Haven TURN ships.
- We **do not** silently re-add Google STUN when fabric is present (no-Google product rule).
- Do **not** stub a fake TURN URL — a real TURN role on haven-relay is future work.

Surfaces: Apple `HavenFabric.iceServerUrls()`, Android `CallManager.iceServers()`, desktop `iceServers()` in `ui/app.js`.

## R0 (done)

| Piece | Location |
|---|---|
| `haven_endpoint_builder()` | `core/haven-net/src/endpoint_builder.rs` |
| All four bind sites routed through it | `lib.rs`, `blobstore.rs`, `s3tunnel.rs` (×2) |
| `EndpointPolicy` + `apply_derp_urls` (Haven-first) | same module |
| `RelayEntry.derp_url` + `upsert(..., derp_url)` | `discovery.rs` |

## R1 — embed iroh-relay (done in CLI + in-app)

- `haven-relay` embeds `iroh-relay` server (`--derp` default ON for local disk; `--no-derp` to opt out).
- In-app host (Mac FFI `DerpServerHandle`, desktop `haven_net::DerpServer`) uses the same socket role.
- Bind **its own** listen socket (default `127.0.0.1:3340`) — **not** a second iroh `Endpoint`
  under the relay's node key (same-key scar).
- Public URL: `--derp-url` / prefs `relay_derp_url` / `haven.relay.derpURL`, or inherit media front-door URL.
- Writes `<data>/interface.json` + prints a one-line JSON for the app to paste (CLI + desktop headless).

```sh
haven-relay run --link <code> --http-url https://relay.example.com --derp-url https://derp.example.com
# → paste the printed {"node","urls","token","derp"} into Haven Storage → Connect external relay
```

Point the tunnel/proxy so media reaches `:8674` and DERP reaches `:3340` (path rules or sibling
hostnames). Free trycloudflare is one origin per process — auto mode spins **two** tunnels.

## R2 — gossip the map (done on clients)

- Frame 19 JSON: `{"node","urls","token","derp","addedAt"}`.
- **Apple / Android / desktop** learn `derp` on announce; re-announce on adopt/host.
- Adopt accepts bare 64-hex **or** the interface JSON (media + fabric in one paste).
- Desktop: `apply_derp_urls` **before** `HavenNode::start` + on every learn; `haven-fabric` event
  → WebView (`rebindPending` when fabric first appears mid-session → one-shot restart hint).
- Apple: `HavenFabric` + FFI `applyDerpUrls` via `RelayMailboxStore.refreshHavenFabric` (before
  node start + on learn); WebRTC via `iceServerUrls()`.
- Android: `refreshHavenFabric` → prefs + `applyDerpUrls` **before** `HavenNode.start` + on learn;
  `CallManager.iceServers()`.

### Bind-time limit (do not paper over)

iroh takes `RelayMode` / `RelayMap` when the `Endpoint` is constructed. `apply_derp_urls` updates
the **process policy** for the next `haven_endpoint_builder().bind()` only. There is **no**
low-risk hot rebind of a live `HavenNode` today (AddressLookup can hot-add; RelayMap cannot).
Shipping posture:

1. Apply fabric from prefs **before** every cold `HavenNode::start` / `Node::spawn`.
2. On mid-session learn, still call `apply_derp_urls` so late secondary binds + next launch are
   Haven-first; live messaging node keeps its construct-time map until process restart.
3. Desktop surfaces a **one-shot toast** when `rebindPending` becomes true (fabric first learned
   while node is already bound). Full soft-reconnect (stop + re-start node in place) is deferred —
   high state-churn risk; restart the app when convenient.

## R3 — AddressLookup over HVD1 (next)

- Wire existing `discovery::AddrRecord` publish/resolve as an iroh `AddressLookup`.
- n0 DNS stays as concurrent fallback until R5.
- **Light slice landed:** `AddrRecord::derp_urls` / `relay_addr` / `push_derp_url` — discovery
  records can carry `relay:https://…` fabric hints in the existing wire format; resolvers can
  `merge_derp_urls` without a full lookup shim.

## In-app host (Mac / desktop GUI / headless)

In-app host embeds the same **iroh-relay** role as the CLI (`haven_net::DerpServer` /
FFI `DerpServerHandle`):

| Front door | Media | DERP fabric |
|---|---|---|
| **Auto (free trycloudflare)** | Quick tunnel → `:8674` | **Second** quick tunnel → `:3340` (one origin per process) |
| **Manual / named** | Operator URL → `:8674` | Dedicated DERP URL pref if set; else same public host (must path-route `:3340`) |
| **LAN only** | LAN IPs | Local bind only until a public URL exists |

### Dedicated DERP URL pref (named dual-role)

| Surface | Key |
|---|---|
| Desktop prefs | `relay_derp_url` (JSON) / Relays sheet “DERP fabric URL” |
| Apple (Mac) | `UserDefaults` `haven.relay.derpURL` / Storage + Relays front-door controls |
| CLI | `--derp-url` |

Empty dedicated DERP → named/manual **reuses the media public URL** (operator must path-route
`:3340` on that host). Sibling hostname example:

```text
https://relay.example.com  →  http://127.0.0.1:8674   (media)
https://derp.example.com   →  http://127.0.0.1:3340   (fabric)
```

Set the second URL in the DERP pref / `--derp-url`. See [`CLOUDFLARE-TUNNEL.md`](CLOUDFLARE-TUNNEL.md).

### Headless desktop

`haven-desktop --headless` (or the headless entry) calls `start_hosting`, which starts media HTTP
**and** embedded DERP, writes `<relay_dir>/interface.json`, and prints the same paste blob as CLI.

Stop hosting drops both cloudflared children + the DERP server.

## Ephemeral tunnels (product rule)

- **Never** bake trycloudflare names into the app binary.
- Host **re-publishes** on every start into the **circle** (frame 19).
- Peers online learn via gossip; offline peers learn when they next sync.
- Prefer named CF tunnel / Manual domain for always-on operators.

## Scar guards

- DERP server ≠ second endpoint under node key  
- All binds through `haven_endpoint_builder`  
- Discovery answers are hints; QUIC identity is end-to-end  
- WebRTC does not re-add Google when fabric is active  
