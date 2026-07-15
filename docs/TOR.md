# Tor / onion mode — research spike & recommendation

**Status:** research spike, July 2026. **No product code was written.**
**Verdict: DON'T RECOMMEND** — not as a global toggle, and emphatically not as a default.
Ship the honest doc fix in §6 instead.

---

## 1. The question

> "Can we implement Tor into the Haven apps as a simple toggle to use for all traffic and
> comms within the app? Don't make it any more complex than a toggle — and maybe enable it
> by default if it works, so communication uses the Tor network wherever possible and user
> IP addresses are automagically hidden."

The ask is a *global* toggle: all traffic, all platforms, ideally default-on. This doc
answers whether that is possible, what it costs, and what it buys.

The short version: **the toggle you're picturing cannot exist**, because Tor moves TCP
streams and Haven's peer-to-peer data plane is QUIC over UDP. A *narrower* thing is
genuinely possible — more possible than we assumed going in — but it is not a toggle. It
is a different product mode that deletes direct P2P, deletes calling, mandates a relay,
and lands on an iOS memory wall. The cost is high and it is aimed at a threat we mostly
don't have.

---

## 2. What's technically possible (with evidence)

### 2.1 Tor is TCP-only. This is not a gap that's about to close.

Tor's own SOCKS specification is unambiguous:

> "The SOCKS5 'UDP ASSOCIATE' command is not supported."
> — [Tor's extensions to the SOCKS protocol](https://spec.torproject.org/socks-extensions.html)

Tor is a circuit-based, TCP-stream-oriented network. There is no UDP transport, in C-tor
or in arti. [Proposal 339 (UDP over Tor)](https://spec.torproject.org/proposals/339-udp-over-tor.html)
is "Accepted" but unimplemented — and even as *designed* it carries UDP over reliable,
in-order circuits, which is not datagram semantics and would be actively hostile to QUIC's
loss-recovery and congestion control. arti's UDP client backend issue
([#463](https://gitlab.torproject.org/tpo/core/arti/-/work_items/463)) has been open since
2022 with 1 of 6 subtasks done. **Do not plan around UDP-over-Tor.**

### 2.2 Haven's direct peer traffic is UDP and therefore cannot cross Tor. Confirmed.

`core/haven-net/src/lib.rs:120` builds `Endpoint::builder(N0)` — iroh **1.0.2**
(`core/Cargo.lock`). The data plane is QUIC/UDP. So is hole-punching, STUN, QUIC address
discovery (UDP 7842), portmapping, and the second endpoint in
`core/haven-net/src/s3tunnel.rs:56`. None of it can traverse Tor. **This part of the prior
holds completely.**

### 2.3 But the prior was too strong: a relay-only iroh over Tor *is* constructible.

Three findings falsify "Tor cannot carry Haven traffic at all":

1. **iroh's relay path is TCP, not UDP.** The relay client transport is a **WebSocket over
   HTTPS on TCP/443** — `tokio_websockets::ClientBuilder` in
   `~/.cargo/registry/.../iroh-relay-1.0.2/src/client/conn.rs:112`, path `/relay`
   (`iroh-relay-1.0.2/src/http.rs:13`). "DERP is UDP" is simply false. The UDP piece
   (port 7842) is a *separate* address-discovery side channel.

2. **iroh has a proxy hook.** `Builder::proxy_url()`
   (`iroh-1.0.2/src/endpoint.rs:690`) sets an **HTTP CONNECT** proxy, applied in
   `iroh-relay-1.0.2/src/client/tls.rs:117-143`. And arti has spoken **HTTP CONNECT since
   2.2.0**, stable and default-on in full builds
   ([blog](https://blog.torproject.org/arti_2_2_0_released/)). These two fit together.

3. **iroh can drop UDP entirely.** `Builder::clear_ip_transports()`
   (`iroh-1.0.2/src/endpoint.rs:503`) removes all IP transports — and it is *not* even
   feature-gated. Plus `unstable-custom-transports` (already enabled in
   `core/haven-net/Cargo.toml:10`, currently unused) exposes `CustomTransport` /
   `PathSelector`.

So `clear_ip_transports()` + `proxy_url(http://127.0.0.1:9150)` + arti = an iroh endpoint
whose only path is a relay WebSocket, dialed through Tor. **That is real.** Credit where
due: the naive "Tor can't touch iroh, full stop" answer is wrong.

Note the custom-transport route is *datagram*-oriented (`poll_recv`/`poll_send` of packets,
`iroh-1.0.2/src/socket/transports/custom.rs`), so "QUIC datagrams framed over a Tor TCP
stream" is also theoretically implementable — QUIC-over-TCP, with double congestion control
and head-of-line blocking. It is a bad idea for the same reasons prop-339 is, and it would
require every peer to host an onion service (see §5.1). Not pursued.

### 2.4 A naive toggle would still leak — and would therefore be a lie.

Even with the above, three leaks survive:

- **pkarr publish.** `PkarrRelayClient` builds **its own reqwest client** with no proxy
  plumbing (`iroh-1.0.2/src/address_lookup/pkarr.rs:577-582`); `proxy_url` never reaches
  it. Every 5 minutes it publishes a signed record to `https://dns.iroh.link/pkarr`
  **direct from your real IP**, handing n0 exactly the node_id↔IP mapping we already
  disclose in `SECURITY.md:38`. (Mitigating detail: it publishes *relay* addresses only,
  not your IP, by default — `pkarr.rs:22` — so the leak is the connection, not the record.)
- **DNS discovery** resolves `<z32-nodeid>.dns.iroh.link` over **UDP/53** via hickory —
  also direct, also un-proxied.
- **WebRTC calls** (`apple/HavenApp/WebRTCCall.swift:66-70`,
  `android/.../CallManager.kt:103`) are UDP DTLS-SRTP with hardcoded Google STUN and **no
  TURN configured**. Under Tor mode they don't degrade — they **die**.

A toggle labelled "hide my IP" that leaves pkarr and DNS egressing from the real IP is
worse than no toggle: it makes a promise the code doesn't keep. Fixing it means replacing
discovery wholesale, not flipping a flag.

### 2.5 Egress inventory — what could ride Tor today

| Egress | Proto | Tor-able? |
|---|---|---|
| iroh P2P data plane (QUIC, `haven/1`) | **UDP** | ❌ never |
| iroh hole-punch / STUN / QUIC-addr-disco / portmap | **UDP** | ❌ never |
| S3-over-iroh media tunnel (`s3tunnel.rs`) | **UDP** | ❌ never |
| WebRTC call media + STUN | **UDP** | ❌ never (no TURN) |
| DNS node discovery (`dns.iroh.link`) | **UDP/53** | ⚠️ only if discovery replaced |
| iroh relay / DERP fallback | **TCP/443** | ✅ via `proxy_url` |
| pkarr publish (`dns.iroh.link/pkarr`) | **TCP** | ⚠️ not proxy-aware today |
| Haven relay `:8674` blob GET/PUT (`httprelay.rs:82`) | **TCP** | ✅ trivially |
| Direct S3 media, SigV4 (`core/haven-s3`, `S3Client.swift`) | **TCP** | ✅ trivially |
| Push register → `haven-push.*.workers.dev` | **TCP** | ✅ trivially |
| Moderation `POST /flag` | **TCP** | ✅ trivially |
| APNs push *receive* | TCP | ❌ OS-owned |
| Apple Music / link previews | TCP | ❌ OS-owned (out-of-process) |
| Nearby / Multipeer | LAN | n/a — no IP exposure to hide |

The ✅ rows are the privuma-shaped subset (§5.4). They are also, notably, **the rows that
already only talk to relays and storage** — i.e. the traffic whose IP exposure we already
address by policy in `THREAT-MODEL.md`.

---

## 3. What "relay-only over SOCKS" actually costs

**It stops being Haven.** D1 and D20 build the product on real P2P with relays as a
*fallback* for the ~15–20% of connections that need one. Tor mode inverts that: 100% of
messages and 100% of media bytes go through a relay, then through three Tor hops.

- **Latency:** Tor adds ~0.5–2s of circuit RTT. Every message. Interactive UI (typing
  indicators, reactions) feels broken.
- **Throughput:** Tor circuits realistically deliver single-digit Mbps at best. Haven is a
  *photo and video* app. Chunked media is 8MB chunks over a 256MB+ ceiling
  (`reference_haven_chunked_media`). A family video album over Tor-over-relay is a
  non-starter.
- **Battery:** a permanently-open Tor client with live circuits + relay WebSocket, on a
  phone, all day.
- **Calls: gone.** No UDP, no TURN. The entire WebRTC feature set (D18, calls, screen
  share) is dead in Tor mode. A "toggle" that silently kills calling is not a toggle.
- **Cost story (this is the mandate problem):** if all traffic must traverse a relay, then
  either (a) it's **n0's free public relays**, which makes a hard third-party dependency
  out of infrastructure D15 lists as a *free fallback*, and pushes bulk media through
  someone else's free tier — a rude and fragile posture; or (b) it's a **user/community
  relay**, i.e. Tor mode only works for people who run a box. D15 says the operator pays
  nothing monthly and **runs nothing required**. A mandatory-relay mode doesn't break the
  $99/yr ceiling directly, but it does break "runs nothing required" — for the *user*.

**Serverless P2P is the pitch. A mode that mandates a relay is a different product.**

---

## 4. What it actually buys — against the real threat model

Be precise about who we'd be hiding from.

- **From peers?** Haven peers are people you *explicitly approved* — family and close
  friends, anchored by in-person QR. Hiding your IP from your own sister is not a threat
  model; it's a rounding error. And `THREAT-MODEL.md` already concedes there is **no
  anonymity within a group** by design — posts are signed by identity keys, deliberately,
  so members can attribute and remove abuse. Tor does not change that and shouldn't.
- **From a relay operator (a stranger's Pi)?** This is the **real** exposure, and it's the
  strongest argument for Tor. But: `THREAT-MODEL.md` answers it with *never logged, never
  persisted (RAM-only), never tied to a real-world identity* — the relay sees circle-sealed
  blobs it holds no key for. It *does* see your public key: the node id it authenticates is
  the same key, which is exactly what `SECURITY.md`'s circle-membership authorization needs
  to stop a stranger enumerating (audit F8). Tor would upgrade "not linked by
  policy" to "not knowable by construction." That is a genuine improvement, for one hop,
  at the cost of the entire §3 list.
- **From n0?** `SECURITY.md:38` already discloses IP↔node-id mappings via n0 discovery,
  and already prescribes the remedy: *"a user with a stricter threat model can run their
  own relay/discovery."* That remedy is cheaper and works today.
- **From a global passive observer?** `THREAT-MODEL.md` explicitly names this a
  **non-goal**. Tor doesn't fully solve it either (traffic confirmation on a
  small friend-graph with distinctive timing is exactly Tor's known weak case — a
  three-person circle is a tiny anonymity set regardless of how many hops you use).

Content is already E2E hybrid-PQ (X25519 + ML-KEM-768). Seeds are Secure-Enclave-wrapped.
There is no account, no telemetry, no plaintext anywhere off-device. **The remaining
exposure is one hop of transient, unlogged `IP ↔ node id` handling — a key with no name
behind it.** Tor is a very large
lever aimed at a small, already-mitigated problem — and it would pay for that small win by
deleting P2P, calls, and media throughput.

The existing advice in `THREAT-MODEL.md` — **run Haven behind your own VPN** — gets ~90% of
the IP-hiding benefit, costs us zero engineering, keeps UDP working, keeps calls working,
and is already true.

---

## 5. Per-platform reality

### 5.1 arti maturity
- **arti 2.5.0** (June 2026); library crates `arti-client` / `tor-hsservice` are **0.44.0**
  — still 0.x, API explicitly unstable ([crates.io](https://crates.io/crates/arti-client)).
- **Client use: production-blessed** since 1.0.0. Fine.
- **Onion-service *hosting*: not blessed.** Tor's own
  [OnionService.md](https://gitlab.torproject.org/tpo/core/arti/-/blob/main/doc/OnionService.md)
  still says *"suitable for testing and experimentation only… should not be used for
  anything you care about."* This matters enormously: **hosting is the only way peers reach
  each other without IP exposure.** The one piece a P2P app would need is the one piece
  that isn't ready.
- **Disqualifying detail:** `arti-client` **can call `exit(1)`** and kill the host process
  on an obsolete-consensus signal ([docs.rs](https://docs.rs/arti-client/latest/arti_client/)).
  A stale Haven build gets terminated out from under itself. In a GUI app, that is not
  acceptable without a sidecar-process design.

### 5.2 iOS — the wall
- **Approval is fine.** Onion Browser and Orbot iOS ship on the App Store. Guideline 4.7
  doesn't apply; 2.5.2 just means compile it in, don't download it.
- **Background execution kills in-process Tor.** Per Apple DTS, the issue *"is not about
  being in the background, but rather about being suspended"*; sockets are reclaimed on
  suspend. Circuits die. Haven needs live connectivity backgrounded.
- **The only legitimate design is `NEPacketTunnelProvider`** — and its memory limit is
  **50 MiB**. This is *binding, not theoretical*: Onion Browser's FAQ says the limit
  *"causes the Tor client to crash and restart"*, and **Orbot removed obfs4proxy and
  Snowflake on iOS purely to reclaim RAM**. Haven's Rust core would have to share that
  50 MiB with Tor. Recall we already have a documented OOM history
  (`reference_haven_android_media_oom`, `reference_iroh_path_oom`) in a *full-size* process.
- **Export compliance regresses.** We currently answer `ITSAppUsesNonExemptEncryption=NO`
  and file no ASC declaration (`docs/EXPORT-COMPLIANCE.md`,
  `reference_haven_export_compliance`). Embedding Tor almost certainly flips that to
  **true** — we'd leave the OS-crypto-only exempt path. Also, per BIS, an item is not
  publicly available merely because it incorporates open source, so a closed-source Haven
  may not inherit Tor's exemption. **This directly falsifies a current shipping claim** and
  would need a real legal look, not a guess.

### 5.3 Android / desktop
- **Android is structurally easy** — a foreground service keeps Tor alive. Good proof
  point: Tor Project's own **Tor VPN Beta** (Arti + Onionmasq) is live on Play and
  [Cure53-audited](https://blog.torproject.org/code-audit-tor-vpn/). Play policy permits it.
- **Desktop:** in-process arti has the `exit(1)` hazard; a sidecar binary hits
  [tauri#11992](https://github.com/tauri-apps/tauri/issues/11992) — `externalBin` **breaks
  macOS notarization**, open since Dec 2024, no documented workaround. Plus routine
  Windows Defender false positives on `tor.exe` (Tor's own support page tells users to
  allowlist it). Budget EV cert + AV vendor submissions.

### 5.4 privuma — found, and it is *not* a precedent

Located at `/Users/blainemiller/GitMirrors/blaineam/privuma-cli.git` (SwiftUI app in
`apple/`). How it actually works:

- **C-tor, not arti**: `apple/Vendor/Tor/fetch-tor.sh` pulls iCepa/Tor.framework
  `v409.11.1` (~141 MB xcframework, git-ignored).
- Runs `tor_run_main()` on a dedicated `Thread` in-process
  (`apple/Sources/Privuma/State/TorManager.swift`), SOCKS on `127.0.0.1:39050`.
- **Proxies exactly one thing: URLSession.** `ProxySettings.swift` sets
  `connectionProxyDictionary` (`SOCKSEnable`/`SOCKSProxy`/`SOCKSPort`), fail-closed, with
  carve-outs for loopback/RFC1918/Tailscale because Tor refuses non-routable addresses.
- **No onion services. No UDP. No P2P. No Network Extension.** Its only background mode is
  `processing` for BGTaskScheduler — nothing keeping circuits alive.

privuma is **an HTTP client fetching HTTPS from a public server** — the single easiest case
Tor supports, foreground-only. The intuition "privuma did it, so Haven can" doesn't
transfer: Haven is the hard case on every axis (UDP, P2P, bidirectional reachability,
background liveness, bulk media). The approach transfers only to the ✅ rows in §2.5 — and
those rows alone hide nothing, because the QUIC mesh next to them still dials direct from
your real IP.

---

## 6. Recommendation

### DON'T RECOMMEND — for the global toggle, and especially not as a default.

Reasoning, in order of decisiveness:

1. **The requested toggle is physically impossible.** "All traffic and comms over Tor" is
   unreachable while the data plane is QUIC/UDP. Any toggle we shipped would cover a
   fraction and silently leave the rest direct.
2. **The constructible version isn't a toggle — it's a product fork.** Relay-only + no
   direct P2P + no calls + relay mandatory + seconds of latency + Mbps ceiling on a
   photo/video app + replaced discovery stack. That contradicts D1/D15/D20 and the
   serverless-P2P pitch.
3. **iOS's 50 MiB Network Extension ceiling is a hard engineering wall**, already proven to
   crash Tor for Onion Browser and to force feature removal in Orbot — for apps that
   *aren't* also hosting a Rust P2P core.
4. **arti won't bless onion-service hosting**, which is the only shape that would actually
   let peers reach each other IP-lessly.
5. **It would falsify a live claim** (`ITSAppUsesNonExemptEncryption=NO`).
6. **It's aimed at a small residual risk.** Content is E2E hybrid-PQ; the relay sees
   sealed blobs, never logs, never links. VPN — already our documented advice — captures
   most of the benefit for zero engineering and keeps UDP, calls, and throughput intact.

### What to do instead

1. **Fix the doc claim (do this now).** `THREAT-MODEL.md:28` currently promises
   *"Optionally fully hidden (planned, not yet shipped) — an opt-in onion/proxy (Tor)
   mode."* On this evidence that is **not a plan we intend to keep**, and leaving it
   implies a roadmap item that won't land. Rewrite it to promise what we can deliver:
   *never logged, never linked, and **run Haven behind a VPN or your own relay** if you
   need your IP hidden from a node.* An honest downgrade beats a stale promise — this is
   the same "honest IP guarantees" discipline as D14.
2. **Promote VPN + self-hosted relay** as the supported IP-privacy story, in-product where
   the toggle would have gone. It works today, on every platform, without deleting calls.
3. **If we ever revisit:** desktop-first, experimental, opt-in, clearly labelled
   "relay-only, no calls, slow" — as a branch spike, never a default. Desktop dodges the
   50 MiB wall and the App Store surface. Revisit only if arti blesses onion hosting *and*
   someone asks for it with a concrete threat model. **Nobody has.**

### The one-line version

Tor hides your IP **from your own family** — who you invited — while breaking calls, media,
and P2P, and it still can't hide you from the relay hop unless we rebuild discovery. The
threat it addresses is the one we've already engineered away by not logging and not linking.

---

*Spike conducted July 2026 against iroh 1.0.2 / arti 2.5.0. No product code changed. If
iroh's relay transport, `proxy_url`, or `clear_ip_transports` change upstream, §2.3 is the
part to re-verify.*
