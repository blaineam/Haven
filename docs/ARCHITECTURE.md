# Architecture

## Layer cake

```
┌─────────────────────────────────────────────────────────────┐
│  UI                                                           │
│   • Apple: SwiftUI app (iOS / macOS)  ── UniFFI ─┐            │
│   • Android: Jetpack Compose          ── UniFFI ─┤            │
│   • Win/Linux: Tauri WebView2 ── Rust backend ───┤ (direct)   │
├──────────────────────────────────────────────────┼───────────┤
│  haven-p2p  (Rust — ONE implementation for all)    ▼           │
│   identity   hybrid-PQ crypto   links   social engine   media │
│                         │                                     │
│   transport seam  ──►  path-selector: nearby → iroh → relay   │
├──────────────────────────────────────────────────────────────┤
│  Network                                                      │
│   nearby (MultipeerConnectivity) · iroh QUIC · relay (iroh)   │
│   discovery: iroh n0 / signed records (no central directory)  │
└──────────────────────────────────────────────────────────────┘
```

> Every client links the *same* Rust core: Apple and Android through UniFFI (Swift /
> Kotlin), and the Windows/Linux Tauri app links it **directly** as a Rust crate (its
> backend is Rust, so no FFI hop). All run a real native iroh peer. The web client was
> abandoned (a browser can't be an iroh peer — no raw UDP / NAT hole-punch), so there is
> no WASM UI; `web/` is now just an invite-landing page.

**Invariant:** everything above the transport seam deals only in hybrid-PQ
encrypted bytes. The transport is interchangeable; the crypto is transport-blind.

## The core (`core/haven-p2p`)

| Module | Responsibility | Status |
|---|---|---|
| `identity` | On-device keypair (Ed25519 + ML-DSA-65 + X25519 + ML-KEM-768); public `HavenId`; routable node id; tamper-check hash | ✅ implemented + tested |
| `crypto` | Hybrid-PQ KEM (X25519 + ML-KEM-768 → HKDF) and AES-256-GCM seal/open | ✅ implemented + tested |
| `link` | `haven://` and `https://` reach-me links/QR; parse, verify, MITM check | ✅ implemented + tested |
| `social` | Circles, posts, stories, comments, reactions, edit/unsend, DMs, media + music refs — events sealed E2E under a per-circle epoch key (group keying), hybrid-signed; `build_feed` reducer | ✅ implemented + tested |
| `groupkey` | Epoch sender-keys: per-circle epoch key distributed via the hybrid KEM (KeyCommit), per-event key derivation, rotation on add/remove for cryptographic revocation + bounded forward secrecy | ✅ implemented + tested |
| `device` / `selfsync` | Per-device credentials + signed device list; `AccountState` CRDT self-sealed to the account's own devices (roster/contacts/profile/settings/blocked/read state converge across devices) | ✅ implemented + tested |
| `transport` (`haven-net`) | iroh QUIC `Node` (listen/dial, sealed payloads); mesh-relay frames; S3-over-iroh tunnel | ✅ implemented + tested |
| `groups` (MLS) | Harden the epoch-key layer to `mls-rs` with a hybrid-PQ ciphersuite (per-message forward secrecy / efficient membership) | ⏳ planned |
| `discovery` | Resolve a node id to a live address (iroh n0 today; signed DHT records later) | 🟡 iroh discovery in use |
| `blobs` | Content-addressed (BLAKE3) chunked media transfer (32 KB sealed chunks peer-to-peer; 8 MB chunks over the relay/S3 mailbox) | ✅ implemented |
| FFI | UniFFI → Swift (Apple) + Kotlin (Android) | ✅ implemented |

## How a photo gets from A to B (target flow)

> **Today vs. target:** the implemented engine seals each event under a rotating per-circle
> **epoch key** (sender-keys group keying — see [`GROUP-KEYING.md`](GROUP-KEYING.md)), which
> already gives cryptographic revocation and bounded forward secrecy. Full MLS hardening
> (per-message forward secrecy / efficient membership) is still planned; the flow below reads
> "group/MLS" as the target shape.

1. **A** has **B**'s `HavenId` (from a prior QR/link approval). A is a member of the
   shared circle (group) with B.
2. A optionally **auto-optimizes** the media (HEVC/HEIF/AAC) or sends the original
   losslessly if chosen. The file is chunked and content-addressed (BLAKE3).
3. A derives a content key for B's group via MLS, **seals** the chunks (AES-256-GCM
   under a hybrid-PQ-derived key), and addresses them to B's node id.
4. The **path-selector** picks the route: Bluetooth if nearby and small; local WiFi
   for bulk; relay only if nothing local is reachable. Discovery resolves B's
   current address from the DHT by B's node id.
5. **B** pulls/receives the sealed chunks over whatever path won, verifies each
   chunk hash, decrypts, and (if B was offline) the chunks were held by the fallback
   chain: sender-online → group-gossip cache → B's own storage pin.

## The offline-delivery fallback chain

Because there's no central store, large content for an offline peer falls through:

1. **Sender stays online** — direct, zero cost.
2. **Group-gossip cache** — other online group members opportunistically cache &
   forward the *encrypted* chunks for the offline member.
3. **Relay mailbox / BYO storage pin** — encrypted blobs park on a **Haven relay
   mailbox** (the in-app relay or the `haven-relay` daemon) or the recipient's *own*
   **S3-compatible bucket** (S3/R2/B2/MinIO) until pulled.

## Clients

- **Apple (iOS / iPadOS + macOS):** SwiftUI on the Rust core via UniFFI. Full transport
  ladder (nearby MultipeerConnectivity + iroh + relay), Secure-Enclave-wrapped seed +
  Keychain, MusicKit, WebRTC calls, on-device `SensitiveContentAnalysis`. macOS ships from
  a **native AppKit/SwiftUI target** (`HavenMac`); **Mac Catalyst was dropped 2026-06-23**
  (see [`MACOS-NATIVE-PORT.md`](MACOS-NATIVE-PORT.md)). A user's own Apple devices take
  per-device transport identities and converge their epoch keys, so posts/DMs sync across
  them (see [`MULTI-DEVICE.md`](MULTI-DEVICE.md)).
- **Android (native, in progress):** Jetpack Compose + the *same* Rust core via UniFFI
  Kotlin bindings — a real iroh peer, not a browser. Android Keystore for keys. Feed, DMs
  (incl. the delete-watermark, group-DM sender rows, pinned+sorted conversations, and
  own-device sync), stories, media chunks, WebRTC calls, notifications, and nearby are
  ported. The web client was abandoned (browsers can't be iroh peers); `web/` is now an
  invite-landing page only.
- **Windows / Linux (Tauri 2, in progress):** a WebView2/WebKit frontend over a **Rust**
  backend that links the core **directly** (`haven_ffi` as a crate — no UniFFI hop, since
  the process is itself Rust). The iroh peer runs natively, so this is a real peer, not a
  thin web client. Keys live in the OS secure store (Credential Manager / Secret Service)
  via `keyring`. The *same binary* runs headless as the circle relay/mailbox
  (`--headless`), like the invisible Mac relay. See [`WINDOWS-PORT.md`](WINDOWS-PORT.md).

## Relays (`relay/`)

Two roles, both federated, swappable, and runnable by anyone — never a central
service. Full detail in [`RELAY-AND-DEPLOY.md`](RELAY-AND-DEPLOY.md).

- **Connection relay** — a stateless dumb pipe that forwards encrypted QUIC/WebRTC
  traffic between live peers that can't NAT-punch directly. Never decrypts or stores.
- **Storage relay ("mailbox")** — mostly object storage (S3/R2/B2/GCS) + a thin
  broker, holding E2E-encrypted blobs for offline peers (rung 3 of the fallback
  chain). This is the BYO / quota'd-bucket model — the user's own storage, or any
  community member's, never required to be yours.

Both run with **hardened, no-log defaults**; IPs are never logged or persisted, and there
is no account, name or email in the system to tie one to — though a relay does authenticate
peers by node id (= their public key) to enforce membership, so `IP ↔ node id` is visible to
it in memory while it moves bytes (see `THREAT-MODEL.md`). IP privacy is **relay-mediated**
(peers never see each other's IP)
plus run-behind-your-own-VPN or a relay/discovery node you host yourself; a Tor/onion
transport was evaluated and declined (iroh is UDP/QUIC and Tor's SOCKS can't carry UDP —
see `TOR.md`). A **`haven-relay`** deployment tool stands
either role up on most clouds in one command.
