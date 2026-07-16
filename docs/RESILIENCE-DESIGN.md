# Infrastructure independence & project survivability (Resilience v2)

> **Status — design spike, not built.** This is the full plan for the "no external single point of
> failure" mandate: Haven must keep operating, decentralized and secure, if **n0's public iroh
> relays**, **n0's discovery service**, or **any third party** shuts down — and must remain
> carriable by a stranger if the sole maintainer disappears. It is **design only**; no product code
> accompanies it. It mirrors `docs/TREEKEM-DESIGN.md` and `docs/SEED-DROP-DESIGN.md`: staged, with
> proof obligations, honest tradeoffs, and every claim grounded in the real code or the **pinned**
> iroh 1.0.2 crate (`core/Cargo.lock`).
>
> **Locked framing (do not relitigate):**
> - **Scope = transport + discovery + continuity.** The target is iroh's relay/DERP layer, node-id→
>   address discovery, and the project's ability to outlive its maintainer. **Push is out of scope
>   as a dependency** — reliable iOS/Android wake requires Apple/Google + *some* server, and the
>   user accepts running their own Cloudflare Worker for it (`docs/NOTIFICATIONS.md`). Push already
>   degrades to in-app mailbox polling when absent; it is a *notification* dependency, never a
>   *delivery* one.
> - **E2E is untouchable.** Content is already sealed hybrid-PQ (`docs/SECURITY.md`); relays are
>   blind (`core/haven-net/src/relay.rs:16`). Nothing here may add a plaintext path or a key-holding
>   participant. Discovery/relay selection is a **new metadata + routing attack surface**, analyzed
>   in §6, but it can never become a content surface.
> - **Zero recurring cost, serverless, per D1/D15.** `docs/DECISIONS.md:6` is "no surveillance /
>   near-zero cost," not "literally no servers." The continuity target is that *nobody's* server is
>   load-bearing — not that servers cannot exist.
> - **Must not regress the shipped iroh scars.** Self-connect leak (`lib.rs:389`), path-management
>   OOM (fixed in iroh 1.0.2, `reference_iroh_path_oom`), dial single-flight (`lib.rs:403`),
>   same-key second endpoint (`lib.rs:350-353`). Every new dial/relay/discovery path must route
>   through the existing chokepoints, not around them.

---

## 0. TL;DR + the failure-point inventory

Haven's **content plane** is already decentralized and blind: circle-sealed envelopes move over an
app-layer mesh (direct P2P, the `HVR1` connection-relay switchboard `relay.rs:44`, the blob mailbox
mesh `lib.rs:344`, BYO S3), and any circle member can run the relay daemon (`core/haven-relay`). If
that were the whole story, Haven would already be un-shutdownable.

It is not the whole story. **Underneath** the app-layer mesh sits iroh's transport, and iroh is
bound to **n0's public infrastructure by a single line, repeated four times:** `Endpoint::builder(N0)`
(`core/haven-net/src/lib.rs:124`, `blobstore.rs:683`, `s3tunnel.rs:55`, `s3tunnel.rs:174`). The `N0`
preset (`iroh-1.0.2/src/endpoint/presets.rs:114-140`) wires in, unconditionally:

1. **n0's default DERP relay servers** (`relay_mode(default_relay_mode())`) — used for NAT traversal,
   hole-punch coordination, reflexive-address discovery (iroh's STUN-equivalent), and relayed packet
   forwarding when no direct path forms.
2. **n0's DNS discovery** (`DnsAddressLookup::n0_dns()`) — resolves node-id → current address by DNS
   query to n0's `iroh.link` server.
3. **n0's pkarr publish relay** (`PkarrPublisher::n0_dns()` → `https://dns.iroh.link/pkarr`,
   `pkarr.rs:127`) — where *this* node publishes its own signed address record.

### The external-dependency inventory (today)

| # | Dependency | Where it enters | If it dies… | Surviving path today? |
|---|---|---|---|---|
| D1 | **n0 DERP relay servers** | `N0` preset → `lib.rs:124` | Cross-NAT peers that can't hole-punch lose their relay path; reflexive-address discovery degrades | **Partial** — same-LAN direct + portmapper-mapped direct still work; Apple Multipeer LAN mesh still works (`FeedView.swift`); but two cross-NAT peers with no direct path go dark |
| D2 | **n0 DNS discovery** (`iroh.link`) | `N0` preset (`DnsAddressLookup::n0_dns`) | Node-id→address resolution by DNS stops | **Weak** — a peer with a cached/`with_relay_url` address (`lib.rs:183`) still reaches; a cold peer with only a node id cannot be found |
| D3 | **n0 pkarr publish relay** (`dns.iroh.link/pkarr`) | `N0` preset (`PkarrPublisher::n0_dns`) | This node can't *publish* where it is; peers using D2 can't find it | **Weak** — same as D2, the publish side |
| D4 | **Google DNS fallback** (`8.8.8.8`) | iroh internal DNS fallback (`endpoint.rs:887`) | System resolver used instead | **Strong** — cosmetic; only a fallback resolver |
| D5 | **Apple Push (APNs) + Cloudflare Worker** | `docs/NOTIFICATIONS.md` | Background wake stops | **Accepted / by-design** — degrades to in-app polling; out of scope |
| D6 | **App Stores** (Apple/Google/MS) | distribution | New installs blocked; existing installs keep running | **Partial** — Linux `.deb/.rpm/AppImage`, Android sideload APK, Windows `.msi` off-store all exist (`docs/ROADMAP.md`); Apple is the hard wall |
| D7 | **The maintainer** (keys, domain, repo) | continuity | No new releases, no relay bootstrap domain, no push Worker | **Weak today** — §8 is the fix |

**There is no classic Google/third-party STUN dependency** — iroh does reflexive addressing over its
*own relays* via `net_report` (`iroh-1.0.2/src/lib.rs:279`), so "STUN independence" is a *subset* of
relay independence: run your own relays and reflexive addressing rides them. iroh's `portmapper`
(UPnP/PCP/NAT-PMP, enabled by default in iroh's feature set) already yields direct addresses without
any relay when the NAT cooperates.

**The verdict up front (expanded in §7 and §10):** the content plane is genuinely hard to kill. The
**transport plane depends on n0 for three things (D1–D3)**, all removable with iroh's *pinned* public
API — no fork of iroh required (verified in §2). The honest limit is that decentralized discovery
(D2/D3) is a **latency/robustness-for-independence trade**, not a free lunch (§4, §10), and that
Apple app-store distribution (D6) and the maintainer's continuity (D7) are **social/legal**
problems that engineering can only *prepare for*, not *solve* (§8, §10).

---

## 1. Goal, threat model, and continuity model

### 1.1 The success criterion

> For every entry D1–D7 above, and for every actor who could "shut Haven down," there is a
> **surviving path** by which two honest users who both still run the app can keep exchanging sealed
> content — and a **surviving path** by which a stranger can rebuild, run, and extend the whole
> system from public artifacts, with no secret and no maintainer-held key required to operate.

This is deliberately weaker than "no degradation": we accept that losing n0 raises discovery latency
and that losing the maintainer freezes the *official* release channel. The criterion is **continuity
of function and continuity of the project**, not continuity of convenience.

### 1.2 Threat / adversary model (transport & discovery only — content model is `docs/THREAT-MODEL.md`)

| Adversary | Capability | New surface this design must defend |
|---|---|---|
| **Infrastructure death** (n0 shuts relays/DNS; a cloud bans the workload) | Removes D1–D3 | Bootstrap without n0; self-hosted relays + discovery |
| **Hostile relay operator** (open federation invites bad actors) | Runs a Haven relay; sees node-id↔IP + timing; can drop/delay frames; can *lie* in discovery gossip | Signed self-authenticating records (§4.4); N-independent-paths (§5); blind-relay invariant preserved |
| **Eclipse attacker** | Controls all discovery/relay paths a victim sees; feeds only attacker-chosen addresses | Pinned signed bootstrap set + multiple independent discovery layers (§6.1) |
| **Address-spoofer / redirect** | Publishes a forged node-id→address record | Records self-signed by the node key; a wrong signature is unusable (§4.4, §6.2) |
| **Sybil / flooder** | Spins up thousands of fake relays or discovery records; floods a relay | Membership-gated forwarding (`lib.rs:606`), rate limits, cost-to-participate, capped fan-out (§5.3) |
| **Censor / DNS seizure** | Seizes the bootstrap domain; blocks DNS | DHT + in-app pinned relay list + operator-domain diversity (§3.2, §7) |
| **State-level network block** | Blocks known relay IPs / DPI | Out of scope to *defeat*; noted honestly in §10 (this is Tor's job, and `docs/TOR.md` declined it) |

**Invariant carried from `docs/SECURITY.md`, never weakened:** a relay/discovery participant learns
only `node-id ↔ IP ↔ timing ↔ size` — metadata it already sees today because the node id *is* the
transport-auth key (the QUIC-verified `conn.remote_id()` is the membership check, `blobstore.rs:784`,
`:992`; `THREAT-MODEL.md`). No design here gives any relay a content
key, a circle roster secret, or the ability to forge a node's address undetectably.

### 1.3 The continuity ("baton") model

A system survives its maker only if a competent stranger can, from **public artifacts alone**:
(a) build every client and the relay from source, reproducibly; (b) run the entire mesh — relays,
discovery, bootstrap — with **no maker-held key and no proprietary server**; (c) understand the wire
protocol well enough to write a second interoperable client; and (d) legally fork and redistribute.
§8 enumerates exactly which artifacts must exist, and flags the two that **do not exist today**: a
consolidated wire spec, and a license that actually permits the fork (the repo is PolyForm
**Noncommercial**, `LICENSE:1` — a real tension, addressed honestly in §8.4).

---

## 2. What exists to build on (verified against the pinned crate)

This is the substrate. Two halves: Haven's own mesh (shipped), and iroh 1.0.2's customization surface
(verified in the crate source, not assumed).

### 2.1 Haven's app-layer mesh — already decentralized and blind

| Piece | Site | What it already gives us |
|---|---|---|
| **Connection relay** (`HVR1` switchboard) | `core/haven-net/src/relay.rs` (`RoutingFrame` :61, TTL/dedup :136), `lib.rs:529` (`RelayNode`) | App-layer forwarding of sealed frames toward node ids the relay can reach — **independent of iroh's DERP**; a relay that has *any* path to a peer forwards to it |
| **Membership-gated forwarding** (anti-reflector) | `lib.rs:606` (`may_forward`), `runner.rs:41` (`authorize_forwarding`) | Open participation without becoming an open DoS reflector (audit F10) — the Sybil-abuse baseline (§5.3) |
| **Blob mailbox + mesh anti-entropy** | `lib.rs:344` (`relay_sync_from`), `runner.rs:97-108` (30s sibling pull), `blobstore.rs` | Store-and-forward that **already gossips set-union between independent relays**, age-preserving — the substrate a discovery-gossip layer extends (§4.3) |
| **Operator retention + headless daemon** | `core/haven-relay` (`runner.rs`, `config.rs`), musl static binaries (`Cargo.toml:15-45`) | "Run your own relay" is shipped; anyone can `haven-relay run --link <code>` on a Pi/VPS |
| **Relay link (routing-only, key-free)** | `core/haven-relay/src/link.rs` | Attaching a relay carries **only** circle tag + member node ids — no key (`link.rs:19-21`). Adding relay *URLs* to this is the natural bootstrap extension (§3.2) |
| **Per-circle ordered relay set + auto-pool** | `docs/RELAY-AND-DEPLOY.md:30-48`, frame 19 (`FeedView.swift:1362`) | Clients already keep **N relays per circle**, mirror-write to all, fan-out-read from any, health-backoff dead ones, and **auto-adopt** advertised relays — the "any subset suffices" property (§5) already exists at the app layer |
| **Reply-path bootstrap from authenticated peer id** | `lib.rs:744-748` | A peer learns a dialable id from any frame delivered directly — a discovery primitive we already trust |
| **Apple Multipeer LAN mesh** | `FeedView.swift` (referenced `lib.rs:119`) | A local-discovery + local-transport layer on Apple that needs **no iroh, no n0** at all |

**The punchline of 2.1:** everything *above* iroh is already federated, blind, and N-redundant. The
gap is entirely *below* it — iroh's own reachability roots on n0 (D1–D3). Even the `haven-relay`
daemon reaches the world via `Endpoint::builder(N0)` (`RelayNode::spawn` → `Node::spawn` →
`lib.rs:124`), so **today, running your own relay still depends on n0 to make that relay findable and
hole-punchable.** Closing that is §3–§4.

### 2.2 iroh 1.0.2 customization surface — verified in the crate source

Every "iroh supports X" below was read in `~/.cargo/registry/.../iroh-1.0.2` (and `iroh-relay-1.0.2`),
matching `core/Cargo.lock` (`iroh 1.0.2`, `iroh-relay 1.0.2`, `iroh-dns 1.0.2`). Haven already enables
`features = ["unstable-custom-transports"]` (`haven-net/Cargo.toml:10`).

| Capability | API (verified) | Confidence |
|---|---|---|
| **Custom relay servers** (replace n0 DERP) | `RelayMode::Custom(RelayMap)` (`endpoint.rs:1933`); `Builder::relay_mode` (`endpoint.rs:557`); `RelayMap::try_from_iter(urls)` (`relay_map.rs:64`), `with_auth_token` (`relay_map.rs:154`) | **Confirmed** |
| **Self-host the DERP relay server** | `iroh-relay` crate ships a `server` feature + a `[[bin]] iroh-relay` (`iroh-relay-1.0.2/Cargo.toml:71,119`; `src/server/`) | **Confirmed** — but not currently a Haven dependency; adding it is real work (§3.1) |
| **Replace discovery entirely** | `Builder::clear_address_lookup` (`endpoint.rs:585`) + `Builder::address_lookup(impl AddressLookupBuilder)` (`endpoint.rs:605`) | **Confirmed** |
| **Add/remove discovery at runtime** | `AddressLookupServices::add` / `add_boxed` / `clear` (`address_lookup.rs:483-511`); `Endpoint::address_lookup()` (`endpoint.rs:1490`) | **Confirmed** — lets us hot-swap discovery without rebinding |
| **DNS discovery on a custom domain** | `DnsAddressLookup::builder(origin_domain: String)` (`address_lookup/dns.rs:78`) | **Confirmed** — point discovery at a Haven-operated / self-hosted `iroh-dns-server` domain |
| **pkarr publish/resolve to a custom relay** | `PkarrPublisher::builder(pkarr_relay: Url)` (`pkarr.rs:290`), `PkarrResolver::builder(url)` (`pkarr.rs:507`), TTL/republish tunables (`:188,:196`) | **Confirmed** — self-host the pkarr bridge |
| **Static / in-memory discovery** (pin known addresses) | `MemoryLookup::new` / `from_endpoint_info` / `add_endpoint_info` (`address_lookup/memory.rs:105,154,184`); implements `AddressLookup` (`:218`) | **Confirmed** — the pinned-bootstrap primitive (§4.1) |
| **Custom `AddressLookup` provider** (our own gossip/DHT source) | `pub trait AddressLookup` (`address_lookup.rs:333`), `AddressLookupBuilder` (`:142`), `Item`/`to_endpoint_addr` (`:371-430`) | **Confirmed** — we can implement a Haven-relay-gossip lookup as a first-class iroh discovery source |
| **Self-authenticating records** (the key security property) | iroh-dns vendors the **pkarr signed-packet** format internally (`iroh-dns-1.0.2/src/attrs.rs` uses `pkarr::SignedPacket`); a record is keyed by, and signed under, the node's own key | **Confirmed** — node-id→address is *already* self-signed by design; no relay can forge it |
| **Mainline DHT discovery** (censorship-resistant, no server) | Lives in a **separate crate** `iroh-mainline-address-lookup` (`pkarr.rs:40-43`), **NOT** in `core/Cargo.lock` today | **verify: needs a spike** — API shape and the OOM/path-churn interaction must be validated before we lean on it |
| **mDNS / local discovery** | The pinned `address_lookup` module has **only** `dns`, `memory`, `pkarr` (`address_lookup.rs:121-123`) — **no mDNS provider** | **verify: needs a spike** — local discovery needs `swarm-discovery`/a custom provider, or we lean on Apple Multipeer (which exists) |

**Conclusion of §2:** the relay-independence and custom-discovery work is achievable on the **pinned**
iroh with its **public** API — no fork, no unstable transport games beyond the feature already
enabled. Two layers (DHT, mDNS) are additive crates flagged for a spike. The self-authenticating
record property we need for security is **already inherent to pkarr** and does not have to be invented.

---

## 3. Relay / DERP independence (§ with bootstrap)

### 3.1 Run Haven relays *as iroh relays*

**Goal:** clients never require n0's DERP servers for NAT traversal, reflexive addressing, or relayed
forwarding. Achieved by pointing iroh at a **custom `RelayMap`** of Haven-operated relay URLs.

**Server side.** Extend the `haven-relay` daemon (`core/haven-relay`) to *optionally* host an **iroh
DERP relay server** alongside its existing connection-relay + blob mailbox roles. iroh ships this as
the `iroh-relay` crate's `server` feature (`iroh-relay-1.0.2/Cargo.toml:71`) and a standalone binary
(`:119`). This is a **new operator role** — a Haven relay becomes a three-in-one: DERP relay (iroh
transport), `HVR1` connection relay (app-layer switchboard), blob mailbox (store-and-forward). A
minimal operator can still run mailbox-only; a *bootstrap* operator runs all three so it can serve
transport for cold peers. **Sizing:** a DERP relay needs a public reachable address (IP+port or a
domain with TLS) — this is the one place "no public host" genuinely cannot hold, and it is the same
requirement n0 fulfills for us today. The honest framing: we don't remove the *need* for some public
relay, we remove the need for *n0's specific* relays and make the role self-hostable and federated.

**Client side.** Replace the `N0` preset with an explicit builder that composes:
`RelayMode::Custom(RelayMap::try_from_iter(<Haven relay urls>))` (`relay_map.rs:64`,
`endpoint.rs:1933`) + the layered discovery of §4. Because the four `Endpoint::builder(N0)` sites are
the *only* place n0 enters, this is a **single well-contained change surface** (`lib.rs:124`,
`blobstore.rs:683`, `s3tunnel.rs:55,174`) routed through one shared `haven_endpoint_builder()` helper
so the self-connect/single-flight/multipath invariants (`lib.rs:107-127`, `:389`, `:403`) are applied
uniformly and can never diverge between the four endpoints.

> ⚠️ **Regression guard.** Adding a second relay role to the daemon must not resurrect the same-key
> second-endpoint bug (`lib.rs:350-353`, `reference_iroh_same_key_second_endpoint`). The DERP server
> binds its *own* listening socket, not a second iroh *endpoint under the relay's node key* — it is a
> server other nodes connect *to*, not a client node. This is architecturally different from the S3
> tunnel's sub-identity trick (`runner.rs:144`) and must be validated as such (proof obligation R1).

### 3.2 The bootstrap problem: learning *any* relay URL without a central list

A fresh client must reach the mesh knowing no address a priori. n0 solved this by hardcoding n0's
relay URLs into the preset. We cannot hardcode a single central list (that *is* the failure point).
Layered bootstrap, in priority order, **any one suffices**:

1. **Signed, in-app relay list (updatable).** Ship a **maker-signed** (Ed25519+ML-DSA, the existing
   hybrid signature `identity.rs:216`) `RelayList` artifact embedded in the app binary: a
   length-prefixed, versioned list of relay URLs + relay node ids + operator domains. It is
   *signature-pinned* (the trust anchor is the maker's public key baked into the build), and
   *updatable* out-of-band: any peer can gossip a **higher-version** signed `RelayList` over the
   existing sync bundle, adopted higher-version-wins exactly like the device roster
   (`device.rs:134`, the pattern seed-drop and TreeKEM both reuse). **Absence is never information**
   (the codebase scar `reference_selfsync_absence_tombstone`): a missing update never shrinks the
   pinned set; updates only *add* or *supersede-by-version*.
   > Governance caveat (§8.4): a *single* signing key is itself a continuity SPOF. The v2 answer is a
   > **threshold/rotatable signer set** — the `RelayList` is valid under *k-of-n* community signer
   > keys, so the bootstrap survives losing the maker. Flagged as a named gate, not hand-waved.
2. **Operator-domain DNS seed.** Each relay operator who owns a domain publishes an `iroh-dns-server`
   record (or a plain well-known TXT/HTTPS record) at a conventional name (e.g.
   `_haven-relay.<domain>`). A client that knows *any* operator domain (from the signed list, a
   friend, or a QR) resolves current relay addresses via `DnsAddressLookup::builder(<domain>)`
   (`dns.rs:78`). Domain diversity across independent operators means no single DNS seizure is fatal.
3. **DHT bootstrap (censorship-resistant).** Mainline-DHT pkarr discovery
   (`iroh-mainline-address-lookup`, **verify: needs a spike** §2.2) lets a client resolve a
   *well-known Haven bootstrap node id* → current address with **no server and no domain** — the
   strongest censorship resistance, at the cost of higher/variable latency and the OOM-interaction
   validation the memory scars demand.
4. **Peer-carried relay URLs (the warm path).** Once a client has reached *one* peer by any means,
   the frame-19 relay advertisement (`FeedView.swift:1362`, `RELAY-AND-DEPLOY.md:44`) and the
   `with_relay_url` dial hint (`lib.rs:183`) already propagate relay reachability across the circle —
   extend frame 19 to carry the relay's **DERP URL**, not just its node id, so adopting one relay
   teaches the whole circle a transport relay, exactly as it teaches a mailbox today.

**Reflexive addressing / hole-punching** rides whichever relays are in the `RelayMap`: iroh's
`net_report` probes them for the node's public address (the STUN-equivalent), and the relay
coordinates the hole-punch. So §3.1 delivers STUN-independence for free — there is no separate STUN
to replace (inventory D-note in §0).

---

## 4. Decentralized discovery — the layered design + the signed-record format (the core section)

This is the hard problem: **node-id → current-address, with no central directory, self-authenticating
so a hostile resolver cannot redirect traffic.** Evaluate each mechanism concretely, then recommend a
layered default.

### 4.1 The candidate mechanisms, with tradeoffs

| Mechanism | How | Latency | Censorship-resistance | Security (spoof/eclipse) | Operability | Verdict |
|---|---|---|---|---|---|---|
| **(a) Relay-mesh gossip of signed records** | Extend the blob-mailbox anti-entropy (`lib.rs:344`) to also set-union **signed node→addr records**; resolve by asking any relay in your set | **Low** (relay already warm) | Medium (needs ≥1 reachable Haven relay) | **Strong if records self-signed** (§4.4) — a relay relays records, never mints them | **High** — reuses shipped mesh; operator already runs it | **Primary** |
| **(b) Mainline DHT / pkarr (BEP44)** | Publish/resolve the pkarr signed packet on the global Mainline DHT | Medium/variable | **Strongest** (no server, no domain, global) | Strong (BEP44 mutable records are key-signed) + eclipse-resistant by DHT redundancy | Medium — extra crate, OOM spike | **Censorship fallback** |
| **(c) Operator-domain DNS** (pkarr-over-DNS / `iroh-dns-server`) | Self-hosted DNS/HTTPS record on operator domains | **Lowest** (plain DNS) | Weak (DNS seizable/blockable) | Strong (record signed; DNS only *transports* it) | High (but needs a domain + TLS) | **Fast seed + bootstrap** |
| **(d) mDNS / local** | Local-link multicast; or Apple Multipeer (shipped) | Lowest (LAN) | N/A (local only) | Strong locally | Apple: shipped. Cross-platform mDNS: **spike** | **Local optimization** |

### 4.2 The recommended layered default (and why)

**Resolve order — local → relay-gossip → DNS-seed → DHT — first hit wins, all self-authenticated:**

1. **Local (d).** Apple Multipeer where present; mDNS elsewhere (spike). Zero infra, instant on-LAN.
2. **Relay-gossip (a).** The default steady-state path: your circle's relays are already warm
   (`RELAY-AND-DEPLOY.md`), already meshed, already blind. Ask them for the signed record. This is the
   lowest-latency non-local path and reuses the most shipped code.
3. **DNS-seed (c).** For cold peers / cross-circle reach and for *bootstrapping the relays themselves*
   (a relay finds its sibling relays the same way — §5.2). Fast, but seizable, so never the *only*
   layer.
4. **DHT (b).** The censorship-resistant backstop: if every Haven relay a client knows is blocked and
   every operator domain is seized, the DHT still resolves a bootstrap node id. Highest/variable
   latency, so last — but it is the layer that makes "seize the domain" non-fatal.

**Why layered rather than pick-one:** each single mechanism has a fatal case (relay-gossip needs a
reachable relay; DNS is seizable; DHT is slow/variable; local is local-only). Their *union* has no
shared fatal case — which is exactly the §7 "every scenario has a surviving path" property, applied to
discovery specifically. iroh composes them natively: register (a),(b),(c) as `AddressLookup` providers
via `Builder::address_lookup` (`endpoint.rs:605`) — iroh queries all and takes the first/best `Item`
(`address_lookup.rs:371`), and runtime `AddressLookupServices::add` (`:483`) lets us hot-add a layer
(e.g. spin up DHT) without rebinding the endpoint.

### 4.3 Extending the relay mesh to gossip records (mechanism (a), concretely)

The blob mailbox already does age-preserving set-union anti-entropy between sibling relays every 30s
(`lib.rs:344` `relay_sync_from` → `blobstore::pull_missing_from_peer`; `runner.rs:97-108`). A **signed
address record** is just another content-addressed blob under a reserved key prefix
(`disc/<node-id-hex>`), so:

- **Publish:** a node PUTs its own signed record (§4.4) to each relay in its set, refreshed on the
  same TOUCH-liveness cadence the mailbox already uses (`blobstore` TTL machinery). No new transport.
- **Gossip:** relays set-union `disc/*` exactly like `mbox/*` — the mesh already converges these for
  free, and the age-preserving pull (`lib.rs:359`) already prevents GC'd records ping-ponging.
- **Resolve:** a custom `AddressLookup` provider (impl of `address_lookup.rs:333`) GETs
  `disc/<target>` from any relay in the set, verifies the signature (§4.4), and returns an `Item`
  (`address_lookup.rs:387`). A relay serving a *wrong* record is caught by the signature check on the
  client — the relay is untrusted by construction.

This is the highest-leverage piece: it turns the *already-shipped, already-blind, already-meshed*
relay layer into the primary discovery layer, with the relay never able to forge or redirect.

### 4.4 The signed-record format (the critical security property, spelled out)

**Requirement:** a discovery record must be **self-authenticating** — verifiable against the node id
it claims to describe — so that *no relay, DHT node, or DNS server can redirect traffic* by serving a
forged address. The node id *is* an Ed25519 public key (`identity.rs:190`; the transport uses it as the authenticated
peer identity, `blobstore.rs:784`), which makes this natural. We reuse the **pkarr signed-packet** semantics iroh already vendors
(`iroh-dns-1.0.2/src/attrs.rs`), extended to Haven's hybrid signature so it inherits the product's PQ
posture.

```
HavenAddrRecord (length-prefixed, device.rs house style; all ints LE; lp(x)=u32 len ‖ bytes)
  magic        : b"HVAD"                 (4)
  version      : u8                       (1)
  node_id      : [u8; 32]                (32)   — the Ed25519 transport/public key this record is FOR
  seq          : u64                      (8)   — monotonic; higher seq supersedes (anti-rollback, LWW)
  not_after    : u64                      (8)   — unix expiry (short TTL, e.g. 30–120 min; DEFAULT_PKARR_TTL=30 is n0's)
  n_addrs      : u16                      (2)
  addrs        : ( kind(1) ‖ lp(bytes) )*n_addrs — kind: 1=ip:port, 2=relay_url, 3=derp_home
  ‖ lp(hybrid_sig)                                — Ed25519+ML-DSA-65 over ALL preceding bytes (identity.rs:216)
```

**Verification (every consumer, every layer):**
1. `magic`/`version` ok; `now < not_after` (reject stale/rollback replays beyond TTL).
2. **The hybrid signature verifies under `node_id`'s key** (`identity.rs:83` verify path). A record
   whose signature does not chain to the very node id being resolved is **discarded** — this is the
   whole security property: the resolver can *withhold* a record (availability attack, mitigated by
   multiple paths §5) but can never *forge* one (integrity attack, cryptographically impossible).
3. **Rollback defense:** among records for a node id, the highest `seq` within its `not_after` wins —
   the same higher-version-wins + stickiness discipline as `DeviceList` (`device.rs:203-225`). A relay
   replaying an *old* signed record can at worst point you at a stale address (a slow-fail redial,
   caught by the dial gate `lib.rs:444`), never at an attacker's address.

**Why this defeats eclipse-by-redirect but not eclipse-by-withholding:** an eclipse attacker who
controls every path you see can *refuse* to serve the honest record (you can't find the peer) but
cannot *substitute* their own address (the signature won't verify under the target's key). So the
residual eclipse risk is **availability, not confidentiality/redirection** — and availability is
defended structurally by requiring the record to be reachable via *multiple independent layers* (§4.2)
and *multiple independent relays* (§5), plus the pinned bootstrap set (§6.1) that an eclipse attacker
cannot remove from the client. This is the same shape as pkarr/BEP44's security argument, restated in
Haven's terms and bound to Haven's hybrid signature.

> The node's **transport key** signs the record, not the account key — mirroring the seed-drop
> principle (`SEED-DROP-DESIGN.md` §4.2) that day-to-day operations use device/transport keys, and so
> that publishing an address record never touches the account crown-jewel key. A record proves "the
> holder of *this transport key* is currently at *these addresses*," which is exactly what discovery
> needs and nothing more.

---

## 5. Federation topology + Sybil/abuse

### 5.1 The topology: independent operators, no load-bearing one

Independent operators each run a Haven relay (DERP + `HVR1` + mailbox + discovery-gossip). They mesh
(set-union gossip, `runner.rs:97`) and any client uses **N relays, any subset suffices** — the ordered
per-circle relay set with mirror-write / fan-out-read / health-backoff / auto-pool that **already
ships** (`RELAY-AND-DEPLOY.md:30-48`). Promote this from a *mailbox* property to a *transport +
discovery* property: a client holds N relays for DERP, N for gossip-resolve, degrades gracefully as
each fails (the 5s→5m backoff already exists), and auto-adopts advertised ones. **No operator is load
bearing** because the client never depends on a specific relay, only on *some* relay in its set being
reachable — and the pinned bootstrap set (§6.1) guarantees the set is never empty.

### 5.2 How relays find each other (the bootstrap problem, one level up)

Relays face the same cold-start problem as clients: a new relay must find sibling relays to mesh with.
Today `--peer <hex>` is manual (`config.rs:52-56`). Federated answer, same layers as §3.2/§4.2:
a relay resolves its declared siblings via the **DNS-seed** and **DHT** layers (a relay owns a domain
more often than a client does, so DNS-seed is its natural primary), and adopts new siblings from the
signed gossip records it already relays. A relay operator opts into a **federation set** by listing a
few well-known bootstrap-operator domains; the mesh converges from there. Crucially, **meshing is
set-union and blind** — a hostile relay that joins the mesh gains only what any relay sees
(ciphertext + node-id/IP metadata), never content, and its forwarding is membership-gated per circle
(`lib.rs:606`), so joining the federation is not joining any circle.

### 5.3 Sybil / abuse of open relay participation

Open federation invites Sybils. The defenses, layered:

1. **No content, ever.** The worst a Sybil relay achieves is metadata observation + selective
   drop/delay — never content, never forgery of addresses (§4.4). This caps the *value* of a Sybil.
2. **Membership-gated forwarding (shipped).** `may_forward` (`lib.rs:606`) already refuses to be an
   open reflector: a relay forwards only frames where a circle member is source or destination. A
   Sybil relay that no circle points at moves nothing. Amplification is capped (`MAX_RELAY_PAYLOAD`
   4 MB, `relay.rs:54`; TTL bound, `relay.rs:47`; time-windowed dedup, `relay.rs:136`).
3. **Client-side trust in relays is zero.** Because records are self-signed (§4.4) and reads fan out
   across N relays with content-key dedup (`RELAY-AND-DEPLOY.md:36`), a Sybil that serves garbage or
   withholds is simply out-voted by honest relays and skipped by health-backoff. There is **no
   consensus to corrupt** — discovery is verify-locally, not trust-the-majority.
4. **Cost to participate in the *default* set.** Sybils can flood the *open* federation, but the
   **signed bootstrap set** (§3.2/§6.1) and a circle's **explicitly-adopted** relays are not open —
   they are pinned/opted-into. A Sybil cannot inject itself into a client's pinned set without a
   valid higher-version signed `RelayList` (which needs the community signer key, §8.4). So the
   attack surface is "the client wastes a resolve on a junk relay and backs off," not "the client is
   redirected or partitioned."
5. **Rate limits + optional proof-of-work on gossip PUTs.** A relay accepting `disc/*` records
   rate-limits per source node id and may require a small PoW stamp on publish to bound record-spam —
   a knob, not a default, tuned per operator. (verify: needs a spike on PoW parameters.)

**Honest residual:** a well-resourced adversary running many relays *does* improve their metadata
vantage (more node-id↔IP↔timing observations). That is the same trade `THREAT-MODEL.md` already makes
for any relay, and the honest guidance is unchanged: for IP-unlinkability run your *own* relay or a
circle member's, and Haven declined Tor for the QUIC reasons in `docs/TOR.md`.

---

## 6. Security analysis (new attack surface + mitigations)

Discovery/relay selection is the new surface. Enumerated threats → mitigations, each grounded:

| Threat | Vector | Mitigation | Residual |
|---|---|---|---|
| **Address redirection** | Hostile relay/DHT/DNS serves a forged node→addr | **Self-signed records** (§4.4): forged sig fails verify under the target node id — cryptographically impossible to redirect | None for redirection; withholding remains → §multiple-paths |
| **Eclipse (withholding)** | Attacker controls all paths a victim sees, serves nothing honest | Multiple independent discovery layers (§4.2) + N independent relays (§5) + **pinned signed bootstrap set the attacker cannot remove from the client** (below) + DHT layer the attacker can't seize | Full network-position eclipse (state-level) is availability-DoS only, never redirection; noted §10 |
| **Rollback / stale-address replay** | Replay an old signed record | Monotonic `seq` + `not_after` TTL + higher-version-wins stickiness (§4.4, `device.rs:203`) | At worst a slow-fail redial, gated (`lib.rs:444`) |
| **Bootstrap-list poisoning** | Trick a client into adopting attacker relays | `RelayList` is **hybrid-signed**, higher-version-wins, absence-never-shrinks (§3.2); pinned anchor in-binary | Compromise of the community signer key (§8.4) — mitigated by threshold signing |
| **Relay DoS / reflector** | Flood a relay; use it to amplify at third parties | Membership-gated forwarding + payload/TTL caps + time-windowed dedup (all **shipped**: `lib.rs:606`, `relay.rs:47,54,136`) | Volumetric DoS of a specific relay → client fails over to others (health-backoff shipped) |
| **Sybil metadata harvesting** | Many relays to widen node-id↔IP vantage | No content ever; run-your-own-relay guidance (`THREAT-MODEL.md`) | Inherent metadata trade, unchanged from today |
| **Self-connect / path-churn regression** | New dial/relay/discovery paths re-trigger the memory scars | All dials route through the shared chokepoints: self-connect guard (`lib.rs:389`), single-flight (`lib.rs:403`), dial gate (`lib.rs:444`), one-endpoint-per-key (`lib.rs:350`) — the custom-relay/DERP-server work must add **zero** new dial sites outside them (proof obligation R1) | Requires disciplined review — named gate |

**The pinned-bootstrap anchor, precisely.** The one thing an eclipse attacker *cannot* take from a
client is what's compiled into its binary: the signed `RelayList` + the community signer public
key(s). Even if every live path is attacker-controlled, the client still *knows* honest relay
identities and will only accept records/relay-lists that verify — so the attacker cannot *permanently
partition* a client onto attacker infrastructure, only *deny service* until an honest path reappears.
That reduces the worst realistic case from "silent redirection to attacker" (catastrophic) to
"temporary unreachability" (a DoS, survivable) — which is the correct security posture.

---

## 7. "Impossible to shut down" — the failure-scenario walk-through

The success criterion (§1.1) is that **every** row has a surviving path. Walked honestly:

| Scenario | What breaks | Surviving path (post-v2) | Honest degradation |
|---|---|---|---|
| **n0 kills its DERP relays** (D1) | iroh transport relay/hole-punch/reflexive-addr on n0 | Custom `RelayMap` of Haven-operated DERP relays (§3.1); reflexive addressing rides them; portmapper still yields direct addrs | Cross-NAT peers need ≥1 reachable Haven DERP relay; someone must run one |
| **n0 kills DNS + pkarr discovery** (D2/D3) | node-id→addr resolution/publish on n0 | Layered discovery §4.2: relay-gossip (primary) + operator-DNS + DHT; all self-authenticated | Cold-resolve latency rises vs n0's tuned service; steady-state (warm relay) unaffected |
| **"Google STUN" dies** (D-note) | — | N/A — no such dependency; reflexive addressing is relay-based | None |
| **Push/Cloudflare dies** (D5) | Background wake | In-app mailbox polling (shipped); §-out-of-scope | No background notifications until a Worker is re-hosted (accepted) |
| **The maker/primary relay operator disappears** (D7 transport) | The maker's relays + bootstrap domain go dark | Federation §5: any other operator's relays serve; signed `RelayList` updates flow peer-to-peer; DHT bootstrap needs no operator at all | If *no one* runs a public relay, cross-NAT (but not LAN/direct/portmapped) delivery stops until someone does — the relay role is self-hostable by anyone (`haven-relay`) |
| **App stores pull Haven** (D6) | New installs via store | Existing installs keep running; off-store Linux/Android-sideload/Windows builds (`ROADMAP.md`); reproducible builds (§8.2) let anyone rebuild | Apple installs are the hard wall — no sideload on stock iOS; honest §10 |
| **Bootstrap DNS domain seized** (censor) | DNS-seed layer | Pinned in-app relay list + DHT bootstrap + operator-domain diversity (§3.2) | Higher-latency DHT path; new users need a non-seized seed (QR/friend/list) |
| **State-level IP block / DPI of relays** | All known relay IPs blocked | Out of reach to *defeat* here — §10; DHT + new operator IPs raise the bar but don't beat DPI | Honest limit: this is Tor's problem, declined in `docs/TOR.md` |
| **The maker's signing key is lost** (D7 continuity) | Signed `RelayList` updates + release signing | Threshold/community signer set (§8.4) if built; else the last-shipped pinned list still works and the mesh still runs | If threshold signing isn't built first, bootstrap-list *updates* freeze (the mesh still runs on the last list) — this is why §8.4 is a *gate*, not a nicety |

**The honest verdict (previewed here, defended in §10):** after v2, **every transport/discovery
scenario has a surviving path between two honest online users** — the criterion is met for the data
plane. The two places "impossible to shut down" is *aspirational rather than absolute* are (1) someone
must run at least one public relay for cross-NAT delivery (the role is free and self-hostable, but not
zero-operator), and (2) Apple app-store distribution and state-level DPI are social/legal/network
problems engineering prepares for but cannot unilaterally defeat.

---

## 8. Project continuity / the baton (the non-transport half)

Engineering independence is worthless if the *project* dies with its maker. What must exist so a
stranger can carry it forward:

### 8.1 The open protocol spec (consolidate what's already in code)

The wire formats are **documented in code and scattered docs** (frame types across `haven-ffi`, the
`HVR1` frame `relay.rs:23-36`, the relay link `link.rs:23-31`, the seal formats in `haven-p2p`, the
sealed-frame numbering referenced throughout the Apple app, e.g. frame 19 `FeedView.swift:1362`).
**No single `docs/PROTOCOL.md` exists** (verified: `docs/` has no proto/spec/wire file). **Deliverable:**
a consolidated, versioned wire spec — frame catalog (all numbered frames + payloads), the seal/KEM
transcript binding (`crypto.rs`), the group-key schedule (`GROUP-KEYING.md`), the discovery record
(§4.4), the relay protocols (`HVR1`, blob mailbox, gossip). Rule of the maker's memory
`feedback_always_update_docs`: this spec is updated with every wire change. Its existence is what lets
a second interoperable client be written — the ultimate anti-lock-in.

### 8.2 Reproducible / self-buildable clients

**Deliverable:** documented, reproducible builds for every client + the relay from source, with no
maker-held secret required to *build* (secrets are only for *signing releases*, §8.4). The relay is
already there (musl static binaries, `cargo deb`, `haven-relay/Cargo.toml:15-45`). The gap is a
`docs/BUILD-FROM-SOURCE.md` covering the Rust core + each platform shell, and a **reproducibility
attestation** (deterministic build inputs) so a stranger can verify the store binary matches source —
the trust bridge when the store itself is the adversary (D6).

### 8.3 "Run your own Haven relay + join the mesh" operator guide

**Deliverable:** an operator guide covering the three-in-one relay role (§3.1): DERP + `HVR1` +
mailbox + discovery-gossip, the domain/TLS setup for the DNS-seed layer, joining the federation set
(§5.2), and retention tuning (already in `runner.rs`). Most of this exists as `RELAY-AND-DEPLOY.md`;
extend it with the new DERP + discovery roles. The guide is what makes "someone can always run a
relay" *actionable* by a stranger.

### 8.4 Governance so the project outlives any single maintainer

Two hard, honest problems:

1. **The license.** The repo is **PolyForm Noncommercial 1.0.0** (`LICENSE:1`). That is **not** an
   OSI/free-software license and it **prohibits the commercial redistribution** a true "anyone can
   carry the baton" mandate implies. This is a genuine tension between the maker's commercial
   interest and the survivability goal, and the doc must name it rather than paper over it.
   **Decision required (a named gate):** either (a) relicense the protocol + core to a permissive/
   copyleft license so forks are legal, keeping trademarks/branding reserved; or (b) add an explicit
   *survivorship grant* ("on cessation of maintenance, the license converts to Apache-2.0") so the
   baton is legally passable even under NC today. Without one of these, §8.1–8.3 are technically
   sufficient but **legally insufficient** — a stranger *could* rebuild but *may not* redistribute.
2. **No secret required to operate.** The mesh must run with **no maker-held key** — verified true for
   the data plane (relays hold no key, `link.rs:19`; discovery records are self-signed by each node,
   §4.4). The *only* maker-held secrets are (a) release signing and (b) the `RelayList` bootstrap
   signer. Both are continuity SPOFs. **Deliverable:** a **k-of-n threshold community signer set** for
   the `RelayList` (and ideally releases), documented so trusted community members can issue updates
   if the maker vanishes — this is the concrete mechanism that turns "the baton can be carried" from
   slogan into procedure. Flagged as the highest-value continuity item and a **hard gate** for the
   "survives the maintainer" claim (§7 last row).

**The baton checklist (what a stranger needs, all public):** consolidated wire spec (§8.1),
reproducible build docs + attestation (§8.2), operator guide (§8.3), a fork-permitting license
(§8.4.1), and a community signer procedure (§8.4.2). Three of five exist in part; two (spec, license/
signer) are the real gaps.

---

## 9. Staged plan R0..R6 with proof obligations + realistic sizing

Honest sizing: this is a **large v2**, larger than seed-drop, because it touches transport (the most
scar-prone layer), adds a new operator role, and has a legal/governance component. Each stage is
independently landable and additive; the risky transport swap is gated behind the safe scaffolding.

| Stage | Scope | Proof obligation | Sizing |
|---|---|---|---|
| **R0. One endpoint-builder chokepoint + signed `RelayList` scaffold** | Route all four `Endpoint::builder(N0)` sites through one `haven_endpoint_builder()`; ship the hybrid-signed, higher-version-wins `RelayList` type (still defaulting to N0 relays). No behavior change. | `RelayList` verify/rollback tests (mirror `device.rs` roster tests); all four endpoints prove-identical config; no new dial sites (regression scan) | **S** — pure refactor + one signed type |
| **R1. Self-host iroh DERP + custom `RelayMap` (opt-in)** | Add the `iroh-relay` `server` role to `haven-relay`; client can point at a custom `RelayMap` behind a flag; N0 stays default. | **R1-crux:** a two-peer cross-NAT delivery test succeeds using **only** a Haven DERP relay, n0 relays removed; **and** no same-key-second-endpoint / path-churn regression (memory-scar gates `lib.rs:350,389,403`) under a soak | **L** — new server role, public reachability, the scar-review burden concentrates here |
| **R2. Relay-gossip discovery (mechanism (a))** | `disc/*` signed records over the existing mailbox mesh; a custom `AddressLookup` provider that GETs + verifies them. | Node A resolves node B **with n0 DNS/pkarr cleared** (`clear_address_lookup`), via relay-gossip only; a forged record is rejected; a stale record loses to higher `seq` | **M** — reuses mesh + `AddressLookup` trait; the record format + verify is the crypto-review surface |
| **R3. Operator-DNS seed + peer-carried relay URLs** | `DnsAddressLookup::builder(<domain>)` layer; extend frame 19 to carry DERP URL; bootstrap layering (§3.2 items 1,2,4). | Cold client bootstraps from a signed in-app list + one operator domain, n0 fully cleared; frame-19 relay-URL adoption propagates across a circle | **M** — infra (domain/TLS) + a small wire-field addition |
| **R4. DHT bootstrap (censorship fallback)** | Add `iroh-mainline-address-lookup`; resolve a well-known bootstrap node id via Mainline DHT. | **verify-first spike:** DHT resolve works **and** does not reintroduce path-churn/OOM (validate against `reference_iroh_path_oom`); domain-seized scenario resolves via DHT alone | **M–L** — new crate, the OOM interaction is the risk; gated behind its spike |
| **R5. Layered default + N0 removal** | Compose local→gossip→DNS→DHT as the default; drop the `N0` preset entirely; N-relay transport set (promote the shipped mailbox-set behavior to transport). | Full §7 scenario matrix passes: each of n0-relay/n0-DNS/n0-pkarr death individually leaves two honest users communicating; eclipse-redirect impossible, eclipse-withhold survivable | **M** — mostly composition + the failure-matrix test harness |
| **R6. Continuity artifacts + governance** | `docs/PROTOCOL.md` (§8.1); build-from-source + reproducibility attestation (§8.2); operator guide extension (§8.3); **license/survivorship decision + k-of-n signer** (§8.4). | A stranger rebuilds every client + relay from the spec/docs alone in a clean env; a community signer issues a valid `RelayList` update without the maker; license permits the fork | **L** — mostly writing + a legal decision + a threshold-signing implementation |

**Sequencing logic (from risk, not convenience):** R0 is free and de-risks everything by making the
n0 surface a single chokepoint. R1 is the scar-heavy heart — it must soak alone before R5 flips the
default, exactly as seed-drop kept its seed-deletion stage isolated. R2–R4 are additive discovery
layers, each shippable behind a flag and individually testable. R5 is the "pull the n0 cord" moment,
gated on the full §7 matrix being green. R6 (continuity) is parallelizable with everything and its
license/signer sub-gate is what earns the "survives the maintainer" claim — do not claim it before R6.

---

## 10. What makes this hard, and what's genuinely out of reach (honest)

- **Transport is the scar-prone layer.** Every memory reference on iroh is a leak/panic/flap
  (`reference_iroh_path_oom`, `_self_connect_leak`, `_dial_singleflight`, `_same_key_second_endpoint`).
  Adding a DERP-server role and new discovery/dial paths is walking back into that minefield; R1's
  proof obligation is deliberately a *soak*, not a unit test, because these bugs are emergent under
  churn. This is the single biggest engineering risk and the reason R1 is isolated and gated.
- **Decentralized discovery is slower than a central directory — unavoidably.** n0's DNS service is a
  tuned, cached, globally-distributed resolver. Relay-gossip is fast *when a relay is warm* but slower
  cold; DHT is slower and variable. We buy independence with latency (and with a little metadata
  spread across more relays). The layered default hides this in the common (warm) case, but a cold
  cross-circle first-contact will be measurably slower than today. Honest, and accepted.
- **Someone must run a public relay for cross-NAT.** "Serverless" holds for the data model, not for
  NAT traversal: two peers behind symmetric NATs need a reachable third party. We make that role free,
  federated, and self-hostable — but not zero-operator. "Impossible to shut down" is therefore
  precisely: *impossible as long as anyone, anywhere, runs one relay* — which no single actor can
  prevent, but which is not literally infrastructure-free.
- **Apple app-store distribution is a hard wall.** Stock iOS has no sideload; if Apple pulls Haven,
  new iOS installs stop, full stop. Reproducible builds and off-store channels (Linux/Android/Windows)
  mitigate for those platforms; iOS has no engineering escape. Say so.
- **State-level DPI/IP-blocking is out of scope to defeat.** DHT + operator diversity raise the bar,
  but defeating DPI is Tor's problem, and `docs/TOR.md` declined Tor for sound QUIC reasons. This
  design does not claim censorship-*circumvention*, only censorship-*resistance* (no single seizable
  point), which is a weaker and honest claim.
- **The license is the quiet blocker.** All the engineering independence in the world doesn't make a
  PolyForm-Noncommercial project legally forkable. §8.4 is not optional garnish — without the license/
  survivorship decision, the "baton" is technically graspable and legally nailed down. This is a
  maker decision, not a code change, and it is the true gate on "survives the maintainer."
- **DHT and mDNS are unverified against the pinned crate.** Mainline-DHT discovery
  (`iroh-mainline-address-lookup`) and cross-platform mDNS are **not** in `core/Cargo.lock`
  (`pkarr.rs:40-43`; `address_lookup` has only dns/memory/pkarr). Both are flagged **verify: needs a
  spike** — the design leans on relay-gossip + operator-DNS as the load-bearing layers precisely so
  that the two unverified layers are *fallbacks*, not the foundation.

**Bottom line.** The n0 dependency (D1–D3) is real, is a single well-contained code surface, and is
removable on the *pinned* iroh with no fork — that part of "impossible to shut down" is genuinely
achievable and the plan above builds it. The remaining distance to *literal* un-shutdownability is
not engineering — it's the requirement that *someone* run a relay, that Apple not be the sole iOS
gatekeeper, and that the license and signing keys be arranged so the project can outlive its maker.
Those are named honestly, gated in R6, and not overclaimed.
