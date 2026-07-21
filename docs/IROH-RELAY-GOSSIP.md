# Embedded iroh-relay + circle gossip

**Branch:** `feature/iroh-relay-gossip`  
**Status:** R0–R2 + in-app host DERP + dual free tunnels + dedicated DERP URL pref + **circle TURN**.  
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
| No Haven DERP URL | n0 public fleet (**fallback only**) | Google STUN (**fallback only**) |
| ≥1 Haven DERP, no TURN | **Haven only** (n0 **off** — not first path) | **Host only** (no Google); media may use **WSS hairpin** `/webrtc/hairpin` |
| ≥1 Haven DERP **and** TURN URLs | **Haven only** | **Circle TURN** only (`turn:…` + creds) |

### WebRTC when fabric is active (read this)

- Live **messaging** rides iroh QUIC; with fabric active it uses circle DERP instead of n0.
- **Call signaling** (SDP/ICE JSON) is sealed over the same iroh path — it **hairpins** through the
  HTTPS fabric (`/relay` WebSocket) when direct QUIC fails. Signaling does **not** use STUN/TURN.
- **Call media** is WebRTC DTLS-SRTP when ICE works. With circle TURN, hard-NAT media uses UDP TURN.
- Without TURN (fabric active): **no Google STUN** — host candidates + path-proxy **WebSocket hairpin**
  (works over free CF). Desktop falls back to PCM over hairpin if ICE fails.
- n0 / Google are **never first path** when a circle Haven relay fabric is known.

Surfaces: Apple `HavenFabric.iceServersFromDefaults()`, Android `FabricIcePolicy` / `CallManager`,
desktop `iceServers()` in `ui/app.js`.

### Multi-device automated QA

```sh
# Server + policy (Mac CI / laptop)
cargo test -p haven-net --test path_proxy_hairpin
Scripts/fabric-multi-device-qa.sh
node ../_shared/soren/soren.mjs run Haven fabric   # also in release requireGreen
```

Point **iOS Simulator** at `127.0.0.1`, **Android Emulator** at `10.0.2.2` (host), physical
devices at the Mac LAN IP, using the path-proxy origin (`/_haven`, `/webrtc/hairpin`).

### Path proxy (single public origin)

When HTTP is on and there is **no sibling** `--derp-url` / `relay_derp_url`, `haven-relay` starts a
local **path proxy** (default `127.0.0.1:8675`) that routes by path:

| Kind | Paths | Backend |
|---|---|---|
| **Media** | `/k/*`, `/l/*`, `/t/*` | mailbox HTTP (`:8674`) |
| **Fabric** | `/relay`, `/derp`, `/ping` (+ subpaths) | iroh DERP (`:3340`) |
| **Hairpin** | `/webrtc`, `/webrtc/hairpin` | **WebSocket** call-media bipipe (local) |
| **Status** | `/`, `/_haven`, `/_haven/*` | proxy-local JSON route table |
| (unknown) | anything else | `404` with path hints |

Flags: `--proxy-bind <addr>`, `--no-proxy`. Probe: `GET http://127.0.0.1:8675/_haven`.

One cloudflared process (free or named) points at the proxy port. Media public URL and DERP public
URL are the **same** HTTPS host — call signaling hairpins over `/relay`. Sibling hostname mode
(`--derp-url` ≠ media URL) skips the proxy and uses dual-origin. See [`CLOUDFLARE-TUNNEL.md`](CLOUDFLARE-TUNNEL.md).

### WebSocket call-media hairpin (free CF)

UDP TURN cannot ride free trycloudflare. The path proxy exposes a **WebSocket hairpin** that **does**:

```text
wss://<fabric-host>/webrtc/hairpin
```

1. Client opens WebSocket (works through free CF HTTP tunnels).
2. First text frame: `{"v":1,"session":"<callSessionId>","peer":"<myHex>","remote":"<otherHex>"}`.
3. Server pairs both sides (90s wait); then bipipes **binary** frames opaquely.
4. Desktop: opens hairpin during mesh; if WebRTC ICE fails, falls back to PCM audio over the hairpin.
5. Apple: opens hairpin during mesh (connection ready; media fallback can ride the same binary path).

This is **not** stock WebRTC RTP-over-WS — it is a Haven TCP/TLS media pipe for when ICE/TURN cannot path.

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

Default: path router unifies both on one origin (tunnel → `:8675`). Optional sibling `--derp-url`
keeps dual-origin. Free trycloudflare then needs only **one** process when path-routed.

## R2 — gossip the map (done on clients)

- Frame 19 JSON: `{"node","urls","token","derp","turn","turnUser","turnPass","addedAt"}`.
- **Apple / Android / desktop** learn `derp` + `turn` on announce; re-announce on adopt/host.
- Adopt accepts bare 64-hex **or** the interface JSON (media + fabric + TURN in one paste).
- Desktop: `apply_derp_urls` **before** `HavenNode::start` + on every learn; soft-rebind when
  fabric becomes active or DERP URLs change mid-session (`Engine::rebind_transport_for_fabric`,
  2s debounce, concurrent guard). `haven-fabric` event → WebView (`derpUrls` + TURN fields).
- Apple: `HavenFabric` + FFI `applyDerpUrls` via `RelayMailboxStore.refreshHavenFabric`; WebRTC via
  `iceServersFromDefaults()` (circle TURN credentials when known).
- Android: `refreshHavenFabric` → prefs + `applyDerpUrls` + TURN prefs; `CallManager.iceServers()`.

## Circle TURN (WebRTC ICE)

| Piece | Location |
|---|---|
| `TurnServer` / `TurnConfig` | `core/haven-net/src/turn.rs` (`turn` crate 0.17) |
| Default bind | `0.0.0.0:3478` (own UDP socket — **not** a second iroh Endpoint) |
| Auth | username `haven`, password = long-lived hex secret (`turn_token`, like `http_token`) |
| CLI | `--turn` / `--no-turn` / `--turn-bind` / `--turn-url` / `--turn-public-ip` |
| interface.json | `"turn":["turn:host:3478"]`, `"turnUser"`, `"turnPass"` |
| Desktop host | `Engine::start_desktop_turn` with media/DERP |
| Persist | `RelayEntry.turn_urls` / `turn_user` / `turn_pass` (Apple/Android/desktop) |

**Reachability:** free trycloudflare cannot front UDP TURN. Port-forward UDP 3478, use a public IP
with `--turn-url`, or rely on LAN `turn:<lan-ip>:3478`. Fallback: run [coturn](https://github.com/coturn/coturn)
and put its URLs in the same frame-19 / interface.json fields.

```sh
haven-relay run --link <code> --http-url https://relay.example.com \
  --turn-url turn:relay.example.com:3478 --turn-public-ip <public-v4>
# interface.json includes turn + turnUser + turnPass
```

### Bind-time limit (soft rebind, not hot map swap)

iroh takes `RelayMode` / `RelayMap` when the `Endpoint` is constructed. `apply_derp_urls` updates
the **process policy** only. Live endpoints cannot retarget RelayMap in place (AddressLookup can
hot-add; RelayMap cannot). Shipping posture:

1. Apply fabric from prefs **before** every cold `HavenNode::start` / `Node::spawn`.
2. On mid-session learn, call `apply_derp_urls` **and** soft-rebind: `HavenNode::shutdown` (full
   endpoint close — no same-key dual endpoint), then `start` again with the same device seed.
   Desktop re-attaches the in-process relay host without killing cloudflared / embedded DERP.
3. Debounce 2s, guard concurrent rebind, never rebind onto an empty (n0-only) map mid-session.
4. `rebindPending` is true while a rebind is scheduled/in-flight; false after success.

## R3 — AddressLookup over HVD1 (next)

- Wire existing `discovery::AddrRecord` publish/resolve as an iroh `AddressLookup`.
- n0 DNS stays as concurrent fallback until R5.
- **Light slice landed:** `AddrRecord::derp_urls` / `relay_addr` / `push_derp_url` — discovery
  records can carry `relay:https://…` fabric hints in the existing wire format; resolvers can
  `merge_derp_urls` without a full lookup shim.

## In-app host (Mac / desktop GUI / headless)

In-app host embeds the same **iroh-relay** role as the CLI (`haven_net::DerpServer` /
FFI `DerpServerHandle`):

| Front door | Media + DERP |
|---|---|
| **Auto (free trycloudflare)** | One quick tunnel → path router `:8675` (media + DERP by path). Dual free tunnel only if path router fails or sibling DERP URL is set. |
| **Manual / named** | Origin → path router `:8675` when no sibling DERP URL; else media `:8674` + dedicated DERP host |
| **LAN only** | Media `:8674` / DERP `:3340` (or path router) until a public URL exists |

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
- TURN server ≠ second endpoint under node key (own UDP socket only)  
- All binds through `haven_endpoint_builder`  
- Discovery answers are hints; QUIC identity is end-to-end  
- WebRTC uses circle TURN when known; otherwise STUN for srflx only (not a messaging dependency)  


