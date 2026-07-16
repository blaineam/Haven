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
  cryptographic, not advisory (`core/p2pcore-ffi/src/lib.rs:1128`, `:1521`, `:2516`). Only the last 4
  epoch keys are retained (`prune_epoch_keys`, `lib.rs:1041-1063`).
- **Device-roster revocation is _advisory_, not cryptographic.** Revoking one of your **own** linked
  devices rotates the epoch too, but every epoch key still seals to the account key as well —
  `recipients_with_devices` **always** adds it (`core/p2pcore/src/device.rs:358-363`) — and a linked
  device holds a _copy_ of the master seed (linking transfers `haven-seed:` / `haven-link:`; enrollment
  only adds a device key to a device that already has the seed). So a revoked device that still holds the
  seed keeps decrypting, and can even re-sign a higher-version roster re-adding itself. Revocation
  therefore defeats a device that is **lost or stolen** (keychain intact, seed not extracted), not one
  that is **compromised**. Making it cryptographic needs the seed-drop re-key (D16 Phase 2), which is
  **not yet built** (`core/p2pcore/src/device.rs:371-373`); until it lands, the only remedy against a
  genuinely compromised device is starting a new identity.
- **Forward secrecy — read this carefully.** Pruning bounds it *only once the epoch has actually
  moved*, and today the epoch moves **only on removal/block/device-roster change**. The periodic
  rotation the design calls for is implemented in core (`rotate_circle`, `lib.rs:1518`) but **is not
  yet called by any client** — so in a stable circle with no membership churn, the epoch never
  advances and one seed compromise still decrypts that circle's history. Haven does **not** have
  per-message forward secrecy or post-compromise security; that needs MLS, which is **not built**
  (the current layer is multi-recipient PKE — `core/p2pcore/src/social.rs:14-16`). Wiring the
  periodic cadence is tracked in `ROADMAP.md` → Outstanding.
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
  `core/p2pcore/src/social.rs:70`, authored at `core/p2pcore-ffi/src/lib.rs:1960`), because circles
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

## Third-party services

- **Apple Push Notification service (APNs)** via a self-hosted **Cloudflare Worker** push server — the
  worker is blind (encrypted payload; the on-device Notification Service Extension decrypts).
- **iroh / number0 (n0)** public discovery + relay infrastructure for P2P NAT traversal (metadata only;
  no content).
- **The user's own** relay binary and/or S3-compatible bucket (their infrastructure, blind storage).
- **WebRTC** (DTLS-SRTP) for calls; STUN for connectivity. No analytics, telemetry, crash reporters,
  or ad SDKs — verified by audit.

## Export compliance

Standard, published algorithms only; `ITSAppUsesNonExemptEncryption = NO`. The app is submitted to the
relevant export bureaus; no proprietary cryptography.
