# Haven — security model & threat model

Haven is a peer-to-peer, end-to-end-encrypted, post-quantum social network. **No content is ever sent
to the developer, and no content is logged.** Content travels only between the people in a user's
circles — directly over Bluetooth/Wi-Fi/iroh P2P, or store-and-forwarded through a relay/S3 mailbox
that one of the circle's own members runs. Every relay and server is **blind**: it holds only
ciphertext.

"No content" is the exact scope, and the qualifier is load-bearing: explicitly **reporting** someone
sends a **content-free** ledger entry to the developer (see *Moderation & reporting* below), and the
push Worker necessarily handles routing metadata. Those are the only things that reach the developer,
and neither includes a byte of what anyone said or shared. **Blocking someone sends nothing** — it is
local and private.

This document records what Haven protects, how, and the limits — including the two features that are
**privacy deterrents, not cryptographic guarantees**. It reflects the post-audit state (2026-07).

## Cryptography

- **Hybrid post-quantum** throughout: key establishment is X25519 + ML-KEM-768 (FIPS 203), signatures
  are Ed25519 + ML-DSA-65, AEAD is AES-256-GCM, KDF is HKDF-SHA256. Both halves must break to lose
  security, so Haven is never weaker than classical and resists "harvest-now-decrypt-later". The KEM
  derivation binds the full transcript (ephemeral key, ciphertext, recipient keys).
- **Group keying (sender keys + epochs)** — see `GROUP-KEYING.md`. Each member seals their posts under
  an epoch key distributed to the current members via the hybrid KEM. Removing or blocking a **member**
  (a contact who never held your account seed) rotates the epoch and seals the new key only to the
  remaining members, so that node **cannot decrypt content posted afterward** — this member removal is
  cryptographic, not advisory (`core/haven-ffi/src/lib.rs:1128`, `:1521`, `:2516`). Only the last 4
  epoch keys are retained (`prune_epoch_keys`, `lib.rs:1041-1063`).
- **Device-roster revocation is _cryptographic_ as of 1.0.7 (seed-drop), gated per circle.** It used to
  be advisory: every epoch key also sealed to the bare account key, and a linked device held a _copy_ of
  the master seed (linking transferred `haven-seed:` / `haven-link:`), so a revoked device kept
  decrypting and could re-sign a higher-version roster to re-add itself. Seed-drop (D16 Phase 2) re-roots
  day-to-day operation on **per-device keys**: a device enrolled through the **seedless** flow holds only
  its own device keypair plus an account-signed `DeviceCredential` and never receives the master seed,
  which concentrates on one **primary** device (Enclave-wrapped) plus the SE-wrapped iCloud-Keychain
  escrow. Sealing runs through `recipients_with_devices_gated` (`core/haven-p2p/src/device.rs:755`,
  called at `core/haven-ffi/src/lib.rs:6137`): when the retirement switch is ON **and** every member is
  affirmatively seed-drop-capable, the bare account key is **dropped** and content seals to authorized
  device bundles only — so a revoked device is cut off even from a seed-holding member. The
  account-leaf-retired roster flag (`DeviceList::with_account_leaf_retired`,
  `core/haven-p2p/src/device.rs:370`) is monotone/sticky and only the account key can mint it, so a
  seedless device cannot forge a higher-version roster to re-add itself. Revoking also re-keys the
  account-state self-sync stream, so a revoked device can no longer read or write profile / contacts /
  circles / settings. Every shipping client turns the switch on for a seed-holding device
  (`apple/HavenApp/FeedStore.swift:792`, `android/…/core/HavenNet.kt:569`,
  `desktop/src-tauri/src/engine.rs:683`), but the **gate lives in core**, not the client: a circle with
  even one un-upgraded member stays on the legacy dual-seal path and everyone keeps reading
  (`docs/SWITCH-FLIP-1.0.7.md`). **The honest residue:** a **primary** device still holds the seed, so
  compromising *it* is a full account compromise — the remedy there is starting a new identity, not
  revoking.
- **Forward secrecy — read this carefully.** Pruning bounds it *only once the epoch has actually
  moved*. The epoch moves on removal/block/device-roster change **and, as of the 2026-07 hardening,
  on a periodic 7-day cadence** driven by the full sync bundle (`ROTATE_INTERVAL_SECS`, `lib.rs:1061`;
  `maybe_rotate`, `lib.rs:1131-1149`) — so even a quiet circle with no membership churn advances its
  epoch, and with the last four epochs retained a seed compromise exposes on the order of the last
  month of captured ciphertext rather than a circle's whole history. (The manual `rotate_circle` FFI
  at `lib.rs:1518` remains test-only; the periodic path above is what actually runs.) Per-message
  forward secrecy and post-compromise security come from the **MLS-style TreeKEM group layer, which
  shipped in 1.0.7** (`docs/TREEKEM-DESIGN.md`) — enabled for circles with a **verified owner**, i.e.
  the ones created from 1.0.7 on. It is gated exactly like seed-drop: a circle turns over only once
  every member's devices have updated and joined, and circles that predate 1.0.7 have no owner to
  anchor it (one can't be added after the fact in a way other members could trust), so they keep the
  epoch scheme described above — which still cuts off anyone you remove. Two honest qualifiers: its
  audit to date is an **internal** AI-driven adversarial review (0 critical, 0 high), **not** a formal
  external one, and no paid external audit is planned (see [Security review](#security-review)) — and
  it is MLS-*shaped*, TreeKEM mechanisms over Haven's own post-quantum primitives, **not** RFC-9420
  wire-interoperable.
- **Authentication**: every event is signed and the signer is bound to the event author and circle
  epoch; push notifications are signed (the receiver verifies the sender); push registration is signed
  (the worker verifies the device belongs to the identity). Signatures are domain-separated; there is
  no general signing oracle.
- **At rest**: the master seed is wrapped by the Secure Enclave; the decrypted social state, media, and
  scheduled queue use file-protection so they're unreadable on a locked/forensic device.

## What a relay / server can and cannot do

- **Cannot** read content, contacts, keys, or notification text — everything it stores or forwards is
  sealed; the push worker only forwards opaque ciphertext.
- **Cannot be enumerated by strangers**: the relay enforces **circle-membership authorization** — a
  circle's mailbox (read, write, and list) is served only to that circle's members (and its sibling
  relays, for replication). A node that merely learns the relay's id can no longer fetch or enumerate a
  circle's blobs. Self-sync slots are likewise access-controlled to their owning account. (Standalone
  self-host relays stay permissive until configured; the apps configure membership automatically.)
- **Can** see **limited metadata**: connection timing, blob sizes, and **`IP ↔ node id` for every peer
  it serves** — both via the iroh/n0 public discovery used for NAT traversal *and* directly, because the
  relay reads the connecting peer's verified node id off the QUIC handshake
  (`core/haven-net/src/blobstore.rs:537`) and needs it to enforce the membership check above. Your node
  id is your public key. It also sees — for a member-run relay, which knows its own circle's config
  anyway — the random circle UUIDs in key paths. Content, contacts, and keys remain sealed. A user with
  a stricter threat model can run their own relay/discovery, or put Haven behind a VPN. *(Core
  groundwork also exists for opaque/HMAC'd per-member key prefixes, for the case of a
  non-member-operated relay — `groupkey.rs:108`, not yet called by any client.)*

## Identity & control

- The user can **roll their identity** at any time (a true reset that abandons the old social graph),
  **remove** any member from a circle, or **block** them. Block/remove are now cryptographically
  enforced going forward (epoch rotation), not just local filtering.
- Users curate their own circles (who they approve, remove, and block).

## Moderation & reporting

**Server-side content moderation is impossible; reporting exists and ships.** Those are two different
claims, and only the first is about cryptography:

- **No *content* moderation is possible, by construction.** Content is E2EE between circle members;
  the developer holds no key and stores no copy, so there is no content for anyone outside the circle
  to review, filter, or take down. Nothing in this section changes that.
- **Reporting is shipped on all three platforms**, and it is *member*-scoped. A report is sealed to
  the **whole circle** as an ordinary event (`EventKind::Report` —
  `core/haven-p2p/src/social.rs:70`, authored at `core/haven-ffi/src/lib.rs:1960`), because circles
  have no owner: every member judges it and acts with the power they already hold — hide, remove, or
  block. The reporter's free-text comment goes **only** to the circle.
- **An explicit report also sends a content-free entry to the developer**, via `POST /flag` to the
  push Worker (`apple/HavenApp/ReportUI.swift:15-30`; Android:
  `android/.../core/Moderation.kt:34`). The stored row is `{subject, action, reason}`
  (`push/worker.js:146-175`) — the reported identity key, the literal string `report`, and an offense
  category. **Never content, never PII.** See `MODERATION.md` for the design and `TERMS.md` §3 for
  the consequences attached to it (possible refusal of developer-operated services, disclosure where
  legally required).
- **Blocking sends nothing, and cannot.** It is local and private on Apple
  (`apple/HavenApp/FeedView.swift:540-547`) and Android (`Moderation.kt` exposes report only), and a
  block is not representable on the Worker at all: `/flag` hard-rejects every action but `report`
  (`push/worker.js:159`), so no block can be stored even by an old or modified client. *(The desktop
  client still POSTs on block — `desktop/src-tauri/src/engine.rs:1311` — but the Worker refuses it,
  so nothing is recorded. It should stop asking; tracked below.)*

**What the ledger does and does not hold** (all four properties are enforced in code, per audit F1):

- **No actor is stored.** The row carries no reporter identity — not even hashed. Node ids are
  enumerable, so any hash the Worker could compute, the operator could invert; not storing it is the
  only honest way to not hold the "A reported B" edge (`push/worker.js:153-156,174`). Be precise
  about the limit: the reporter's key **is** transmitted, because verifying the signature requires
  it, so the Worker *observes* the actor in memory and only *persistence* is ruled out by code. That
  is the same operator-policy boundary as the IP metadata above, not a cryptographic one.
- **Signed, so not forgeable.** The reporter must prove their identity key over
  `flag-v1:<subject>:report:<category>` + timestamp, checked with the same Ed25519 `verifyReg` the
  `/register` routes use (`push/worker.js:168`; signed client-side at `ReportUI.swift:25`). An
  unauthenticated POST cannot plant a row against anyone, and the signature binds subject, action,
  and category, so a captured report cannot be re-aimed or re-labelled.
- **Replay-inert.** The key derives from the signed timestamp + signature, so re-POSTing a captured
  report rewrites the same row instead of inflating the "many reporters" count
  (`push/worker.js:171-173`); outside `verifyReg`'s 5-minute window it is rejected outright.
- **Expiring.** Rows carry a 90-day TTL (`push/worker.js:175`). Not permanent.

Still worth stating plainly: this is a record the developer holds *about a reported identity*. It is
content-free, actor-free, and expiring — but it is not nothing, and it is the one place the "the
developer holds nothing" instinct needs a qualifier.

**Known gap:** the desktop client has not caught up to the signing above — it still sends the old
unsigned `{actor, subject, action, reason}` body (`desktop/src-tauri/src/engine.rs:1056-1076`). The
Worker rejects it (401), so desktop reports currently reach the *circle* but never the ledger, and
desktop's block POST is refused (400). No data is exposed by this; it is a parity bug, not a leak.

## Deterrents, not guarantees (do not over-rely)

- **Secret messages** (screenshot-protected): the recipient is handed the plaintext like any message;
  the "secret" rendering is a same-device, same-client UX deterrent against shoulder-surfing and
  casual screenshots. A determined recipient (or a modified client) can read it normally. It is **not**
  protection *against the recipient*.
- **Biometric circle locks**: gate the in-app UI for a circle. They are a privacy convenience, not an
  access-control boundary for a fully-compromised, unlocked device.

## Link previews (peer-supplied URLs)

A link preview is the only place where a **peer's message decides what your device connects to**, so
it is treated as hostile input rather than as a rendering detail.

- **Nothing is fetched on render.** Previews load only when you tap **Load preview**. Automatic
  fetching turned any message into an IP-and-online-presence beacon aimed at the *recipient* — the
  sender learned when you read and from where, with no tap and no consent — and let a sender aim your
  device at a host of their choosing. Note that Haven sets `NSAllowsLocalNetworking` (for the LAN
  relay media path), so App Transport Security does **not** backstop this; the check below does.
- **Non-public destinations are refused** before connecting: loopback, RFC1918 private space,
  link-local (including `169.254.169.254` cloud metadata), CGNAT `100.64/10`, IPv6 unique-local,
  multicast and reserved ranges. Every address a host resolves to must be public — one private record
  disqualifies the host. Implemented in `LinkSafety` on both Android and Apple.
- **Redirects are followed by hand and re-vetted per hop** (max 3) on Android, because a public host
  answering `302 → 169.254.169.254` otherwise defeats the destination check. On Apple the fetch is
  `LPMetadataProvider`, which follows redirects internally with no hook to inspect them; that residual
  is bounded by the tap gate — after an explicit tap the exposure matches tapping the link into the
  in-app browser, which would follow the same redirect.
- **Transfers are bounded**, not truncated after the fact: 256 KB for HTML, 2 MB for a poster image,
  with connect/read timeouts. Poster images are size-checked from their header before rasterizing, so
  a small file declaring enormous dimensions cannot blow the heap.
- **The preview cache is bounded** (LRU, 64 entries) and negative results expire, so browsing a busy
  circle cannot grow it without limit and one failed fetch is not permanent.

Residual, stated plainly: destination checking is resolve-then-connect, so a DNS rebind with a very
short TTL could still swap the answer between the check and the connection. Closing that needs
dialing the vetted IP directly while carrying the original `Host` header. The exposure is narrow —
it requires winning a sub-second race to reach a LAN address whose response is never surfaced beyond
a title — and it cannot happen at all without an explicit tap on that specific link.

## Third-party services

- **Apple Push Notification service (APNs)** via a self-hosted **Cloudflare Worker** push server — the
  worker is blind (encrypted payload; the on-device Notification Service Extension decrypts).
- **iroh / number0 (n0)** public discovery + relay infrastructure for P2P NAT traversal (metadata only;
  no content).
- **The user's own** relay binary and/or S3-compatible bucket (their infrastructure, blind storage).
- **WebRTC** (DTLS-SRTP) for calls; STUN for connectivity. No analytics, telemetry, crash reporters,
  or ad SDKs — verified by audit.

## Security review

Haven's audit to date is an **internal adversarial review** (0 critical, 0 high). There is **no paid
external audit and none is planned** — Haven is free, unfunded, and a paid engagement is not something
this project can carry.

**Independent review is welcome from anyone.** No permission needed, no scope restrictions, no bug
bounty. If you find something:

- Report it **privately** to **<apps@wemiller.com>** so it can be fixed before disclosure.
- Real findings are **credited by name** in the release notes and contributor list, if you want the
  credit. Say so if you would rather stay anonymous.
- The interesting surface is the group-keying layer: `core/haven-p2p/src/treekem.rs` (tree math, the
  epoch key schedule, the fork tie-break and chain rule), `device.rs` (roster authority, credential
  chaining, admin grants), and the `mls_*` engine wiring in `core/haven-ffi/src/lib.rs`. The design
  is written up in [`TREEKEM-DESIGN.md`](TREEKEM-DESIGN.md) and [`SEED-DROP-DESIGN.md`](SEED-DROP-DESIGN.md).
- The wire parsers are continuously fuzzed in CI
  (`core/haven-p2p/tests/fuzz_wire_parsers.rs`); start above that layer.

Primitives are standard and not homegrown — X25519 + ML-KEM-768, Ed25519 + ML-DSA-65, AES-256-GCM,
HKDF-SHA256, BLAKE3, via vetted crates. The protocol composed from them is Haven's own, and that is
where review is worth your time.

## Export compliance

Standard, published algorithms only; `ITSAppUsesNonExemptEncryption = NO`. The app is submitted to the
relevant export bureaus; no proprietary cryptography.
