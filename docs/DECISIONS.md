# Architectural decisions

Each entry is a decision we've committed to, with the reasoning and the honest
trade-off. Newest concerns first.

## D1 — "No surveillance, near-zero cost" instead of "literally no servers"

**Decision:** Allow tiny, swappable, **federated relays** that only route opaque
encrypted blobs and hold zero plaintext / zero PII. They are never load-bearing
for trust, and anyone can run one.

**Why:** Pure zero-server is physically in tension with "reliable, including a web
client." Two phones behind home routers can't always reach each other directly
(~15–20% of connections need a relay due to symmetric/CGNAT). Peers also go
offline, so content needs somewhere to wait. Forcing "sender must stay online"
would wreck the experience for the non-technical family users this is *for*.

**Trade-off:** There is some always-on infrastructure. We make it cheap (a $5 box),
dumb (sees only ciphertext), and federated (no single one matters), and frame the
product promise as *no surveillance / no data collection* rather than *no servers*.

## D2 — Identity is a keypair; no PII

**Decision:** An account is an on-device keypair. The public key is the user id and
routable address. Contacts are added by QR (in person) or link (remote). Recovery
is via passphrase-encrypted escrow in the user's *own* iCloud Keychain / Secure
Enclave + an exportable recovery code.

**Why:** No phone/email means no PII to collect, leak, or subpoena. Public-key
identity is also exactly what the transport layer needs to dial a peer.

**Trade-off:** Losing the key = losing the identity, so recovery UX is a real
problem we own (not the user's email provider's).

## D3 — Group encryption via MLS (`mls-rs`), not pairwise Signal

**Decision:** Use **MLS (RFC 9420)** for all E2E encryption, via AWS's **`mls-rs`**.
1:1 chats are just 2-member groups.

**Why:** The product is *groups* (family, friends), and MLS is built for efficient
group membership changes. `mls-rs` has a pluggable crypto-provider model, which is
what lets us register hybrid post-quantum ciphersuites (see D4) — OpenMLS is more
locked to its built-in suites.

## D4 — Hybrid post-quantum crypto everywhere

**Decision:** Derive every content key from a **hybrid** of classical + PQ:
- KEM: **X25519 + ML-KEM-768** (FIPS 203), mixed via HKDF-SHA256.
- Signatures/identity: **Ed25519 + ML-DSA** (FIPS 204). *(ML-DSA is the next crypto
  addition; the `sign`/`verify` seam is already isolated. Ed25519 ships first.)*
- Symmetric: **AES-256-GCM** (already quantum-resistant).

**Why:** Relays route ciphertext an adversary could store today and crack with a
future quantum computer ("harvest now, decrypt later"). Hybrid means an attacker
must break *both* primitives, so we're never weaker than classical even if young PQC
algorithms are later found flawed. Same approach as Signal PQXDH and Apple PQ3.

**Trade-off:** Slightly larger keys/signatures (ML-KEM ct ~1 KB, ML-DSA sig ~2–3 KB).
Negligible against media; only mildly relevant to tiny text messages.

**Status:** Hybrid PQ **KEM** is implemented and tested (`crypto.rs`). Hybrid PQ
**signatures** are staged next.

## D5 — Transport priority ladder: Bluetooth → local WiFi → relay

**Decision:** A path-selector races available transports and prefers the
cheapest/most-private reachable one: Bluetooth (presence + small payloads) → local
or peer-to-peer WiFi (bulk) → relay (last resort). Bulk transfers skip Bluetooth's
low-bandwidth pipe.

**Why:** Staying off the relay is better for privacy, latency, and cost. Bluetooth
is always-on and works with no network at all; local WiFi is the high-bandwidth lane
for big files.

**Trade-offs / honest limits:**
- Web/Android-web clients **cannot** do Bluetooth or WiFi-direct (no browser API),
  so they always use WebRTC/relay. The rich local mesh is a native superpower.
- Apple↔Android *local* transport is hard (AWDL vs Nearby/WiFi-Direct don't
  interoperate); cross-OS over relay always works. A custom BLE+socket protocol for
  cross-OS local is a later milestone.

## D6 — Rust core, native UIs (Swift + Kotlin via UniFFI)

> **Updated (2026-06-22):** the WASM path was dropped with the web client (see
> [`WEB-PARITY.md`](WEB-PARITY.md)). The core is now shared to **Swift** (Apple) and
> **Kotlin** (Android) via UniFFI; there is no wasm-bindgen client.

**Decision:** One Rust crate (`haven-p2p`) is the single source of truth for all
security-critical logic. It's exposed to Swift via **UniFFI** (XCFramework) and to the
Android client via **UniFFI Kotlin** bindings.

**Why:** `iroh` and `mls-rs` are Rust, and one core means every native client runs
*identical* crypto — no second implementation to audit or drift.

**Trade-off:** Requires a Rust toolchain in the build (the user already runs a
Rust-XCFramework pipeline for MLX, so this is a paved road). `rustup` + iOS targets
must be installed before the XCFramework step (the Homebrew Rust on this machine has
no `rustup` yet).

## D7 — Reach-me links carry only the id + a verification hash

**Decision:** A link is `haven://u/<id>#<verify>` or `https://<domain>/u/<id>#<verify>`.
It carries the 32-byte Ed25519 id (resolved to a live address via decentralized
discovery) and a 16-byte hash of the full hybrid key bundle, kept in the URL
**fragment** so no web server ever sees it. Using a link creates a *pending* request
the owner must approve. See [`LINK-SYSTEM.md`](LINK-SYSTEM.md).

**Why:** Permanent, server-free, works on a plain static website, and the fragment
keeps even the hosting page blind. The pending-approval step is the spam/abuse
defense for a publicly posted link.

## D8 — Apple Music = share references, not audio

**Decision:** Music sharing means attaching a track/playlist *reference*; each user
plays it through their own Apple Music subscription (MusicKit native, MusicKit JS on
web). Users' own audio files flow through the normal encrypted file path.

**Why:** MusicKit/DRM forbids transmitting the audio itself. This is the only legal
model — and it's clean: no piracy, no licensing exposure.

**Trade-off:** A friend without a subscription hears 30-second previews.

## D9 — Calls: WebRTC mesh now, E2E SFU later

**Decision:** Group audio/video via WebRTC mesh for small groups (≤~5), which stays
serverless. Larger calls later via an insertable-streams E2E SFU that relays frames
it can't decrypt.

**Why:** Mesh uplink dies beyond ~5 participants, but small family/friend calls fit
mesh and need no server.

## D10 — Safety is on-device and graph-bounded

**Decision:** Blocking is client-side refusal + group removal. Sensitive-content
guards use Apple's on-device `SensitiveContentAnalysis` (nothing leaves the device).
Distribution is friend-graph-only — **no global discovery feed, ever**.

**Why:** Aligns with the no-server / no-data ethos and is the defensible answer to
abuse (incl. CSAM): on-device analysis + invite-only, graph-bounded sharing. Also
structurally prevents the doomscroll the product exists to avoid.

## D11 — Edit & unsend as signed, ordered events (with timers + an "edited" badge)

**Decision:** Messages are immutable once sent. **Editing** posts a new signed
`Edit{target, new_ciphertext, ts}` event into the same MLS group; clients render the
latest version and show an **"Edited"** badge (keeping the original timestamp).
**Unsending** posts a signed `Retract{target, ts}` event; honoring clients remove the
content and show **"Message unsent."** Both are gated by client-enforced **timers**
(e.g. edit ≤ 15 min, unsend ≤ a few min); receivers reject edit/retract events whose
`ts` falls outside policy, so the window can't be abused later.

**Why:** With no central store, you can't mutate a row — but a signed, ordered event
*is* the edit history, and it's tamper-evident within the group (everyone sees the
same sequence). The badge/“unsent” marker are themselves part of that history.

**Honest limit:** unsend is **best-effort**, exactly like iMessage/Signal. We can't
force deletion on a recipient's *device*, a *modified* client, or a *screenshot*, and
a relay may have briefly held an encrypted copy. The timer + signed retract are the
strongest guarantees possible without a server policing everyone's device.

## D12 — License: PolyForm Noncommercial 1.0.0, copyright retained

**Decision:** The codebase is **source-available under PolyForm Noncommercial 1.0.0**
(`LICENSE`). Copyright is retained by Blaine Miller, who distributes the paid
($9.99) App Store binary — permitted because the copyright holder isn't bound by the
public license. Outside contributions require a lightweight **CLA/DCO** granting
relicensing rights, so the app can keep being sold.

**Why:** PolyForm Noncommercial cleanly does the one thing requested — anyone may
read, learn from, fork, and use it noncommercially, but **not** ship it commercially.
It's professionally drafted and plain-language.

**Terminology honesty:** this is **"source-available," not OSI-approved "open
source"** — the noncommercial restriction is exactly what disqualifies it from the
OSI definition. Fine to call it open *source* loosely, but not *open-source licensed*.

**Alternatives if you ever want *eventual* true-OSS:** FSL (Functional Source
License, converts to MIT/Apache after ~2 years) or BSL (Business Source License,
time-delayed). Swap-in is a one-file change.

## D13 — One Rust core → every platform

**Decision:** Because all security-critical logic lives in `haven-p2p` (Rust), new
clients are mostly UI:

> **Updated (2026-06-23):** the web (WASM) client was dropped — a browser can't be an
> iroh peer (see [`WEB-PARITY.md`](WEB-PARITY.md)). Android is now a *native* UniFFI →
> Kotlin client (in progress, `android/`), and macOS ships from a **native AppKit/SwiftUI
> target** (`HavenMac`) — **Mac Catalyst was dropped 2026-06-23** (see
> [`MACOS-NATIVE-PORT.md`](MACOS-NATIVE-PORT.md)).

| Platform | How | Effort |
|---|---|---|
| iOS / iPadOS / macOS | SwiftUI + UniFFI (XCFramework); macOS is a **native** AppKit-backed target (Catalyst dropped) | primary |
| **Android** | **native** Jetpack Compose + **UniFFI → Kotlin/JNI** over the *same* core | low–medium |
| ~~Web~~ | ~~wasm-bindgen → WASM~~ — **abandoned** (no browser iroh peer) | n/a |
| **Windows / Linux desktop** | native client reusing the Rust core | low–medium |
| **Apple Watch** | companion app, Rust core via `aarch64-apple-watchos` (tier-3) | scoped (see below) |

**Watch scope (honest):** messages, photos, reactions, notifications, quick replies,
and possibly audio messages/calls are feasible. **Bulk video / large-file transfer is
not** (watchOS media + bandwidth limits; cf. our watchOS video-wall findings). Ship
the Watch as a glanceable companion, not a full client.

**Why:** The Rust-core decision (D6) is what makes "someone can build an Android
client easily" actually true — they inherit identity, crypto, links, and transport
for free and only write UI.

> **D14 is partially superseded by [D15](#d15--zero-operator-cost-senders-own-storage-free-relays).**
> The two-role split and IP guarantees still hold; the *operator-funded quota'd
> bucket* and its quota machinery are dropped.

## D14 — Two relay roles; storage is BYO/federated; honest IP guarantees

**Decision:** Split "relay" into two roles (full detail in `RELAY-AND-DEPLOY.md`):
- **Connection relay** — stateless live packet forwarder for NAT traversal.
- **Storage relay ("mailbox")** — sealed blobs on the relay's own local disk (the
  in-app relay or `haven-relay` daemon), for offline delivery and large/lossless files.

Storage is a **Haven relay mailbox** or the user's **own S3-compatible bucket**
(AWS S3, Cloudflare R2, Backblaze B2, MinIO) — so there is no central service. A
**deployment tool**
(`haven-relay`, OpenTofu + CLI) lets any entity stand up a compliant relay on AWS/GCP/
Azure/Hetzner/Fly/DO/Cloudflare-R2/Oracle/bare-VPS in one command, with
privacy-hardened defaults that are hard to disable.

**IP privacy — the honest version (also in `THREAT-MODEL.md`):** a relay/storage node
*transiently handles* your IP because that's how bytes reach you; "no node ever sees
your IP" is false and we won't claim it. We **do** guarantee, by default config:
- **zero logging / zero persistence** (RAM-only, provider logs disabled),
- **no linkage to a real-world you** — but *not* "the relay can't see who's connecting":
  a relay authenticates the peer by its iroh node id, which **is** your Haven public key
  (`core/haven-net/src/blobstore.rs:537`), because that's what enforces circle-membership
  authorization and keeps a stranger from enumerating a mailbox. So `IP ↔ node id` is
  available to it in memory while it moves your bytes. It has no account, name, email or
  phone to attach that key to, and it holds no content key,
- **quota without identity** (blind-signed Privacy-Pass-style tokens),
- **your own path if you want IP *hiding*** — run behind your own VPN, or use a
  relay/discovery node you host yourself. An opt-in onion/proxy (Tor) mode was evaluated
  and **declined**: Tor is TCP-only and cannot carry iroh's QUIC/UDP data plane or WebRTC
  calls, and the only constructible variant deletes direct P2P and calling (see `TOR.md`).

Promise: **never logged, never sold, never readable.** Not "never seen" — a relay
necessarily learns `IP ↔ node id` for as long as it is moving your bytes, and nothing
persists it.

**Why:** Removes you as a central operator, lets the network be genuinely federated,
and makes the strongest IP claim that is actually true rather than a comforting lie.

## D15 — Zero operator cost: relay-mailbox / BYO storage, free relays

**Decision:** The operator pays **nothing monthly** and runs nothing required:
- **Storage = a Haven relay mailbox** (sealed blobs on a user/community-run relay's
  own local disk — the in-app relay or `haven-relay` daemon) or the user's **own
  S3-compatible bucket** (AWS S3, Cloudflare R2, Backblaze B2, MinIO). No
  operator-funded bucket. "The user funds their own storage," literally.
- **Connection relay** = iroh/n0 **free public relays** + community-run relays;
  hole-punching via **public STUN**; discovery via the **mainline DHT**.
- **Hosting** = GitHub Pages (`blaineam.github.io`) for the invite-landing page, AASA,
  and marketing page. **Notifications** = a blind APNs relay on Cloudflare Workers
  (free tier; see [`NOTIFICATIONS.md`](NOTIFICATIONS.md)).
- App is a **one-time $9.99, no subscription**.

**This deletes** the 512MB quota, blind-signed tokens, App Attest gating, the storage
subscription, and the funded default bucket — they only existed to meter a bucket the
operator would have funded. `haven-relay` (D14) remains as an **optional** community /
self-host reliability layer, never required.

**Trade-offs (dependency, not dollars):**
- Connection relay depends on **best-effort free third-party relays** (no SLA);
  degradation hits hard-NAT links and live calls until community/self relays fill in.
- **Offline delivery needs a reachable mailbox.** With neither peer online, delivery
  needs a Haven relay mailbox or the sender's own S3-compatible bucket; either is
  cross-platform, so any client can read it.

**Why:** The user explicitly wants no monthly cost, not even $5/mo. Self-funded
storage + free infrastructure achieves that and simplifies the product. See
`OPERATING-COSTS.md`.

## D16 — Multi-device: one account, per-device keys (not a shared key)

**Decision:** A user is **one account identity** with multiple **authorized
devices**, each holding its *own* keypair. No private key is copied between devices.
The account identity key signs a **device credential** per device; each device is its
own **MLS leaf**, so messages are received on all of them. Full design in
`MULTI-DEVICE.md`.

> **Reality check (2026-07):** the *shipped* system diverges from this ideal, and the docs must
> not assert the ideal as fact. (1) A linked device today holds a **copy of the account master
> seed** (`haven-seed:` move-to-device transfers it) and runs under it — a private key **is**
> effectively copied, contra the sentence above. (2) There is **no MLS** in the tree; group
> keying is sender-keys + epochs (`GROUP-KEYING.md`), and multi-device is signed device bindings
> + a CRDT (`selfsync`), not MLS leaves. (3) Consequently device revocation is **advisory, not
> cryptographic** — a revoked-but-compromised device keeps decrypting and can re-add itself. The
> cryptographic fix (**seed-drop** re-key) is **designed and planned for 1.0.7**, not shipped —
> see [`SEED-DROP-DESIGN.md`](SEED-DROP-DESIGN.md). The "instant revocation" and "MLS leaf" phrasing
> below records the original intent; read it as target, not current behavior.

- **Linking:** new device shows a QR/code → an authorized device confirms a short
  verification phrase → issues a signed credential → adds the device as a leaf to all
  groups. No PII.
- **Always-on device** (esp. a Mac) acts as the user's **personal store-and-forward
  node**, caching encrypted traffic and forwarding it to other devices when they come
  online (advances the $0 goal — hardware the user already owns).
- **Revocation:** account key signs an updated device list excluding a lost device; an
  MLS Remove commit re-keys the groups. The user keeps their identity.
- **Recovery:** account key is escrowed (D2) so losing all devices is recoverable.

**Why (vs. copying one key everywhere):** a shared key can't be revoked — a stolen
device would force a brand-new identity and re-establishing every contact. Per-device
keys give instant revocation, least privilege, and fit MLS natively (each device = a
leaf, D3). This is the Signal/iMessage/Matrix approach.

**Trade-offs / honest limits:** more moving parts than copying a key; the account key
is the crown jewel (compromise = full-account compromise — mitigated by escrow +
Secure Enclave + not needing it for daily messaging); long-offline devices must replay
the **ordered** MLS commit backlog to catch up; a web client is a weak always-on node
(native desktop is the real forwarder).

## D17 — Scheduled "send later" fires from an awake device

**Decision:** Scheduled messages are queued as **plaintext-at-rest, synced across the
user's own devices**, and **sealed-and-sent at send time** by whichever authorized
device is awake — the **always-on device (D16) is the primary firer**. Not pre-sealed
(MLS epoch could go stale before T). Editable/cancelable until fired (D11). Two modes:
**send-time** (default, private — nothing transmitted until T) and **display-time**
(optional — pre-delivered, revealed at T; resilient but weaker secrecy, for non-secret
timed posts). Full design in `SCHEDULED-MESSAGES.md`.

**Why:** No server exists to hold a queue and fire it, so the send must originate from
one of the user's own devices; the always-on device makes exact-time sending possible.
Queueing plaintext (not ciphertext) avoids MLS epoch staleness.

**Trade-offs / honest limits:** without an always-on device, iOS background wake-ups
(`BGTaskScheduler`) are best-effort — a scheduled send may go out late (and is marked
"scheduled for X, sent Y") rather than exactly on time. Double-send is prevented by a
primary-firer designation plus recipient-side message-id dedup.

## D18 — Camera, Apple Music on posts, audio crossfade (security-audited)

**Decision:** Add an in-app camera (photos+video), the ability to attach an Apple
Music song that plays alongside a post (artist+title pill + playing animation), and a
clean audio crossfade (attached music plays; video muted by default; unmute fades
music out / video in). Full design + per-feature security audit in `MEDIA-AND-MUSIC.md`.

**Security posture (the point):**
- **Camera media is sealed E2E before it leaves the device**; sandbox-only, EXIF/GPS
  stripped by default, no analytics, temp files deleted after seal. No server path →
  nothing for the maker to be compelled to produce.
- **Apple Music = references only, never audio** (legal, no piracy); the `TrackRef`
  rides inside the already-sealed event; MusicKit auth is per-device; Haven sees no
  Apple ID / library / listening data and adds **no central component** — the
  maker-holds-no-keys property is preserved.
- **Crossfade has no security surface** (local playback); it only honors user control
  (muted by default, explicit unmute).

**Why:** These make Haven feel like iMessage+Photos+Music while keeping every byte on
the same E2E path and the maker out of the trust chain.

**Trade-off:** camera + MusicKit can't run in the Simulator, so implementation is
device-verified via TestFlight. The MusicKit capability/entitlement is **granted on the
App ID** — live Apple Music attach + playback is shipped.

## D19 — Post retention: auto-delete with sender override (shortest wins)

**Decision:** Posts can expire. A viewer sets a default ("Auto-delete old posts":
off / 1 week / 1 month / 3 months / 1 year) and a sender can attach a shorter
override per post ("Disappears after…": 1h / 1d / 1w). The **shorter of the two**
governs; absence of both = keep forever. Enforcement lives in the reducer
(`build_feed(events, now_ms, viewer_retention_secs)`): a post past
`created_at + min(sender, viewer)` is dropped from the feed (and thus from any
device that rebuilds it). `retention_secs` is carried inside the **already-sealed**
`EventKind::Post`, so the limit is integrity-protected like the rest of the post.

**Security posture:** retention is a property of signed content — a recipient can't
forge a *longer* life than the sender allowed (sender override is enforced for
everyone), and a recipient can always choose *shorter* (their own default). No
central component, no maker-held state. This is client-side expiry, not a DRM claim:
an honest client deletes; we don't pretend to defeat a malicious client that screenshots.

**Why:** ephemerality is table stakes for a private network; "shortest wins" gives
both sides control without either being able to weaken the other.

## D20 — Real P2P transport wired into the app (iroh, ticket-based)

**Decision:** Ship the live networking layer in the app, not just the core. `haven-net`
exposes a callback-based `Node` (accept loop → handler) with `ticket()` /
`send_ticket()`; `haven_ffi` wraps it as an async UniFFI `HavenNode` (+ `InboundListener`
foreign callback) driven on a tokio runtime. The Swift "Networking (beta)" screen goes
online, shows a dial ticket (QR + copy), and sends sealed bytes to a pasted peer ticket.
iroh cross-compiles cleanly to `aarch64-apple-ios`; the app links
`SystemConfiguration.framework` (netdev/hickory DNS need `SCDynamicStore*`).

**Security posture:** the transport only ever moves `SealedEnvelope` bytes — the
network never sees plaintext, and the node id is the Ed25519 routable key. No relay,
no server, no maker-held address book. Verified: `haven-net` round-trips a real sealed
post over QUIC; on-device UI test brings a node online and mints a ticket.

**Trade-off:** iroh+tokio grows the XCFramework to ~252 MB (App Store thinning applies
per-arch). Two-device sync (replacing the demo friend with a connected contact) and
relay-assisted reachability beyond the LAN are the next networking milestones.
