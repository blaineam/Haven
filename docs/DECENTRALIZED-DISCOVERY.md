# Decentralized discovery: Haven relays as the bootstrap, not Google and Number Zero

**Status:** exploratory branch `haven-decentralized-discovery`. Record format, relay storage,
authorization, and the client are **implemented and tested**. The iroh `AddressLookup` shim and the
custom relay map are **staged, not built**. Feature flag defaults **OFF** — merging this changes no
shipped behavior.

**The goal.** Haven should not *depend* on infrastructure nobody in this project controls. Today it
does, in three places. Those services are fine and should stay wired in as fallbacks. What must
change is that they are currently the **only** path.

---

## 1. The dependency audit

Every place Haven's connectivity rests on a third party, with file:line. This was enumerated before
any design work.

### 1.1 iroh's n0 preset — DNS/pkarr address lookup **and** the default relay servers

`Endpoint::builder(N0)` applies, per `iroh-1.0.2/src/endpoint/presets.rs:112-137`:

* `PkarrPublisher::n0_dns()` — publishes this node's address to `https://dns.iroh.link/pkarr`
  (`iroh-1.0.2/src/address_lookup/pkarr.rs:127`).
* `DnsAddressLookup::n0_dns()` — resolves other nodes via n0's DNS server.
* `relay_mode(default_relay_mode())` — n0's public DERP relay fleet.

Every endpoint Haven binds uses it:

| File:line | What binds here |
|---|---|
| `core/haven-net/src/lib.rs:18` | `use iroh::endpoint::presets::N0` |
| `core/haven-net/src/lib.rs:125` | **the main node** — messaging + in-process relay, one endpoint |
| `core/haven-net/src/blobstore.rs:79` | import |
| `core/haven-net/src/blobstore.rs:683` | `BlobServer` (standalone relay/mailbox host) |
| `core/haven-net/src/blobstore.rs:1325` | `BlobClient::connect` (per-fetch endpoint) |
| `core/haven-net/src/s3tunnel.rs:34` | import |
| `core/haven-net/src/s3tunnel.rs:55` | S3 tunnel server endpoint |
| `core/haven-net/src/s3tunnel.rs:174` | S3 tunnel client endpoint |
| `core/haven-net/Cargo.toml:10` | `iroh = { version = "1", … }` |

`core/demo/src/main.rs:64,89` uses `RelayMode::Disabled` — demo only, not a shipping path.

There is **no** `RelayMode::Custom` anywhere in the tree. Nothing today can point Haven at a
self-hosted DERP relay.

### 1.2 Google's public STUN servers — WebRTC calls

Hardcoded, no configuration surface, identical on all three platforms:

| File:line |
|---|
| `apple/HavenApp/WebRTCCall.swift:71-72` |
| `android/…/core/CallManager.kt:103-104` |
| `desktop/ui/app.js:3370` |

`stun.l.google.com` / `stun1.l.google.com`. Google learns the IP of every Haven caller, and if it
ever stops answering, calls stop traversing NAT. There is no TURN server, so a symmetric-NAT pair
already fails today.

### 1.3 The push relay — a single Cloudflare Worker at a personal account

| File:line |
|---|
| `apple/HavenApp/PushManager.swift:22` |
| `android/…/core/Moderation.kt:28` |
| `desktop/src-tauri/src/engine.rs:30` |

`https://haven-push.blaineams3.workers.dev` — a compile-time constant in three languages. Changing
it requires shipping three app updates. This is deliverable 2's problem; see
`docs/NOTIFICATIONS-FALLBACK.md`.

### 1.4 What is already ours

Worth stating, because it is the foundation the design builds on and it is genuinely good:

* `core/haven-net/src/httprelay.rs` — a self-hosted relay with **per-request Ed25519 signatures**
  and a membership gate shared byte-for-byte with the iroh path
  (`blobstore::blob_forbidden`, `core/haven-net/src/blobstore.rs:998`).
* `core/haven-net/src/relay.rs` — mesh frame forwarding over relays we run.
* `core/haven-relay/` — the single-binary self-hostable relay, packaged for Debian, Docker, macOS,
  Windows.

Haven already has relays. It just never asked them where anyone is.

---

## 2. The design

### 2.1 Two separable problems

The n0 dependency is really two, and conflating them is why this looks harder than it is:

| Problem | Question | Answer |
|---|---|---|
| **Address lookup** | "Which relay / IP is node X on?" | New: signed records on Haven relays. **Built.** |
| **NAT traversal** | "Neither of us can hole-punch; who forwards our packets?" | `RelayMode::Custom` → a self-hosted `iroh-relay` server. **Staged.** |

Only the first needs new protocol. The second is configuration of software that already exists and
is already a dependency — `iroh-relay` ships a server, and iroh accepts a custom `RelayMap`. Writing
a bespoke DERP would be a mistake; there is nothing to invent.

### 2.2 The discovery record

A node's own signed statement of where it can be reached, stored on a relay under
`haven/disc/<node-hex>`. Implemented in `core/haven-net/src/discovery.rs`.

```text
  magic    : b"HVD1"           (4)
  node     : [u8; 32]         (32)   — the Ed25519 node id this record describes
  seq      : u64 LE            (8)   — monotonic; rollback defense
  expires  : u64 LE            (8)   — absolute unix seconds
  n_addrs  : u16 LE            (2)   — 0..=16
  addrs    : [u16 LE len ‖ utf8]*    — "relay:<url>" | "ip:<addr>:<port>"
  sig      : [u8; 64]         (64)   — Ed25519 over DOMAIN ‖ everything above
```

Three properties do all the work:

1. **Signed by the subject.** Not by the relay, not by a CA. The node id *is* an Ed25519 public key,
   so verification needs nothing but the id you were already going to dial.
2. **Bound to its key.** `verify(expect_node_hex, …)` refuses a record whose `node` field isn't the
   id you asked for. Without this a relay could shelve Bob's genuinely-signed record under Carol's
   key and misdirect every lookup for Carol. This is the single most important line in the module.
3. **Monotonic and expiring.** `seq` blocks rollback at the relay's write gate; `expires` bounds how
   long a stale answer survives even if the write gate is bypassed.

### 2.3 It rides the existing blob store — no new endpoint

Discovery records are ordinary keys in the store the relay already serves over both transports. No
new routes, no second auth system, no new port. Authorization is one carve-out, mirroring the proven
`haven/devroster/` pattern (`core/haven-net/src/blobstore.rs:1003-1009`):

* **PUT** — open to any signed peer, then verified by `verify_discovery_put` **before** the bytes
  are stored, on **both** transports (`httprelay.rs` PUT branch and `blobstore.rs` iroh PUT branch).
  It must be open: a device no relay has heard of has to be able to say where it is, or it can never
  be found. That is exactly the devroster argument, and it is safe for exactly the same reason —
  the body proves its own authorship.
* **GET / HAS** — open to any signed peer.
* **LIST / TOUCH / AGES** — *not* carved out. `discovery_node()` matches one exact 64-hex key and
  nothing else, so a prefix falls through to the ordinary membership + broad-prefix gates and is
  refused. This is deliberate: enumerability is the difference between "a relay answers questions"
  and "a relay hands over its address book."

### 2.4 Why GET is open (and why that is not a regression)

It is tempting to require circle membership for reads. It breaks bootstrap — the case that matters
most is a device nobody has authorized yet.

The honest comparison is not "open vs. closed", it is "open **to a relay the user chose**" vs. the
status quo, which is n0's public DNS where **anyone on the internet** can resolve **any** iroh node
id. Relay-served discovery is strictly less exposure than what ships today. The tradeoff is recorded
here rather than hidden because it is the one place the design gives something up.

### 2.5 Learning about relays: the `RelayBook`

A client needs at least one relay before any of this works. Three sources, in order of how most
users will actually get there:

1. **Contact-shared** — a relay announce already travels sealed inside circle state (frame 19). A
   relay you were invited to is a relay you can query.
2. **User-supplied** — paste a `host:port` in settings; the operator's own relay.
3. **Gossiped among known peers** — members you already trust can propagate the set.

`RelayBook` (in `discovery.rs`) is the syncable container, and its merge rules are written directly
against this project's scar tissue:

* **Absence is never deletion.** A peer that has never heard of relay B must not remove B. This has
  gone wrong twice here — resurrecting rclone remotes, and circles wiped on a fresh restore.
* **Removal is an explicit tombstone** (`present: false`) at a higher generation, *kept*, so it
  survives a sync round and beats a stale peer still holding the live entry.
* **On a generation tie, the tombstone wins.** That precise tie is what resurrected the rclone
  remotes.

All four rules have tests (`discovery.rs` `mod tests`).

### 2.6 Where this plugs into iroh (staged)

`AddressLookup` (`iroh-1.0.2/src/address_lookup.rs:333`) is a public two-method trait — `publish`
and `resolve` — and `Builder::address_lookup` is **additive**: iroh queries every registered lookup
concurrently and uses whatever answers. So the wiring is:

```rust
// staged — not built
Endpoint::builder(N0)                       // n0 stays: fallback, never removed
    .address_lookup(HavenRelayLookup::new(cfg))   // ours, tried in parallel
    .relay_mode(RelayMode::Custom(haven_relay_map))  // when relays are configured
```

`HavenRelayLookup` wraps `discovery::publish` / `discovery::resolve`, converting to iroh's
`Item`/`EndpointData`. The plumbing is `Node::spawn_with_discovery(secret, handler, cfg)`, with the
existing `spawn` delegating with `DiscoveryConfig::default()` (disabled) so no caller changes.

**Two landmines are load-bearing here** and both are already guarded in `discovery.rs`:

* **Never publish or resolve our own node id.** Dialing yourself sends iroh's path discovery into an
  unbounded loop — this cost ~98 GB in one recorded incident and a watchdog panic in another. The
  self-filter must sit in `HavenRelayLookup`, not only at the dial site, because a resolve result
  feeds addresses straight into iroh's address book.
* **Concurrent lookups for a dead id must be single-flighted**, for the same reason
  `Node::conn_for` single-flights dials (`core/haven-net/src/lib.rs:88-96`): a check-then-act gate
  is bypassed by a burst, and a dead id takes ~30 s to time out.

### 2.7 Reflexive addresses (STUN-equivalent) — deliberately not faked

A relay *could* echo the source address it sees on an HTTP request. **That is not a STUN
substitute**, and the difference matters: the observed **TCP** source port is not the **UDP** port
QUIC is using, and on most NATs it will not even be in the same mapping. Such an endpoint would
yield a correct public IP and a useless port — which is worse than nothing, because it looks like it
works.

The real options, in preference order:

1. **Run `iroh-relay`'s server on the Haven relay host.** It already does QUIC address discovery and
   DERP forwarding, it is already in the dependency tree, and it is the software n0 itself runs.
   This is the recommendation.
2. A dedicated `HVSTUN1` UDP responder on the relay. Only worth building if (1) proves impractical.

For WebRTC calls specifically (`§1.2`), the ICE server list should become **configuration derived
from the `RelayBook`**, with Google's STUN retained as a trailing fallback entry rather than the
only entry. A self-hosted `coturn` gives STUN *and* TURN, which also fixes symmetric-NAT calls that
fail today. That is a packaging task, not a protocol one.

---

## 3. Threat model

**Assumption:** the relay is fully hostile — operator compromised, host seized, or a lawful order
compelling cooperation. Node ids and discovery records are public. The attacker cannot break
Ed25519.

| # | Attack | Outcome | Why |
|---|---|---|---|
| T1 | Serve a forged address for Bob | **Fails** | Records are signed by Bob's node key. Tested: `refuses_tampered_address`. |
| T2 | Shelve Bob's real record under Carol's key | **Fails** | `verify` binds record→key. Tested: `refuses_record_shelved_under_the_wrong_key`, and end-to-end at the relay (`relay_is_a_shelf_not_an_authority` §2). |
| T3 | Redirect a dial to a relay-controlled endpoint | **Fails** | Discovery yields *hints*. QUIC/TLS authenticates the **node id** end-to-end; a wrong endpoint fails the handshake. Discovery does not participate in authentication at all. |
| T4 | Replay an old record to pin Bob to a dead address | **Fails** | `seq` monotonic at the write gate; `expires` absolute. Tested end-to-end (§3 of the integration test). |
| T5 | Truncate / pad / re-encode a record | **Fails** | Fixed layout, trailing bytes rejected, size-bounded. Tested: `refuses_trailing_garbage`, `refuses_truncated_and_oversize`. |
| T6 | Enumerate every node the relay has seen | **Fails via this API** | LIST is not carved out; the membership + broad-prefix gate refuses it. Tested end-to-end (§5). |
| T7 | Withhold Bob's record | **SUCCEEDS — accepted** | A relay can always deny service. Mitigation: configure several; n0 lookup remains a fallback. |
| T8 | Log "A asked about B" — social graph | **SUCCEEDS — partially pre-existing** | A relay already sees `dest` node ids on every routed frame (`relay.rs` module docs) and every mailbox key. Discovery adds query-time edges for peers whose messages never touch that relay. Not mitigated. Honest statement: use a relay you trust, or more than one. |
| T9 | Serve a record for a node that doesn't exist | **Harmless** | It would have to be signed by that node's key. It isn't. |
| T10 | Roll a relay's own identity to MITM | **Fails** | The relay is dialed by node id, same as any peer. Its URL is a hint; its key is the identity. |

**The invariant:** *a relay can deny service and learn who asks about whom. It cannot make a
connection go to the wrong place.* Everything above is a restatement of that.

Not addressed, and deliberately out of scope here: traffic analysis by a network observer, and a
compromised **device** (which loses the node key and thus the whole game regardless).

---

## 4. What was built vs. what is staged

### Built and verified

| Piece | Where |
|---|---|
| `AddrRecord` — layout, sign, verify, expiry | `core/haven-net/src/discovery.rs` |
| `verify_discovery_put` — rollback defense | same |
| `discovery_node` — exact-key matcher (anti-enumeration, anti-traversal) | same |
| `RelayBook` — presence + generation LWW merge | same |
| `DiscoveryConfig` — the flag, default OFF | same |
| `publish` / `resolve` clients (dependency-free HTTP/1.1) | same |
| Relay authorization carve-out | `core/haven-net/src/blobstore.rs:1003-1019` |
| Write gate, **HTTP** transport | `core/haven-net/src/httprelay.rs` PUT branch |
| Write gate, **iroh** transport | `core/haven-net/src/blobstore.rs` iroh PUT branch |
| 14 unit tests | `discovery.rs` `mod tests` |
| 2 end-to-end tests against a real relay | `core/haven-net/tests/discovery_relay.rs` |

`cargo check --tests` clean across the workspace; all 16 tests pass.

### Staged — designed, not built

1. `HavenRelayLookup: AddressLookup` + `Node::spawn_with_discovery` (§2.6), including the
   self-id filter and lookup single-flight.
2. `RelayMode::Custom` plumbing and an `iroh-relay` server in `haven-relay` (§2.7).
3. `RelayBook` persistence + self-sync wiring (LWW semantics are built and tested; storage is not).
4. FFI/UniFFI surface + platform settings UI.
5. Configurable ICE servers for WebRTC (§1.2), ideally self-hosted `coturn`.

### Unproven — say so plainly

* **No two real devices have connected using this.** Everything is verified against a local relay
  in-process. Cross-NAT behavior is untested.
* **The `AddressLookup` conversion is unwritten**, so the claim "iroh will accept our hints
  alongside n0's" is read off the trait signature and docs, not observed.
* The `iroh-relay`-as-DERP recommendation is **not prototyped**. It is the obvious answer and n0
  runs exactly this, but "obvious" is not "tried".
* No performance work at all: no lookup caching, no publish backoff, no negative-answer cache.
* `MAX_RECORD` / `MAX_ADDRS` / `DEFAULT_TTL_SECS` are reasoned guesses, not measured.
