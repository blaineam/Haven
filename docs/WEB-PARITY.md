# Web client — in development (reopened 2026-11-19)

**Status: being built on `feat/web-client`. Not shipped. See D21 in [`DECISIONS.md`](DECISIONS.md).**

The web client was abandoned on 2026-06-22 (history at the bottom). The reason then was
structural: a browser cannot be a Haven peer, and the only workable shape needed a public server
every circle would depend on. That reason no longer holds, because of things that shipped since:

- **A circle-hosted HTTPS front door.** The relay's path proxy serves the sealed-media mailbox,
  the iroh relay (DERP, a WebSocket) and the call hairpin on one hostname
  ([`CLOUDFLARE-TUNNEL.md`](CLOUDFLARE-TUNNEL.md)). A tab needs only outbound HTTPS/WSS to it, and
  it is the circle's own relay, not a server of Haven's.
- **Seedless enrollment (1.0.7).** A linked device holds a device key and a credential and never
  receives the master seed ([`MULTI-DEVICE.md`](MULTI-DEVICE.md)). The deleted `haven-wasm` crate
  wanted the seed in `localStorage`; a browser device never has it at all.
- **iroh runs in a browser** as a relay-only endpoint.

## What a web device is

A **seedless linked device** like any other, enrolled from one of your existing devices and
revocable from them. It is a real node on the same protocol — the same engine compiled to
WebAssembly, the same `haven/social/0` wire, the same signed-HTTP mailbox — with one difference:
its only network path is the circle relay. Nothing in the protocol or the relay's authorization is
special-cased for it.

Two session modes are planned:

| Mode | Device key | Needs |
|---|---|---|
| **My computer** | Persists, wrapped by a non-extractable browser key | A stable relay hostname (a named tunnel or your own domain — a quick tunnel's hostname changes on every restart and takes the browser's storage with it) |
| **Public computer** | In memory only; revoked when the tab closes | — |

There is **no web sign-up**. Creating an account in a browser would put the master seed there. A
web device is always linked from an existing device.

## What the web client trusts (read this before using one)

The page's code has to come from somewhere, and whoever delivers it can change it. For a web
session that is **the relay host, the tunnel provider in front of it (it terminates TLS), and
any network that inspects TLS** — which includes exactly the locked-down networks a web client is
for. Sealed data survives all three; code does not. Nothing in a browser fully closes this.

So the design bounds the damage instead of pretending it away: a compromised web session can read
and post **as that one device until it is revoked**. It never holds the master seed, cannot
authorize other devices, and loses access to new content when revoked (the epoch rotates). Native
apps remain the stronger client, and the UI will say so. Web access is off unless a circle's
owner turns it on, because other members' posts become readable in that browser.

## What a browser cannot do

| Limit | Effect |
|---|---|
| No direct peer connections | Everything rides the circle relay: slower media, and the web client works only while that relay is online |
| No background life | Notifications with the tab closed need Web Push; nothing else runs |
| No Bluetooth / nearby mesh | Nearby delivery is unavailable |
| Cannot host a relay | Hosting stays on the native apps and `haven-relay` |
| Bring-your-own S3 | Each bucket needs CORS enabled |

## Where it lives

| Piece | Path |
|---|---|
| Browser core: engine + relay-only transport (wasm32 only) | `core/haven-web` |
| Build → `web-client/pkg` | `web-client/build.sh` |
| Transport smoke (headless Chromium vs. the native wire) | `web-client/smoke/smoke.mjs`, `core/haven-net/examples/web_peer.rs` |
| Request signing shared by relay, native clients and browser | `core/haven-p2p/src/httpauth.rs` |

`haven_ffi` (the engine) now builds for `wasm32-unknown-unknown`: its native-only parts — the iroh
node, relay/DERP/path-proxy hosting, the S3 client — are compiled out there, and the browser
supplies the transport. `web/` is still only the static invite-landing site.

## Progress

- [x] Engine and crypto core compile to WebAssembly; the engine self-test passes in Chromium.
- [x] Relay-only iroh node in a tab: reaches a native node and is reached by one, through a circle
      DERP, sender ids authenticated, 2 MiB frames (`web-client/smoke`).
- [ ] Seedless enrollment of a tab from a native device.
- [ ] Signed mailbox over `fetch`, same-origin with the relay; the relay serves the bundle.
- [ ] One sealed message each way between a tab and a native device.
- [ ] The same through a real Cloudflare tunnel.
- [ ] Engine IO loop in the browser (what `desktop/src-tauri/src/engine.rs` does natively), storage.
- [ ] Responsive UI (phone → desktop), from `desktop/ui`.
- [ ] Calls (WebRTC + the relay hairpin), Web Push.
- [ ] Tamarin model for the web device class + CI guards, before any release.

## History — why it was abandoned (2026-06-22)

Browsers cannot accept inbound connections or do raw UDP/QUIC, so a tab can never hole-punch into
the mesh. The only shape that could work was a thin client of a publicly-hosted WSS → iroh bridge,
which meant "a server everyone depends on" — the thing Haven exists to avoid. The `web/engine/`
client was removed, and `core/haven-wasm` was deleted in the 2026-07 security audit (it recommended
storing the seed in `localStorage`). The "open a tab to keep your circle warm" idea became the
in-app RelayHost and `haven-relay`; the second platform became native Android.
