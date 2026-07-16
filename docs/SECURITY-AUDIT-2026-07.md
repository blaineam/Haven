# Security audit — 2026-07 (pre-v1)

Scope: the whole product as of `f0ad60d`, audited against the standing mandate:

> **Audit every feature; the maker must NOT hold keys or be a bypass target.**

Method: read the code, not the comments. Every finding cites `file:line` against the tree at
`f0ad60d`. Claims were taken from `docs/SECURITY.md`, `docs/GROUP-KEYING.md`, `docs/MODERATION.md`,
`docs/LINK-SYSTEM.md`, `docs/NOTIFICATIONS.md`, `docs/HAVEN-NET-RELAY.md`, `docs/RELAY-AND-DEPLOY.md`,
`docs/THREAT-MODEL.md`, `docs/TERMS.md`, `web/`, and `appstore-metadata.md`, and then attacked.

**A false claim is a finding.** Several here are documentation findings: the code is safe and the doc
promises more (or less) than the code delivers. Those are ranked alongside the code bugs because the
docs are public and load-bearing.

---

## Headline

**The mandate is intact on content, and broken on metadata — in one specific, shipped place.**

Nothing anywhere in this codebase lets Blaine, a relay operator, or the website read a post, a
message, or a media item. I attacked that from five directions and could not move it. The hybrid PQ
construction is real, the epoch revocation is real, the Worker and the website are structurally
blind. On the thing the project cares most about, the answer is: **no glaring holes.**

But `POST /flag` (`push/worker.js:146-163`) writes a **permanent, unauthenticated, forgeable
identity-vs-identity graph** into the developer's KV — and fires automatically on every *block*, an
act users reasonably believe is private and local. `docs/TERMS.md:43-45` then attaches real
consequences to those rows (service refusal, disclosure to law enforcement). That is the maker
holding something he promised not to hold, populated by a channel anyone can forge into.

That is **F1**, and it is the one finding I would gate v1 on for mandate reasons. The other ship
blockers (**F2**, **F3**) are ordinary security bugs of the "default transport has no authorization"
kind — serious, but not mandate violations.

---

## Severity summary

| # | Finding | Severity | Blocks v1? |
|---|---|---|---|
| F1 | Moderation ledger: unauthenticated, forgeable, permanent identity graph held by the developer | **Critical** | **Yes** |
| F2 | HTTP relay (`:8674`, the default media transport) has zero circle-membership authorization | **Critical** | **Yes** |
| F3 | Unauthenticated `/call` + NSE ignores verified sender → lock-screen spoofing & ring-spam | **High** | **Yes** |
| F4 | `haven/devroster/**` + `haven/media/**` readable/enumerable by strangers, no token | **High** | **Yes** |
| F5 | Media refs are random UUIDs, not content addresses; no blob↔ref binding | **High** | **Yes** |
| F6 | Media is plaintext at rest; on macOS with no protection at all | **High** | Yes (or fix docs) |
| F7 | `SECURITY.md` flatly contradicts shipped reporting/ledger + `MODERATION.md` | **High** (docs) | **Yes** |
| F8 | `RELAY-AND-DEPLOY.md` promises "ephemeral rendezvous tokens" that do not exist | **High** (docs) | **Yes** |
| F9 | Relay bearer token crosses the wire in cleartext; no TLS; token never rotates | **High** | Yes |
| F10 | Connection relay is an open forwarder with 32× amplification | **High** | Yes |
| F11 | `DeviceKeyStore` has the locked-read-overwrite bug the master seed was hardened against | **Medium** | No |
| F12 | Transient SE failure silently downgrades a seed copy to plaintext | **Medium** | No |
| F13 | Transient read failure destroys the identity-recovery archive | **Medium** | No |
| F14 | No quota / rate limit / content-address verification → disk exhaustion, mesh-amplified | **Medium** | Community-relay story only |
| F15 | HVCHUNK1 manifest is unauthenticated; unbounded chunk count → remote disk-fill | **Medium** | No |
| F16 | Routing header leaks the co-recipient set (= the circle graph) | **Medium** | No (docs must be honest) |
| F17 | `quick-xml` 0.36.2 in `haven-s3`: two 7.5-high advisories, attacker-reachable | **Medium** | No |
| F18 | DM authorization degrades to "member of any circle on this relay" | **Low-Med** | No |
| F19 | `HAVEN_SCENE` is not DEBUG-gated; auto-opens the seed-backup sheet in release | **Low-Med** | No |
| F20 | Worker observes sender-IP × recipient-identity in real time | **Low** | No (docs) |
| F21 | `api.github.com` fetch fires on every page load, including post-link opens | **Low** | No |
| F22 | Demo seeding drives the real store on Apple/Android (desktop isolates correctly) | **Low** | No |

---

## F1 — CRITICAL: the moderation ledger is a developer-held, permanent, forgeable identity graph

**The claim.** `docs/SECURITY.md:3-4`: "**Nothing is sent to the developer; nothing is logged.**"
And `docs/SECURITY.md:49-51`: "There is **no content moderation or reporting** by design, **and it is
not possible**: content is E2EE between community members, the developer has no access to it and logs
nothing, so there is nothing to moderate or report to."

**What the code does.** `push/worker.js:146-163` implements `POST /flag`, writing a **permanent** KV
row `ledger:<ISO-ts>:<uuid>` = `{actor, subject, action, reason}`. There is no `expirationTtl`.
`docs/MODERATION.md:47` states the intent plainly: "Entries are permanent by design."

It fires on every **block**, silently, on all three platforms:

- `apple/HavenApp/FeedView.swift:542` — `ModerationLedger.record(action: "block", …)`
- `apple/HavenApp/FeedView.swift:926` — on report
- `android/.../HavenNet.kt:853`, `:1187` — same, on report *and* block
- `apple/HavenApp/ReportUI.swift:21` — sends `FeedStore.shared.myAccountHex`, the user's real account id

**`/flag` performs no signature check.** I verified this directly: `verifyReg` is called at
`worker.js:29` (`/register`), `:46` (`/register-owner`), and `:59` (`/register-voip`) — and nowhere
else. `/flag`'s only validation is a hex regex (`worker.js:154`) and an IP-keyed best-effort rate
limit (`:156`).

`docs/TERMS.md:43-45` then attaches consequences: *"Identities that accumulate abuse reports may be
refused the services the developer does operate (such as push notification relaying), and ledger
entries may be shared with law enforcement where legally required."*

**Impact.** Three distinct problems, compounding:

1. **Mandate violation.** Blaine holds a permanent, timestamped, append-only graph of "identity A
   acted against identity B", plus each actor's IP at the Cloudflare edge. That is a social graph.
   The mandate says he must not become this.
2. **It is forgeable, which makes it both dangerous and worthless.** Because `actor` is
   unauthenticated, anyone can write unlimited entries attributing reports to arbitrary identities
   against a victim. The ledger's *only* stated value is "many distinct reporters × one identity is
   signal" (`MODERATION.md:44`) — precisely what forgery manufactures. An unauthenticated endpoint
   should not be able to trigger service denial or plant law-enforcement records.
3. **Block is a private, defensive act.** Users are never told at block time that it phones home.
   The disclosure exists only in `TERMS.md`/`MODERATION.md`, while `SECURITY.md` — the doc users and
   auditors actually read — asserts the opposite.

**Recommended fix** (do not apply from this doc; these are precise instructions):

1. **Sign `/flag`.** Domain-tagged Ed25519 over `actor|subject|action|ts`, verified with
   `verifyReg`-shaped logic (`worker.js:272-286` is the template, including its 5-minute window).
   Non-negotiable given the Terms' consequences.
2. **Stop auto-recording `block`.** Remove the ledger call at `FeedView.swift:542` and
   `HavenNet.kt:853`. Report only, and only with an explicit "also notify the developer" checkbox.
3. **Drop `actor`, or store `HMAC(actor, rotating_key)`.** `subject + action` is sufficient for
   pattern detection and removes the graph edge entirely.
4. **Add `expirationTtl`** (90d). "Permanent by design" is indefensible for a forgeable record.
5. **Reconcile `SECURITY.md:3-4` and `:49-51` with reality** — see F7.

---

## F2 — CRITICAL: the HTTP relay path has zero circle-membership authorization

**The claim.** `docs/SECURITY.md:35-37`: "the relay enforces **circle-membership authorization** — a
circle's mailbox (read, write, and list) is served only to that circle's members… A node that merely
learns the relay's id can no longer fetch or enumerate a circle's blobs."

**What the code does.** `httprelay::serve(root, bind, token)` (`core/haven-net/src/httprelay.rs:82`)
never receives `RelayAuth`. `handle_conn` (`:102`) checks exactly two things: a bearer token
(`:121-122`) and `checked()` (`:235-241`), which only enforces the `haven/` prefix + `safe_path`.
**`mailbox_forbidden` is never called from this file.** The iroh path calls it correctly at
`core/haven-net/src/blobstore.rs:754`; the HTTP path does not.

This path is **on by default everywhere**: `DEFAULT_HTTP_BIND = "0.0.0.0:8674"`
(`core/haven-relay/src/config.rs:230`), enabled unless `--no-http` (`config.rs:164-168`), started at
`runner.rs:91-92`, `apple/HavenApp/RelayHost.swift:94`, `android/.../HavenNet.kt:1806`,
`desktop/.../engine.rs:1767`, and published by `relay/docker/docker-compose.yml:38`. And there is
**one token per relay** (`config.rs:234-249`; `RelayHost.swift:107-115`) — per-device, not
per-circle — handed to every circle the relay serves.

**Evidence.** Probed against a real `httprelay::serve` in the scratchpad, caller a member of no
circle holding only the relay token:

```
GET /l/haven                          → 200  haven/devroster/deadbeef
                                             haven/mailbox/fam/aaaa
                                             haven/mailbox/secretclub/bbbb
GET /k/haven/mailbox/secretclub/bbbb  → 200  SEALED-secretclub-post
PUT /k/haven/mailbox/secretclub/injected → 200 OK
GET /l/haven/devroster                → 200  haven/devroster/deadbeef
```

**Impact.** Any token holder — by design, every member of *any* circle on the relay — can enumerate
every circle on that relay, read every blob, and write into any circle's mailbox. The entire point
of the community/mesh relay model (`RELAY-AND-DEPLOY.md:42,47-76`) is that strangers' circles
co-tenant one relay. Content stays sealed, so this is not a plaintext break — but the enumeration
claim and the per-circle boundary are **false on the default transport**. The unit test at
`httprelay.rs:396-405` exercises `haven/mailbox/fam/` writes with no membership concept present.

**Recommended fix.** A shared bearer token structurally cannot express membership, because HTTP here
has no verified peer identity. In preference order:

1. Authenticate with the member's node key: `Authorization: Haven <nodehex>.<sig over
   method|path|ts|nonce>`, giving HTTP the identity iroh already has, then call `mailbox_forbidden`
   with it.
2. Interim: per-circle tokens (`token_c = HMAC(relay_secret, circle_id)`, shipped per-circle in the
   frame-19 announce), bind the circle from the key prefix, and hard-refuse broad `haven` /
   `haven/mailbox` prefixes over HTTP.

Note `appstore-metadata.md:72` describes this as "an authenticated local HTTP interface (port 8674)".
That is true only in the weakest sense (a shared bearer token) and should not be read as membership
authorization.

---

## F3 — HIGH: unauthenticated `/call` + NSE ignores the verified sender

**The claim.** `docs/SECURITY.md:23`: "push notifications are signed (**the receiver verifies the
sender**)."

**What the code does.** The signature *is* verified, and verified well —
`core/haven-ffi/src/lib.rs:331-353`, binding recipient + domain tag at `:317-323`. But the core's
own doc comment warns at `core/haven-ffi/src/lib.rs:309-310`:

> "The receiver should still confirm it's a known contact before trusting the display name — **the
> signature proves authenticity, not authorization**."

Nothing does. `apple/HavenNotificationService/NotificationService.swift:37-38` ignores
`opened.sender_hex` and renders `opened.data` directly. There is no known-contact check. `/notify`
requires no signature (`worker.js:171-177`), and node ids are public by design (they are in every
reach-me link and QR). So:

> Any stranger mints a throwaway identity → seals+signs `{t:"Mom", b:"I'm stranded, send money"}` to
> the victim → `POST /notify` → the victim's lock screen renders it as **Mom**.

The signature check the docs tout is satisfied: the forger validly signs *as themselves*, and nobody
checks who that is.

**The VoIP variant is worse.** `apple/HavenApp/PushManager.swift:154-166` calls
`CallManager.shared.reportIncomingFromPush(name:peerHex:)` **outside** the `if let` that decrypts and
verifies. Decryption failure → `name = "Someone"` (`:155`) → **the phone rings anyway**
(`CallManager.swift:359-367` → `:382`). `/call` requires no signature (`worker.js:74-76`). And `h`
(caller hex) inside the payload is never checked against the signer (`PushManager.swift:161`), so
even a verified payload can claim to be someone else — CallKit renders the spoofed name full-screen.
The only brake is `rateLimited` (`worker.js:305-311`): 60/min keyed on source IP, on eventually
consistent KV; its own comment concedes it is "best-effort, not a hard gate".

**Impact.** Anyone with a victim's public node id can put attacker-chosen text under an
attacker-chosen contact name on their lock screen, and can ring their phone full-screen from a
killed/locked state, repeatedly. Phishing, harassment, battery drain — against exactly the trust
relationship Haven sells.

**Recommended fix.** Note iOS 13+ *requires* `reportNewIncomingCall` for every VoIP push or the
process is killed and the app loses VoIP privileges, so the ring cannot simply be dropped.

1. **Worker-side (the real fix):** authenticate `/call` and `/notify` — require the sender's
   signature and verify it. Keep the uniform `ok:true` response (`worker.js:143`) so the existence
   oracle stays closed.
2. **Device-side:** mirror known-contact hexes into the shared Keychain group (the pattern already
   exists — `SharedLockedCircles`, used at `NotificationService.swift:53`). After
   `openSignedNotificationWithSeed`, require `opened.senderHex ∈ contacts`, else fall through to the
   generic banner at `:40`. For calls: report, then immediately `provider.reportCall(with:endedAt:
   reason:.failed)` when the payload doesn't open, or `opened.senderHex != obj["h"]`, or the sender
   isn't a known contact.

---

## F4 — HIGH: device rosters and media are readable/enumerable by strangers, with no token

**The claim.** Same as F2 — "cannot be enumerated by strangers".

**What the code does.** `mailbox_forbidden` (`core/haven-net/src/blobstore.rs:698-709`) ends in
`None => false` — **permissive for every key not under `haven/mailbox/`**. Device rosters live at
`haven/devroster/<account>` (`blobstore.rs:619`), so GET and LIST of that namespace are allowed for
any peer. The crate's own test asserts the same permissive branch for media (`blobstore.rs:1322`).

The roster blob is **signed, not sealed**: `verify_devroster` (`blobstore.rs:632-665`) parses a
plaintext `HavenId` bundle and `DeviceList` straight out of the body.

**Impact.** A stranger who learns a relay's node id dials it, `LIST haven/devroster/` → every account
id the relay serves, then `GET` each → that account's full public identity bundle, complete device
list, and revoked set. A precise account roster and multi-device map of the relay's entire
population, from an unauthenticated dial with no token. The same branch lets a stranger enumerate and
download every media blob (sealed, but counts, sizes, and the full ciphertext corpus for offline
work).

**Recommended fix.** Flip to default-deny once configured: `None => true` with an explicit allowlist.
Gate devroster *reads* to authorized members (writes stay permissive — the signature is the trust,
and that part is sound). Refuse `LIST haven/devroster` for non-relays.

---

## F5 — HIGH: media refs are random UUIDs, not content addresses; nothing binds a blob to its ref

**The claim.** Asserted repeatedly in-code: "Content-addressed keys never change"
(`apple/HavenApp/SharedStore.swift:216`); "`key(ref)` is content-addressed — independent of the
sealed bytes" (`:280-282`); "keys are content-addressed, so a co-member can neither read nor forge
another member's DM — only relay it" (`core/haven-net/src/blobstore.rs:702-706`).

**What the code does.** The ref is a random UUID:

- `apple/HavenApp/Media.swift:319` — `let ref = "img_\(UUID().uuidString)"`
- `apple/HavenApp/Media.swift:339` — `let ref = "vid_\(UUID().uuidString)"`

And `seal_bytes` binds **no** context — not the ref, not the circle id, not the post id
(`core/haven-p2p/src/social.rs:208-230`: `group` is used only to enumerate recipients; the signed
transcript covers sender/ciphertext/recipients and nothing else). `seal_circle_media`
(`core/haven-ffi/src/lib.rs:2197-2208`) passes no AAD. On the open side there is no ref check
either: `open_circle_media` (`lib.rs:2242-2258`) accepts any circle member as sender, and
`open_circle_media_file` (`lib.rs:2276-2296`) loops **every known circle** until one opens.
`SharedStore.swift:616-621` does the same. The reassembled blob is never hashed against `ref`.

Compounding: the relay does not gate media keys at all (F4), and `local_put`
(`blobstore.rs:322-331`) overwrites unconditionally.

**Impact.** A relay operator — always a circle member — or any node that learns a ref can take member
X's sealed media from ref A and PUT it at ref B. Every client opens it (X is a member, signature
verifies, GCM verifies) and renders X's photo A under whatever signed post referenced ref B. This is
**silent, cryptographically undetected content substitution across posts, authors, and circles**, and
it defeats the point of signing posts: the post envelope is unforgeable, but its media payload is
freely swappable. The same primitive gives permanent media DoS (overwrite with garbage → GCM fails
forever; senders won't re-upload because `MediaBackupLedger.has(node, ref)` marks it confirmed —
`SharedStore.swift:229-233`).

**Recommended fix.** Both halves are needed:

1. Make the ref an actual content address: `ref = "img_" + hex(blake3(plaintext))`, and after every
   open verify `blake3(plaintext) == ref` before adopting/rendering (`SharedStore.swift:616-621`,
   `Media.swift:650`). This alone kills substitution and makes puts genuinely idempotent.
2. Bind context into the AEAD: give `seal_bytes` an `aad: &[u8]`, pass `circle_id || ref`, include it
   in `env.transcript()` so the signature covers it, and have `open_bytes` require the caller's
   expected AAD. Then delete the "try every circle" loop in `open_circle_media_file` — it is the
   mechanism that makes cross-circle replay work.

Both are wire-format changes: version the envelope and accept legacy unbound blobs read-only during
migration.

---

## F6 — HIGH: media is plaintext at rest; on macOS with no protection at all

**The claim.** `docs/SECURITY.md:26-27`: "the decrypted social state, **media**, and scheduled queue
use file-protection so they're unreadable on a locked/forensic device."

**What the code does.** Media is written as raw plaintext and stays that way for the life of the
install. `apple/HavenApp/Media.swift:320-323` — `img.jpegData(...)` → `try? data.write(to: url)` into
`haven-media/<ref>.jpg`; video likewise (`:337-352`). Sealing happens only on the way *out* to a
relay (`core/haven-ffi/src/lib.rs:2220` reads plaintext from `in_path`), and inbound media is
written back to plaintext (`lib.rs:2299-2306`, `Media.swift:650-653`).

Protection is iOS Data Protection at the **weakest** usable class —
`.completeUntilFirstUserAuthentication` (`Media.swift:277-283`). The `#else` branch (`:284-285`)
applies **no protection on macOS**: `createDirectory` with no attributes. Media sits in plaintext in
`~/Library/Application Support/haven-media/`, readable by any process running as the user.

Additional plaintext residue: `MediaPicker.swift:99,153`, `StoryCamera.swift:234,422`,
`DualCamera.swift:129`, `CameraView.swift:343,762`, `Audio.swift:22`, `FeedView.swift:3053,3079` all
stage plaintext in `temporaryDirectory`. `Media.swift:120-137` (`export()`) writes a trimmed
plaintext MP4 to tmp and **never deletes it** (no `defer`; contrast `SharedStore.swift:316-317`,
which correctly does).

**Impact.** The at-rest claim does not hold on macOS at all, and holds only against a
powered-off/pre-first-unlock iOS device. Forensic extraction of an AFU iPhone, any macOS
local-process compromise, or an unencrypted backup yields every photo, video, and voice note in the
clear. This is the largest gap between `docs/SECURITY.md` and the code.

**Recommended fix.** On macOS, seal `haven-media` at rest under a key derived from the master seed
(which *is* SE-wrapped), decrypting to tmpfs/`.part` only for AVPlayer and deleting on teardown. On
iOS, raise `haven-media` to `.completeUnlessOpen` (playback holds the handle open, so this works) and
route the `temporaryDirectory` staging above through `MediaStore.makeTempFile()` (`Media.swift:
643-647`), which already lands in the protected dir. Add the missing
`defer { try? FileManager.default.removeItem(at: dst) }` to `Media.swift:120`. **If you ship without
this, correct `docs/SECURITY.md:26-27`** — it currently claims a property the code does not have.

---

## F7 — HIGH (docs): SECURITY.md contradicts the shipped product and MODERATION.md

`docs/SECURITY.md:49-51` states: "There is **no content moderation or reporting** by design, and it
is not possible… there is nothing to moderate or report to."

`docs/MODERATION.md` — same repo — documents a shipped report sheet, a shipped circle-wide
`EventKind::Report`, and a shipped developer ledger, on all three platforms (`MODERATION.md:51-60`).
`SECURITY.md:3-4`'s "nothing is sent to the developer; nothing is logged" is contradicted by every
`/flag` call site listed in F1.

These cannot both be true. `SECURITY.md` is the document a security researcher reads first, and it is
wrong in the direction that inflates the guarantee. Note `appstore-metadata.md:61` is *more* accurate
than `SECURITY.md` — it carefully says there is no copy of *content* to moderate, which is true.

**Recommended fix.** Rewrite `SECURITY.md:49-51` to match `appstore-metadata.md:61`: no *content*
moderation is possible, because the developer has no content; reporting exists and is circle-scoped;
a content-free ledger entry is sent to the developer on report (and, until F1 is fixed, on block),
and link to `MODERATION.md` and `TERMS.md:38-45`. Fix `:3-4` to scope "nothing is logged" to content.

---

## F8 — HIGH (docs): RELAY-AND-DEPLOY.md promises a rendezvous-token design that does not exist

`docs/RELAY-AND-DEPLOY.md:160-164` states: *"The relay/broker sees opaque sealed frames addressed by
**ephemeral rendezvous tokens**, not Haven public keys. A node that somehow logged an IP still could
not tie it to a Haven identity."*

**This is false.** There are no rendezvous tokens in the code. `dest` ids are long-term Ed25519
identity keys (`core/haven-net/src/relay.rs:57`; `core/haven-relay/src/link.rs:13-17`), and the QUIC
session authenticates the peer under that same key (`blobstore.rs:537`, `lib.rs:672`). The relay
holds an exact, permanent identity↔IP map. `SECURITY.md:38-42` is honest about this ("Can see limited
metadata: connection timing, IP↔node-id mappings"); the two docs contradict each other, and the
optimistic one is wrong.

**Recommended fix.** Either implement the blinded routing tags the doc claims (`HMAC(epoch_key,
node_id)`, rotated per epoch — the "opaque/HMAC'd per-member key prefixes" groundwork
`SECURITY.md:42` mentions, and which `groupkey::mailbox_prefix` already provides for storage keys),
or delete the paragraph. Docs must agree.

---

## F9 — HIGH: the relay bearer token crosses the wire in cleartext; no TLS exists

`httprelay` is raw TCP (`core/haven-net/src/httprelay.rs:47,84`) — there is no TLS in the crate. The
module doc says "TLS is delegated to a fronting proxy/tunnel" (`:8-9`), but clients announce bare
`http://<lan-ip>:8674` URLs by default (`RelayHost.swift:120-124`; `HavenNet.kt:1830-1845`); the
HTTPS public URL is opt-in.

So `Authorization: Bearer <token>` (`httprelay.rs:122`) crosses the wire in cleartext on **every**
request. An on-path attacker — explicitly *not* the relay operator, so outside the trusted party —
captures it from the first request and inherits everything in F2. The token is static, persisted, and
never rotated (`config.rs:234-249`), so this is permanent. The attacker also sees every key
(`haven/mailbox/<circleUUID>/<hash>` → circle UUIDs, blob sizes, traffic volume) and can tamper with
or inject blobs (no wire integrity).

**Recommended fix.** Refuse to bind a non-loopback address without TLS. Replace the bearer token with
a signed/timestamped/nonce'd request MAC so the credential is not replayable from a capture. Rotate
on membership change. Stop announcing plain-HTTP LAN URLs as the default transport.

---

## F10 — HIGH: the connection relay is an open, unauthenticated forwarder with 32× amplification

`RelayNode::handle_inbound` (`core/haven-net/src/lib.rs:549-603`) performs **no membership check
whatsoever**. It parses any frame from any peer and forwards to up to `MAX_DEST = 32` destinations
(`relay.rs:47,93`). `cfg.link.members` is loaded but never consulted — `runner.rs:38` is a no-op
warmup hook.

`MAX_PAYLOAD` is 256 MB (`lib.rs:28`), so one frame → 32 outbound sends = **8 GB out for 256 MB in**.
Any stranger holding a relay's node id gets a free anonymous packet-injection and amplification
service aimed at arbitrary node ids. `SeenSet` is RAM-only and count-capped at 8192 (`relay.rs:153`);
an attacker pushing >8192 distinct msg_ids evicts the dedup window — the crate's own test proves an
evicted id is re-admitted (`relay.rs:189`) — defeating even honest loop-breaking.

**Recommended fix.** Require `dest ⊆ link.members` (and/or sender ∈ members) before forwarding; cap
relayed frame size far below 256 MB; per-peer rate limit; make `SeenSet` time-windowed rather than
count-capped.

---

## F11 — MEDIUM: `DeviceKeyStore` has the locked-read-overwrite bug the master seed was hardened against

**The claim.** The project's own rule (`reference_keychain_locked_overwrite`): "nil read ≠ absent (may
be LOCKED); only `errSecItemNotFound` justifies generate+save."

**What the code does.** `AccountStore` implements this **perfectly** (see VERIFIED). `DeviceKeyStore`
— the other 32-byte Account seed on the device — does not:

```swift
// apple/HavenApp/DeviceRoster.swift:40-44
private static func loadSeed() -> Data? {
    var q = query(); q[kSecReturnData as String] = true; …
    return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
}
```

The OSStatus is discarded — `errSecInteractionNotAllowed` collapses to `nil`, identical to
`errSecItemNotFound`. The caller then generates and saves over it:

```swift
// apple/HavenApp/DeviceRoster.swift:19-23
static func deviceAccount() -> Account {
    if let seed = loadSeed(), let acct = try? Account.fromSeed(seed: seed) { return acct }
    let fresh = Account.generate()
    saveSeed(fresh.secretSeed())      // ← SecItemDelete + SecItemAdd (:46-52)
    return fresh
}
```

The item is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`:49`), so a read before first unlock
returns `errSecInteractionNotAllowed` → nil → **the device key is destroyed and replaced**. An
`Account.fromSeed` throw also silently triggers regeneration — the exact case `AccountStore.swift:
35-38` explicitly refuses.

**Impact.** The device key is what the account signs to authorize this device, and it is the
per-device transport seed. Rotating it out from under the account-signed credential — which survives
in `UserDefaults` (`DeviceRoster.swift:59-62`) and now attests to a key that no longer exists —
desynchronizes the device from the signed roster. That is precisely the failure signature of two bugs
already in this project's history (`reference_haven_own_device_roster_reject`,
`reference_haven_roster_revocation_flipflop`). Ranked Medium only because reachability is narrow
(needs `deviceAccount()` pre-first-unlock; `FeedView.swift:148/637/663` are view-driven, so a
background launch after reboot is the realistic trigger).

**Recommended fix.** Mirror `AccountStore.loadSeedStatus` exactly: return the OSStatus and generate
**only** on `errSecItemNotFound`. On any other status, return nil/throw and let the caller retry
after unlock. Treat a `fromSeed` failure as "present but unreadable", never as absent.

---

## F12 — MEDIUM: a transient SE failure silently downgrades a seed copy to plaintext

**The claim.** `docs/THREAT-MODEL.md:13`: "**Every** on-device copy of the master seed is
Secure-Enclave-wrapped… The one unsealed copy is the *opt-in* iCloud-synced archive."

**What the code does.** Three write paths fall back to plaintext on *any* seal failure, not only on
no-Enclave hardware:

- `apple/Shared/SharedSeed.swift:52` — `add[kSecValueData] = box.seal(seed) ?? seed`. On `nil`, the
  raw 32-byte seed is written to the **shared** access group.
- `apple/HavenApp/AccountStore.swift:232-240` — `saveSeed`: `if wrapAndStore(data) { return }`, else
  plaintext keychain item.
- `apple/HavenApp/AccountStore.swift:420-431` — `storeHistory`: the `else` catches both "opted into
  iCloud" *and* "seal failed", so a seal failure writes a **device-local plaintext archive of up to
  12 past seeds**.

`seal` returns nil whenever `publicKey(creatingIfNeeded:)` returns nil
(`SecureEnclaveBox.swift:99-104`), which includes the **locked** case: `privateKey()` returns `(nil,
errSecInteractionNotAllowed)` and `guard creatingIfNeeded, status == errSecItemNotFound` fails
(`:63-65`). So this is not only the Simulator path the comments describe — it is any transient
Enclave unavailability.

**Impact.** Silent, permanent downgrade. Once the plaintext item lands it is never re-wrapped
(`SharedSeed` and `storeHistory` have no repair path; only `AccountStore.swift:32` re-wraps on
launch). A keychain dump then yields the live seed and every archived identity — exactly what the SE
wrapping exists to prevent, while the threat model asserts it cannot happen.

**Recommended fix.** Distinguish "no Enclave" from "Enclave unavailable right now". Add tri-state
availability probing; at each call site, if the Enclave *exists* but sealing failed, **write nothing
and retry later**. Only the genuine no-Enclave case (`errSecUnimplemented`/Simulator) may take the
plaintext path. In `storeHistory`, split the `else` into explicit `synced` and `seal-failed` branches,
the latter aborting.

---

## F13 — MEDIUM: a transient read failure destroys the identity-recovery archive

`previousIdentities()` collapses every failure to `[]` — a locked keychain read
(`AccountStore.swift:445`), a failed SE unwrap (`:452-454`, `if case .ok(...)` with no else), and a
JSON decode failure all return the empty array indistinguishably from "no archive".

`archive()` then treats `[]` as ground truth and rewrites the store from it
(`AccountStore.swift:398-405` → `storeHistory`, which unconditionally `SecItemDelete`s both keychains
first at `:413-416`). `setICloudSync` is worse: it calls `storeHistory(previousIdentities())`
directly (`:110`) — one failed read while toggling the switch wipes the archive.

**Impact.** Same nil-read-is-not-absence class as F11, applied to the recovery archive. Silent,
permanent loss of up to 12 recoverable identities — the exact data whose purpose is surviving an
identity mistake.

**Recommended fix.** Give `previousIdentities()` a status-carrying sibling (`.found([String])` /
`.notFound` / `.lockedOrError`), exactly like `loadSeedStatus`. `archive()` and `setICloudSync` must
**abort without writing** on anything but `.found`/`.notFound`. Keep the lossy variant only for
read-only UI (`roster()`, `:495`).

---

## F14 — MEDIUM: no quota, no rate limit, no content-address verification

PUT never verifies `key == hash(body)` on either path (`blobstore.rs:761-810`;
`httprelay.rs:147-160`). Any authorized peer — per F2, any token holder for *any* circle — can write
unlimited distinct 256 MB keys. `gc_sweep` sweeps only `MAILBOX_PREFIX` (`blobstore.rs:399-402`);
`haven/media/**` is **never** swept (asserted at `:1289`), so junk under `haven/media/` is permanent.
Mesh sync then replicates the flood to every sibling relay (`pull_missing_from_peer:564-597`).

`RELAY-AND-DEPLOY.md:117-125` lists precisely these as open review items ("cap peer fan-out,
rate-limit `list`/`get`, bound store size per circle"). None are implemented. For a v1 that invites
strangers to run community relays, this is a blocker for that story specifically.

**Recommended fix.** Verify content-addressed keys against `blake3(body)` on PUT (poisoning becomes
impossible rather than merely "inert" — and this composes with F5's fix); per-circle byte quota;
per-peer rate limit; a TTL for media.

---

## F15 — MEDIUM: the HVCHUNK1 manifest is unauthenticated with an unbounded chunk count

Chunks are **not** independently sealed — the whole media is sealed into one envelope, then the
*sealed bytes* are sliced (`SharedStore.swift:445-456`). This is good for integrity: reorder, swap,
drop, and truncation all break the single AES-GCM tag and fail closed (`:616-621`). **The truncation
attack does not work.**

The manifest itself, however, is unauthenticated plaintext JSON at the permission-free key
`haven/media/<ref>` (`makeManifest`, `SharedStore.swift:170-176`). `parseManifest` reads only
`chunks` and ignores the `total`/`sizes` it wrote (`:178-185`), and the download loop trusts that
count with no ceiling (`:591-601`). Identical on Android (`HavenNet.kt:2203-2211`) and desktop
(`engine.rs:2791-2799`).

**Impact.** Anyone who can PUT a media key (per F4, that is unauthenticated) can serve a manifest
declaring `chunks: 100000000`. The victim loops fetching and appending until the disk fills. Cheap
remote disk-exhaustion DoS on every platform.

**Recommended fix.** In all three `parseManifest`s, reject `chunks > MAX_CHUNKS` and `total >
MAX_MEDIA`; enforce `sizes.count == chunks` and `sizes.sum() == total`; assert each fetched part
matches `sizes[i]`. Best fix: seal `{sizes,total}` to the circle and store *that* as the manifest, so
a relay cannot author one.

---

## F16 — MEDIUM: the routing header leaks the co-recipient set

**Every plaintext field a relay operator sees** (`core/haven-net/src/relay.rs:25-32`): `magic`
`HVR1` (4B) · `ttl` u8 · `n_dest` u8 · `msg_id` [16B] · `dest` — *n*×32B Ed25519 node ids · payload
byte length. Plus, at the transport layer, the QUIC-authenticated sender node id and its IP. On the
storage path: the key `haven/mailbox/<circleUUID>/<hash>` and the blob length.

`relay.rs:19-21` claims the relay learns "never who is in which circle". **False.** `dest` is the
co-recipient list for one message — up to 32 node ids explicitly grouped. Observed over time it *is*
the circle membership graph. A storage relay gets it more directly: per-circle key prefixes plus
which node id PUTs/GETs each.

**Recommended fix.** `groupkey::mailbox_prefix` (`core/haven-p2p/src/groupkey.rs:108-115`) already
implements exactly the right primitive for storage keys — a keyed BLAKE3 MAC over `kind:circle_id`
under a per-member `circle_secret`, so the relay never sees the circle id. It is built, tested
(`groupkey.rs:364-373`), and distributed in every KeyCommit (`:42-47`) — **but the storage paths do
not appear to use it.** Finish that wiring, apply the same idea to `dest`, and correct `relay.rs:
19-21` in the meantime.

---

## F17 — MEDIUM: `quick-xml` 0.36.2 in `haven-s3` — two high advisories, attacker-reachable

`cargo audit` (run 2026-07-15, 554 crates, advisory-db fresh) reports 5 vulnerabilities + 3 warnings:

| Crate | Version | ID | Severity | Solution |
|---|---|---|---|---|
| `quick-xml` | 0.36.2 | RUSTSEC-2026-0195 (unbounded ns-decl alloc → memory-exhaustion DoS) | 7.5 high | ≥0.41.0 |
| `quick-xml` | 0.36.2 | RUSTSEC-2026-0194 (quadratic runtime on duplicate attr names) | 7.5 high | ≥0.41.0 |
| `quick-xml` | 0.39.4 | RUSTSEC-2026-0195, -0194 | 7.5 high | ≥0.41.0 |
| `crossbeam-epoch` | 0.9.18 | RUSTSEC-2026-0204 (invalid ptr deref in `fmt::Pointer`) | — | ≥0.9.20 |
| `paste` | 1.0.15 | RUSTSEC-2024-0436 | unmaintained | — |
| `anyhow` | 1.0.102 | RUSTSEC-2026-0190 (`Error::downcast_mut()` unsoundness) | unsound | — |
| `spin` | 0.10.0 | — | yanked | — |

**The one that matters** is `quick-xml@0.36.2`, a **direct dependency of `haven-s3`**
(`cargo tree -i` confirms: `quick-xml v0.36.2 └── haven-s3 └── haven_ffi`). It parses XML responses
from a **user-configured, arbitrary S3 endpoint** — i.e. attacker-controllable input in the BYO-storage
threat model (`docs/BYO-STORAGE.md`), reachable from the app process on every platform. A hostile or
compromised S3 endpoint returns crafted XML → quadratic CPU or unbounded allocation in the client.
The `0.39.4` copy is transitive under `iroh → netwatch → netdev → plist` and parses local system
plists, so it is not attacker-reachable.

**Recommended fix.** Bump `haven-s3`'s `quick-xml` to ≥0.41.0 (direct dep, yours to move); this is the
only one I would treat as security-relevant before v1. Bump `crossbeam-epoch` to ≥0.9.20 and
un-yank/replace `spin` opportunistically. `paste` (unmaintained) and `anyhow` (downcast unsoundness,
not reached by this code) are acceptable to carry with a `cargo-deny` ignore + a note.

---

## F18 — LOW-MEDIUM: DM authorization degrades to "member of any circle on this relay"

`blobstore.rs:706`: `Some(circle) if circle.starts_with("dm:") => !a.members.values().any(|m|
m.contains(peer))`. Any member of **any** circle on the relay can read, write, and prefix-enumerate
**every** DM mailbox on it. The comment acknowledges this and argues content stays sealed — true —
but DM keys are `dm:<a>-<b>`, i.e. both participants' account ids in the clear, so this hands a
complete who-DMs-whom oracle to any co-tenant. With F2 that becomes any token holder; with F4 the
account hexes resolve to identities.

**Recommended fix.** Derive DM mailbox keys as an HMAC over the participant pair under a key only the
participants hold (the `mailbox_prefix` primitive again), so the key neither names participants nor
can be probed.

---

## F19 — LOW-MEDIUM: `HAVEN_SCENE` is not DEBUG-gated and auto-opens the seed-backup sheet in release

**The claim.** `apple/HavenApp/DemoSeed.swift:21-23`: "Everything here is gated on HAVEN_DEMO so it is
impossible to trigger in a real build." `DemoEnv.isDemo` backs this up correctly (`:40-49`, a real
`#if DEBUG` / `#else return false`).

**The sibling property has no gate:**

```swift
// apple/HavenApp/DemoSeed.swift:51-52
static var scene: DemoScene? { env["HAVEN_SCENE"].flatMap(DemoScene.init) }
```

`DemoScene` includes `.identity` (`:32`), and the consumer is live in release —
`apple/HavenApp/ContentView.swift:73-78` presents `IdentityBackupView` (`:70-71`), the sheet that
renders the master-seed transfer code / QR, 0.4s after appear.

**Impact.** On macOS, `HAVEN_SCENE=identity /Applications/Haven.app/Contents/MacOS/Haven` on a
shipped, signed build auto-presents the master-seed QR with no interaction — a one-command seed-exfil
path for anyone with brief local access to an unlocked Mac, skipping the deliberate multi-tap UX
guarding that sheet. Low-Medium because it does not grant much an attacker with local exec lacks —
but it directly falsifies the file's own "impossible to trigger in a real build."

**Recommended fix.**

```swift
static var scene: DemoScene? {
    #if DEBUG
    return env["HAVEN_SCENE"].flatMap(DemoScene.init)
    #else
    return nil
    #endif
}
```

Better: make `scene` return nil unless `isDemo` is also true, so the two cannot drift apart again.

---

## F20 — LOW: the Worker observes sender-IP × recipient-identity in real time

`/notify`'s body carries the **recipient** nodeId while the request carries the **sender's** IP
(`cf-connecting-ip`, `worker.js:306`) — so the Worker *observes* the social graph in real time even
though it does not persist it. KV holds `nodeId → tokens` (`:37`), `voip:` (`:65`), `owner:` (`:47`);
rate-limit rows are IP-keyed with 60s TTL (`:309`) and **not** joined to nodeId. `wrangler.toml` has
no `[observability]` block, so Workers Logs are off by default.

Honest answer to "does it retain identity → token → IP?": **token yes, IP no** — but only by a
one-line-change margin, and account-level Logpush is invisible from this repo.
`docs/NOTIFICATIONS.md` is honest here; `SECURITY.md:3-4`'s "nothing is logged" is a **policy** claim
about a server Blaine controls, not a cryptographic guarantee.

**Recommended fix.** Set `[observability] enabled = false` explicitly in `wrangler.toml`. State in
`SECURITY.md` that no Logpush is configured and that this is operator policy, not cryptography.

---

## F21 — LOW: `api.github.com` fetch fires on every page load, including post-link opens

**The claim.** `docs/SECURITY.md:69-70`: "No analytics, telemetry, crash reporters, or ad SDKs —
**verified by audit**." True for the app, and *almost* true for the site.

`web/index.html:659` does an unconditional top-level `fetch("https://api.github.com/repos/…/releases/
latest")` on **every** page load — including when opened via `#p/<circle>.<post>`.

**Impact.** GitHub/Microsoft receives reader IP + timestamp + `Referer: https://wemiller.com/` for
every Haven link opened in a browser. It does **not** learn which post (fragments are stripped from
`Referer` per spec, regardless of policy). Still an undisclosed third-party readership-timing signal,
and avoidable.

**Recommended fix.** Bake release asset URLs at deploy time (the `notify-portfolio` workflow already
exists), gate the fetch behind a click on the download section, or at minimum skip it entirely when
`location.hash` is non-empty. Also add `<meta name="referrer" content="no-referrer">` and a CSP
(`connect-src 'self' api.github.com`) — defense-in-depth that makes a malicious-JS exfil conspicuous.

---

## F22 — LOW: demo seeding drives the real store on Apple/Android

Desktop does this correctly and deliberately — its own seed **and** its own data dir
(`desktop/src-tauri/src/demo.rs:52-62`, `lib.rs:188-195`), with the rationale written out at
`demo.rs:20-22`. Apple and Android do not: `DemoSeeder.seed(feed:)` uses `feed.demoEngine`
(`DemoSeed.swift:86`) — the real engine — and mutates `ProfileStore.shared` (`:89-93`); Android uses
`HavenNet.engine` (`DemoSeed.kt:82`), `ProfileStore.get(context)` + `me.save()` (`:86-92`), and
`LocalMedia.storeUnderRef` — all real stores. Persistence is partly defended (`Profile.swift:13-19`
skips `defaults.set` when `isDemo`; `FeedView.swift:211` guards `demoPersist`) — but Android's
`HavenNet.demoPersist()` has no such guard and writes seeded state to disk.

Release builds are safe (the `#if DEBUG` / `BuildConfig.DEBUG` gates hold). Exposure is a developer
running a debug build on a device holding real data. **Recommended fix.** Port desktop's rule to both:
own seed, own data dir/prefs namespace. Minimum on Android: guard `demoPersist()` on
`BuildConfig.DEBUG && DemoEnv.isDemo`.

**Related (INFO).** `android/app/build.gradle.kts:47-48` sets `isMinifyEnabled = false` for release,
so `DemoSeeder`/`DemoEnv` ship in the release APK as unreachable code (`BuildConfig.DEBUG` is a
`static final false`). Same on Apple. Only desktop achieves true absence
(`#[cfg(debug_assertions)] mod demo;` + a `compile_error!` tripwire at `demo.rs:22`). Not exploitable
— reaching the seeder requires already having code execution — but a weaker guarantee than desktop's,
and F19 shows what happens when a gate is assumed rather than enforced. Moving `DemoSeed.kt` to
`src/debug/java/` would give physical absence.

---

## Claims VERIFIED TRUE

These are as valuable as the holes. Each was attacked, not merely read.

### Cryptography

- **The hybrid is a real hybrid.** `combine` (`core/haven-p2p/src/crypto.rs:106-119`) builds
  `ikm = dh ‖ pq` and runs it through one HKDF-SHA256 extract+expand. Breaking one half leaves the
  other's 32 bytes of entropy in the IKM — you cannot learn the output without both. Both halves are
  fixed-length (32 ‖ 32), so the concatenation is unambiguous and not vulnerable to a
  canonicalization split. This is the correct construction; it matches PQXDH/PQ3 as the comment
  claims.
- **The KEM transcript really is bound.** `kem_transcript` (`crypto.rs:123-130`) folds ephemeral
  X25519 pub ‖ ML-KEM ciphertext ‖ recipient X25519 pub ‖ recipient ML-KEM pub into the HKDF `info`
  (`:112-114`), giving implicit key confirmation and blocking unknown-key-share / ciphertext
  substitution. The `haven-hybrid-kem-v2` salt (`:111`) is a clean break from the unbound v1.
  `SECURITY.md:16`'s "The KEM derivation binds the full transcript" is accurate.
- **The deterministic-nonce seal is sound, and the danger is correctly fenced.** `seal_reproducible`
  (`crypto.rs:157-170`) derives the nonce as a PRF of the key — catastrophic if a key ever repeated
  across distinct plaintexts. It cannot: the event key derives from a salt that is itself a keyed
  BLAKE3 PRF over the plaintext (`groupkey.rs:186-194`), so any plaintext change → different salt →
  different key → different nonce. `groupkey.rs:285-304` tests exactly this. The tradeoff (an
  observer can tell whether two same-epoch envelopes seal identical plaintext) is real, correctly
  documented at `GROUP-KEYING.md:48-51`, and is the property the mailbox dedup depends on.
- **The epoch key is never used directly as an AES key** — only as HKDF keying material
  (`derive_event_key`, `groupkey.rs:120-129`), so one epoch key safely seals unbounded events.
- **Removal fencing is cryptographic, and I could not find a decrypt window.** `seal_key_commit`
  (`groupkey.rs:68-85`) seals to exactly the new member set; a removed node is absent, never receives
  the key, and cannot derive any `event_key` for that epoch or later. Proven end-to-end by
  `key_commit_revokes_removed_member` (`groupkey.rs:307-343`), which asserts both that Carol cannot
  open the epoch-1 commit and that she cannot open an epoch-1 post with her stale e0.
- **`GROUP-KEYING.md` is now accurate about rotation.** The doc's corrected text (`:78-82` — rotates
  on removal/block, on device-roster change, and periodically; **not** on add) matches the code.
  Worth noting the doc explicitly explains *why* add needn't rotate, which is the right reasoning.
- **The `allow_forwarded` author/sender bypass is correctly gated.** `open_event_in_epoch`
  (`groupkey.rs:211-230`) skips the author/sender bind only when the caller passes
  `allow_forwarded` — and the single production call site passes `sender_hex == me_hex`
  (`core/haven-ffi/src/lib.rs:1273`), i.e. only for my own account's self-forwards. Only my own
  account can produce a `sender=me` envelope, so a member cannot use this to re-attribute someone
  else's event. I checked every call site; there is no other.
- **Tamper/forgery rejected** — `groupkey.rs:346-361`.
- **No crypto backdoors in core.** No `env::var`/`getenv` outside `#[cfg(test)]` in `haven-p2p`,
  `haven-ffi`, `haven-net`; no `#[cfg(test)]` leakage into release paths; no hardcoded keys, no
  skip-verify flags, no crypto-weakening env overrides.

### Relay

- **The relay cannot read content.** Bodies are read and written verbatim on both paths
  (`blobstore.rs:778-788,820-827`; `httprelay.rs:133-156`). No decryption path exists in the relay; it
  holds no content key. The only body inspection anywhere is the signature-verified devroster branch
  (`blobstore.rs:798-802`). **The core claim holds.**
- **Path traversal is properly closed.** `safe_path` (`blobstore.rs:237-263`) rejects
  empty/oversize/NUL/absolute and `.`/`..` per component, then re-asserts `starts_with(root)`. HTTP
  percent-decodes *before* validating (`route` → `decode` → `checked`, `httprelay.rs:214-241`), so
  `%2e%2e` is caught (tests at `:346,:355`). Attacked; could not break it.
- **`self/` self-sync slots are correctly owner-gated.** On iroh, the account in the key is compared
  to the QUIC-verified `conn.remote_id()` before any other gate (`blobstore.rs:742-749`); on HTTP they
  are refused outright (test at `httprelay.rs:407`).
- **Device-roster injection is impossible.** `verify_devroster` (`blobstore.rs:632-665`) binds the
  carried bundle to the key and requires a valid hybrid account signature, excluding revoked devices.
  A stranger cannot inject device ids for another account. (Its *confidentiality* is F4; its
  *integrity* is sound.) **Nobody can add a device to your account.**
- **A member cannot TOUCH-expire another member's envelopes, and cannot delete anything.**
  `local_touch` (`blobstore.rs:367-377`) only calls `touch_now` (`:191-196`), which moves mtime
  forward. There is no delete verb. Deletion is exclusively the relay's local TTL policy
  (`gc_sweep:387-403`). A member can only keep entries alive — exactly as `RELAY-AND-DEPLOY.md:113-115`
  claims.
- **TOUCH prefix confinement is correct** — both paths force a trailing `/` before `starts_with`
  (`blobstore.rs:856`; `httprelay.rs:184`), so `fam` cannot match `famX`.
- **Mesh sync will not resurrect GC'd entries** (`blobstore.rs:172-188,200-206`, tested `:1205-1235`).
- **A malicious relay cannot forge or read.** Payloads are signed `SealedEnvelope`s; the relay has no
  key. It **can** silently drop, delay, and reorder (`lib.rs:601` is best-effort, no acks) —
  unavoidable for store-and-forward, mitigated by multi-relay fan-out.

### Push / notifications

- **The Worker is blind on content.** Unsealed envelope = `{nodeId (recipient), ciphertext (opaque
  b64), event (opaque b64), silent}` + APNs headers. **No sender-supplied title/body ever.** The
  fallback alert is a hardcoded constant — `{title:"Haven", body:"New activity"}` (`worker.js:191`)
  and `"Incoming call"` (`:120`) — so the NSE-fails-to-decrypt case leaks nothing, and the NSE never
  guesses (`NotificationService.swift:40`).
- **Push registration is signed and verified — impersonation is closed.** `PushManager.swift:123-128`
  signs; `worker.js:272-286` verifies Ed25519 over `haven-push-register-v1:<nodeId>:<token>:<ts>` with
  a 5-minute window. `nodeId` **is** the pubkey, so it is self-authenticating. **You cannot register a
  device token under someone else's identity.** Half of `SECURITY.md:23-24` is fully sound (the
  registration half; the notification half is F3).
- **Notification signing binds the recipient** (`core/haven-ffi/src/lib.rs:317-323`: domain tag ‖
  recipient hex ‖ plaintext) — cross-user replay prevented.
- **No existence oracle** — `/notify` and `/call` return uniform `ok:true` for unknown nodes
  (`worker.js:143,177`).

### Link system — the strongest part of the codebase

- **The fragment never reaches the server.** `web/index.html:515` reads `location.hash`, parses it
  locally (`:514-533`), and navigates via `window.location.href = "haven://…"` (`:545`) — a custom
  scheme, no round-trip. **Nothing** puts the hash into a fetch, query param, path, beacon, `Image`,
  `replaceState`/`pushState`, or redirect. `hashchange` re-renders locally (`:579`). Verified by
  reading every hash consumer.
- **Zero third-party subresources.** Every origin in `web/` is `github.com` / `apps.apple.com` /
  `play.google.com` as user-clicked links, plus the one `api.github.com` fetch (F21). No fonts, no
  CDN, no scripts, no analytics.
- **The post link carries no key.** `DeepLink.swift:33-37` emits `#p/<circleId>.<postId>` — two
  opaque ids, percent-encoded with `.`/`/` excluded. Identical on Android (`DeepLink.kt:44`) and
  desktop (`desktop/ui/app.js:365`). A pointer, not a capability — as documented.
- **The relay link carries no key material** (`core/haven-relay/src/link.rs:1-30` — circle tag +
  already-public node ids).

### Seed at rest

- **The `.seError` / locked-read discipline on the master seed is correct, and notably well done.**
  `SeedStatus` distinguishes four states (`AccountStore.swift:255`); `.missingKey`, `.failed`, and a
  wrong-size decrypt all map to `.seError` (`:262-272`); `.lockedOrError` and `.seError` both take the
  throwaway-identity path with an explicit "Do NOT save" (`:46-54`). **`.notFound` is the only branch
  that generates+saves** (`:39-45`). I traced every `Account.generate()` in the file (`:37,41,53,72,
  581`) — each is either non-persisting or a deliberate user-initiated reset. A seed present but
  underivable refuses to overwrite (`:35-38`). `loadWrappedBlob` applies the same discipline one layer
  down (`:332-364`). `SecureEnclaveBox.publicKey` refuses to mint a second Enclave key on a locked
  read (`:63-65`) — the subtle case that would orphan existing ciphertext. **The bug class that has
  bitten this project before is correctly defended here.** (F11/F13 are the *other* stores, which did
  not inherit the discipline.)
- **The three named master-seed copies are SE-wrapped** — active (`AccountStore.swift:369-377`), NSE
  shared mirror (`SharedSeed.swift:52`), device-local archive (`AccountStore.swift:420-424`) — modulo
  F12's fallback.
- **The iCloud archive is opt-in and is the only *intentionally* unsealed copy.**
  `iCloudSyncEnabled` defaults to `false` (`AccountStore.swift:87`); the synchronizable branch
  requires `synced == true` (`:425-430`). The rationale at `:392-397` is accurate — an Enclave key
  cannot sync, so cross-device recovery needs the bytes.
- **The seed is never synchronizable.** Every `saveSeed`/`wrapAndStore` sets
  `kSecAttrSynchronizable: false` (`:239,374`). (Note: the `synced:` parameter on `saveSeed` (`:232`)
  is **dead** — accepted and never read. Correct behavior via a misleading signature; worth deleting.)
- **No plaintext master seed in UserDefaults, files, or logs** anywhere in `apple/HavenApp`.
- **Desktop seed lives in the OS keyring** and `load_seed` correctly distinguishes `NoEntry` from a
  transient error (`desktop/src-tauri/src/store.rs:559-574`); callers propagate rather than mint
  (`lib.rs:42-50,62-70`). **Free of the F11/F13 bug class.**
- **Android seed lives in `EncryptedSharedPreferences` under a Keystore `AES256_GCM` master key**
  (`HavenCore.kt:84-95`); `loadOrCreate` generates only on a genuine null (`:62-71`).

### Media

- **Chunked media is tamper-evident.** Reorder, swap, drop, and truncation all break the single
  AES-GCM tag and fail closed (`SharedStore.swift:616-621`). **The truncation attack does not work.**
  (F15 is a separate, lesser manifest issue.)
- **The AEAD ratio-threshold trap is absent** — there is no naive ratio check to misfire. Swept
  `apple/HavenApp`, `android/app/src`, `desktop/src-tauri/src`, `core/haven-p2p*` for
  ratio/plausibility/size-sanity heuristics; found none. The only size logic is `sealedSize >
  mediaChunkBytes` (`SharedStore.swift:325`), an exact byte comparison against a fixed 8 MB constant —
  correct, and immune to the fixed-AEAD-overhead problem. **Media validity is decided by GCM
  authentication, not by size — the right call.**

### Demo

- **`DemoEnv.isDemo` is a true compile-time gate** (`DemoSeed.swift:40-49`).
- **`core/demo/src/main.rs` is dev-only** — a standalone `haven-demo` binary that mints throwaway
  identities and disables relays; ships nowhere.
- **Desktop demo gating is exemplary** and should be the model: `#[cfg(debug_assertions)] mod demo;`
  (`lib.rs:7-9`), a `compile_error!` tripwire (`demo.rs:22`), `#[cfg(debug_assertions)]` at every call
  site, a release `no_net()` hard-returning `false` (`lib.rs:181-184`), isolated seed + data dir, and
  demo implies no-net so the synthetic cast can never reach the wire (`demo.rs:47-50`).

---

## The mandate question, answered directly

> Is there any path by which Blaine (or a relay operator, or the website host) can read content,
> impersonate a user, or become a chokepoint?

**Read content: no.** Not through the relay (it holds no key; `blobstore.rs` never decrypts), not
through the Worker (payloads are sealed; `worker.js` forwards opaque b64), not through the website
(the fragment carries two opaque ids, no key material — verified at `DeepLink.swift:33-37`). Even a
*malicious* website serving hostile JS gets `p/<circleId>.<postId>` + reader IP — a readership map,
not a post. Decryption requires the circle epoch key, which exists only on member devices.

**Impersonate a user: no, cryptographically** — but **yes, perceptually**, via F3. Nobody can forge a
signature, register a token under another identity (`worker.js:272-286` verified), or inject a device
into someone's roster (`blobstore.rs:632-665` verified). But because the NSE never checks *who* validly
signed, a stranger can put "Mom" on a victim's lock screen. That is an authorization gap, not an
authenticity break — and it is fixable in a few lines on both sides.

**Become a chokepoint: yes, once — and it is shipped.** The moderation ledger (F1). Not a
hypothetical malicious-operator scenario: it is live code writing a permanent, forgeable
identity-vs-identity graph into Blaine's KV on every block, with service-denial and
law-enforcement-disclosure consequences written into the Terms. It holds no content and no keys, so
the *content* mandate survives — but "the maker must not be a bypass target" does not survive an
unauthenticated endpoint that can get someone's push service cut off and plant a record about them.

The website-operator and Worker-operator trust class is the *correct* bar: metadata at worst, never
content. F1 is the one place the project fell below its own bar.

---

## What I did NOT cover, and why

- **No runtime verification of most findings.** This was primarily a static audit. The one exception
  is F2, proven with a live probe against `httprelay::serve` (transcript in the finding). **F5's
  substitution attack and F19's `HAVEN_SCENE=identity` are code-path arguments and should be
  confirmed empirically before being treated as settled** — F19 is a 30-second test on a release
  macOS build.
- **WebRTC / calls (DTLS-SRTP) beyond the push doorbell.** Media-path encryption, SDP handling, and
  the frame-9 relay-forwarded signaling were not audited. **Flagged:** the relay-forward path noted
  that non-idempotent frame types (call signaling) would be **replayable by a malicious relay**, since
  `msg_id` dedup is an honest-relay loop-breaker only (see below). Worth a dedicated look.
- **`msg_id` is not replay protection and should not be described as such.** It is sender-chosen
  random (`relay.rs:63-68`) and a relay builds its own outbound frames (`lib.rs:593-598`) — it can
  re-emit the same payload under fresh msg_ids indefinitely. What actually neutralizes replay is
  application-layer idempotence: event ids are `BLAKE3(author‖created_at‖kind)` and the reducer dedups
  by id (`core/haven-p2p/src/social.rs:82,371-373`), and mailbox keys are content hashes so a re-PUT is
  a no-op. Fine for events; **unexamined for call signaling.**
- **iOS Data Protection classes on the engine state file and the scheduled queue.** I verified only
  the `haven-media` directory (`Media.swift:277-285`). Given F6 found the media half of
  `SECURITY.md:26-27` false on macOS, the other two stores in that sentence deserve the same check.
- **Watch (`apple/HavenWatch`) and `core/haven-wasm`** — not examined for seed storage. `haven-wasm`
  in particular deserves attention: the transfer-code flow (`AccountStore.swift:123-131`) advertises
  moving the seed to a web client, and a browser has no Enclave equivalent.
- **`apple/Haven N.xcodeproj`** (32 numbered duplicates) — treated as project-file noise. Worth
  confirming none is a live target with different `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, since every
  Apple demo gate rests on `#if DEBUG` resolving correctly for the shipped target.
- **The iroh/n0 dependency itself**, `SelfSync` reducer semantics, scheduled messages, Apple Music
  integration, and the S3 tunnel (`s3tunnel.rs`) beyond the `quick-xml` reachability question.
- **No formal cryptanalysis.** I verified construction and composition (the hybrid is a real hybrid,
  the transcript binds, nonces cannot repeat), not the primitives themselves — those are standard
  library implementations of published algorithms, which is exactly what you want.
- **Supply chain beyond `cargo audit`.** No review of npm (`web/`, Worker), Gradle, or SwiftPM
  dependency trees; no lockfile provenance or typosquat check.

---

## Recommended ship gate

**Fix before v1:**

1. **F1** — sign `/flag`; stop auto-logging blocks. *(Mandate. Also the cheapest fix here.)*
2. **F2 + F9** — the default media transport is an unauthenticated-by-circle, cleartext,
   statically-tokened HTTP service on `0.0.0.0:8674` that undoes the authorization done properly on
   the iroh path.
3. **F3** — one known-contact check in the NSE + signature on `/call`.
4. **F4 + F10** — each independently falsifies "cannot be enumerated by strangers" with no token.
5. **F5** — silent media substitution is the most surprising break in the report; a member-operated
   relay is inside every gate you have.
6. **F7 + F8** — the docs must stop claiming things the code does not do. This is the cheapest
   category and the most damaging if a researcher finds it first.
7. **F6** — fix, or amend `SECURITY.md:26-27` to tell the truth about macOS.

**Acceptable to ship with, tracked:** F11–F22.

**Honest confidence.** *High* on the crypto core, the link system, and the seed discipline — small,
well-factored, thoroughly tested code that I read completely and attacked. *High* on F1, F2, F7, F8
(F2 is empirically proven; the rest are direct doc-vs-code contradictions). *Medium-high* on F3, F4,
F5 — traced carefully but not executed. *Medium* on the Apple/Android platform layers, which are
large and where I sampled rather than swept. *Low* on the areas listed as not covered — particularly
WebRTC call signaling and `haven-wasm`, which are real gaps in this audit rather than clean bills of
health.

**The one-line summary:** the cryptography is genuinely good and the mandate holds on content; the
gap is everywhere the code left the crypto — the default HTTP transport, the unauthenticated
endpoints, and a ledger that quietly made the maker into the thing he promised not to be.

---
---

# Verification round 2 — 2026-07-15

A second auditor, who wrote none of the round-1 fixes, was asked to (a) **independently verify** every
claimed fix rather than trust the commits, and (b) audit what round 1 explicitly skipped — WebRTC call
signaling, `haven-wasm`, and the large new attack surface (signed HTTP auth, content-addressed media,
live device-to-device delivery, the signed `/flag`) that landed in ~20 commits under deadline.

Method held to round 1's bar: **prove things.** Two executable attacks and one live-Worker forgery
suite are the load-bearing evidence; the rest is code traced end-to-end. Where a fix could not be
made to fail, it is marked RESOLVED **with the evidence that would have caught it if it were broken**.

## Round-1 verdicts (this round's re-verification)

| # | Round-1 severity | Verdict now | How it was verified |
|---|---|---|---|
| F1 | Critical | **RESOLVED** (documented residual) | Live `wrangler dev` + a 7-case forgery suite; KV dumped |
| F2 | Critical | **RESOLVED** | The round-1 probe, now green: non-member 401/403, member 200 |
| F3 | High | *out of round-2 scope for the push path;* call path = **new R1** | NSE known-contact check present; call signaling separately broken |
| F4 | High | **RESOLVED** (reads + devroster writes; see R6) | Round-2 probe now green: stranger's roster PUT refused, signed enrollment 200 |
| F5 | High | **RESOLVED** (real residuals) | `media_substitution` test green; legacy path traced on 3 platforms |
| F7 | High (docs) | **RESOLVED** | Reporting section honest; the follow-on false claims (R2/R4/R5) are now all resolved |
| F8 | High (docs) | **RESOLVED** | "rendezvous tokens" gone; signed-auth doc text matches code |
| F9 | High | **PARTIAL — as intended** | No TLS on non-loopback binds; confirmed still the honest state |
| F10 | High | **RESOLVED** | Same signed-auth + `blob_forbidden` default-deny gate |
| F11 | Medium | **RESOLVED** | `loadSeedStatus` 3-way enum; only `.notFound` writes |
| F17 | Medium | **RESOLVED** | `haven-s3` on `quick-xml 0.41.0`; residual is transitive `plist` |
| — | Video GPS (non-audit) | **RESOLVED** | exiftool proof on all 6 export paths + JPEG + Android remux |
| — | Epoch rotation (non-audit) | **RESOLVED** (additive) | `rotate_if_stale` 7d, sync-bundle driven, backward-clock guarded |
| — | Revocation (non-audit) | **code honest; docs/UI NOT → R2,R3** | `recipients_with_devices` always seals to the account key |

## New round-2 findings

| # | Finding | Severity | Blocks v1? |
|---|---|---|---|
| R1 | WebRTC call signaling is unauthenticated **and** unsealed → spoofed call control + SDP/DTLS-SRTP MITM | **High** | ~~Yes~~ **RESOLVED** |
| R2 | `SECURITY.md` still calls device-roster-change revocation "cryptographic, not advisory" — false | **High** (docs) | ~~Yes~~ **RESOLVED** |
| R3 | Android + desktop still tell a user a revoked device "will no longer receive anything posted afterward" | **Med-High** (UI) | ~~Yes~~ **RESOLVED** |
| R4 | `TERMS.md` says the developer "cannot tell who reported whom"; the actor **is** transmitted | **Medium** (docs) | ~~Yes~~ **RESOLVED** |
| R5 | `appstore-metadata.md` says reporting "is not technically possible"; the `/flag` ledger ships | **Medium** (docs) | ~~Yes~~ **RESOLVED** |
| R6 | Non-member can destroy/fabricate any account's device roster over plain HTTP (proven) | **Med** | ~~Recommended~~ **RESOLVED** |
| R7 | `haven-wasm` is dead code but exports `seed_hex()` and advises `localStorage` — delete the crate | **Info** | ~~No~~ **RESOLVED** |

---

## F1 — RESOLVED, with a residual the docs now own

**Verified by executing it.** Ran the current `push/worker.js` under `wrangler dev --local` and pointed
a 7-case forgery suite (self-generated Ed25519 keys, real Ed25519 signatures) at `POST /flag`:

```
200  A1 legit signed report                          [expect 200]  ✓
401  B1 unsigned flag                                [expect 401]  ✓
401  B2 garbage sig                                  [expect 401]  ✓
401  B3 re-aim captured sig at new subject           [expect 401]  ✓   (subject bound)
401  B4 re-aim captured sig, new category            [expect 401]  ✓   (category bound)
401  B5 claim actor=alice, sig by mallory            [expect 401]  ✓   (actor bound)
400  B6 signed action=block                          [expect 400]  ✓   (block unrepresentable)
401  B7 signed, 1h-stale ts                          [expect 401]  ✓   (5-min window)
400  C1 replay flag sig as /register                 [expect 400]  ✓   (hexToken keeps the spaces disjoint)
```

Then dumped the KV the Worker actually wrote: rows are `{subject, action, reason}` — **no `actor`,
not even hashed** (confirmed by reading a row back); every row carries `expirationTtl` 90d; and five
identical replays collapsed to **one** row (the key is `ts + sigTag(sig)`, so a captured flag is a
no-op re-write). Each of the four round-1 fix items — signed, subject+action+category bound,
replay-idempotent, no actor, 90d TTL, `block` rejected — **holds under attack.** Blocks never leave
the device: `apple/HavenApp/ReportUI.swift` and `android/.../Moderation.kt` send only on `report`, and
`blockConnection` (`FeedView.swift:539`) is local-only.

**Residual (now an accepted, documented property, not a hole).** The sybil floor is exactly what the
Terms already disclose. My suite planted **25/25** rows against one victim from 25 throwaway keys, and
**10/10** from a single identity by walking `ts` inside the 5-minute window. But `docs/TERMS.md:64-68`
and `docs/MODERATION.md:64-68` now state this plainly ("a determined attacker can still sign N reports
from N throwaway keys… a row means *a holder of a valid Haven identity reported this identity*, **not**
N distinct people"), and **nothing in the Worker reads the ledger to auto-enforce** (grep: the only
`ledger:` references are the write and its key). Signing raised the floor from "anyone with curl" to
"each row costs a real key", which is all the Terms lean on. Acceptable.

**Nit (not a finding):** a non-numeric `ts` makes `verify_header`'s window `NaN > 300 → false`, so it
reaches `new Date(NaN).toISOString()` and throws → **HTTP 500**, not an accepted flag. Harmless (no row
lands), but the input should be rejected as `400` before the date math.

---

## F2 / F4 / F9 / F10 — RESOLVED (F9 partial, as intended), verified by the round-1 probe going green

The round-1 probe (`core/haven-net/tests/http_relay_probe.rs`) is now a committed regression test, and
it **passes** against the fixed relay. Its three passes are the exact F2/F4 attack, re-run:

```
[1] non-member, only the shared token:      GET /l/haven … PUT … → 401  (all four)
[2] non-member, correctly signed + token:   GET /l/haven … PUT … → 403  (all four)   ← the authz case
[3] secretclub's OWN member:                GET/PUT/list/get     → 200            ← still works
```

Pass [2] is the one that matters: a caller with a **valid identity and a valid signature** who is a
member of no circle is refused `403` on enumerate, read, and write. I read the mechanism and it is
sound: `verify_header` (`httprelay.rs:147`) binds `REQUEST_DOMAIN‖token‖method‖key‖ts‖nonce‖
blake3(body)`, recomputes the body digest server-side and **enforces** it (`:308`, `400` on mismatch),
burns the nonce (`:181`, replay → `None`), and bounds the timestamp in **both** directions (`:166`).
`blob_forbidden` (`blobstore.rs`) now ends in `true` — **default-deny** for any unrecognized key under
`haven/` — the inversion round 1 asked for. The signed header reaches all three clients through the
`http_auth_header` FFI (`haven-ffi/src/lib.rs:410`; `SharedStore.swift:510`, `HavenNet.kt:2422`,
`engine.rs`), signing with the **device** key.

**F9 remains PARTIAL, and that is the honest state.** `httprelay` is still raw TCP (module doc:
"TLS is delegated to a fronting proxy/tunnel"), and clients still announce bare `http://<lan-ip>:8674`
by default. The signed-request MAC means a captured `Authorization` header **cannot be replayed** (the
nonce is burned and the ts window is 5 min), which closes the worst of round-1 F9 — but an on-path
attacker still reads every key and blob in cleartext on a non-loopback bind. Round 1 flagged F9 as
"partial (no TLS)"; it is still partial for the same reason. Not newly broken; not newly fixed.

---

## F4 reopened for devroster **writes** → R6 (proven): a non-member can destroy any device roster over HTTP

Round-1 F4 was about **reads**, and reads are now denied (pass [2] above). But `blob_forbidden`
un-gates **`VERB_PUT` on `haven/devroster/**` before the membership check** (`blobstore.rs`), on the
stated grounds that the blob is self-authenticating via `verify_devroster`. That is true on the **iroh**
path (`blobstore.rs:696,841` call `verify_devroster`) and **false on the HTTP path** — `httprelay.rs`
never calls `verify_devroster`; its PUT branch calls `local_put` directly (`:326`), which renames over
the target unconditionally.

**Proven with an executable probe** (temporary, not committed):

```
=== ROUND-2 PROBE: non-member devroster PUT over plain HTTP ===
attacker: a self-generated Ed25519 key, member of no circle, holding the token
  [control] PUT /k/haven/mailbox/secretclub/injected -> 403   (mailbox write correctly refused)
  [ATTACK ] PUT /k/haven/devroster/deadbeef           -> 200
  roster on disk after: "POISONED-NOT-A-SIGNED-ROSTER"
  [ATTACK ] PUT /k/haven/devroster/00000…000           -> 200   (fabricate a roster for an unknown account)
  >>> PROBE SUCCEEDED: a non-member destroyed a stranger's device roster.
  >>> The real account-signed roster is GONE (local_put renames over it).
```

**Impact — bounded, but real.** A signed non-member (any self-minted key; the `Authorization` gate is
passed, the *membership* gate is skipped for this verb) overwrites a victim's real account-signed
device roster on a given relay with garbage. Clients verify the account signature on **read**
(`handleDeviceRosterAnnounce`), so the garbage is rejected there — but the *real* roster on that relay
is gone, so the victim's device-id dialing/auth degrades for anyone fetching from that relay until it
re-syncs from a sibling or the owner re-publishes. This is a device-roster **availability DoS**, not an
integrity break (fabricated rosters fail signature verification downstream). Mitigated by multi-relay
fan-out; worsened by mesh anti-entropy potentially propagating the clobber.

**Recommended fix.** On the HTTP PUT path, when `key.starts_with("haven/devroster/")`, call
`verify_devroster(account_from_key, &body)` and refuse (`400`) if it fails — exactly what the iroh path
does at `blobstore.rs:696`. Do not rely on `blob_forbidden` un-gating a verb whose safety lives in a
verifier the HTTP path never invokes.

### RESOLVED — the write is now verified on BOTH transports, with rollback defense

A new write gate, `blobstore::verify_devroster_put(root, account, body)`, is the write-side twin of
the read gate and fails closed the same way: it parses + hybrid-verifies the account-signed DeviceList
in the body (via the existing `verify_devroster` machinery, now returning the `version` too) and
returns `None` — REFUSE — for any unsigned, malformed, or wrong-account body. It also reads the roster
already on disk and refuses a validly-signed but **strictly older** version, so a replayed stale roster
can only lose (the roster flip-flop rollback rule from `DeviceList::adopt_if_newer`).

The HTTP PUT path (`httprelay.rs`) now routes every `haven/devroster/<acct>` write through this gate
before `local_put`, and — matching the iroh path — expands the account's membership from the verified
device ids. The iroh path (`blobstore.rs handle_request`) had the *same* latent clobber (it renamed the
blob over the target *before* verifying, verifying only to gate membership expansion); it now verifies
**before** the rename too, so neither transport is a weaker boundary than the other.

The round-2 probe is committed as a permanent regression test
(`core/haven-net/tests/http_relay_probe.rs::devroster_write_requires_a_valid_account_signature`).
Before/after:

```
BEFORE:  PUT /k/haven/devroster/deadbeef  → 200   (garbage renamed over a stranger's real roster)

AFTER (probe output):
  [ATTACK ] PUT /k/haven/devroster/deadbeef            -> 403   victim roster on disk: UNCHANGED
  [ATTACK ] PUT /k/haven/devroster/0000…0000           -> 403   (fabricated roster not stored)
  [LEGIT  ] PUT /k/haven/devroster/<acct> (v2, signed) -> 200   (enrollment still works)
  [ROLLBACK] PUT /k/haven/devroster/<acct> (v1, stale) -> 403   (v2 survives the replay)
  [LEGIT  ] PUT /k/haven/devroster/<acct> (v3, signed) -> 200   (roster genuinely advances)
```

The round-1 read probe (`audit_probe_is_refused_and_members_still_served`) stays green — the F2 read
gate did not regress. `cargo test -p haven-net` passes; `cargo check --workspace` clean.

---

## F5 — RESOLVED, with residuals the fix undersells

`core/haven-p2p/tests/media_substitution.rs` passes (6/6), and it is **not** vacuous: it runs real
`seal_bytes`/`open_bytes` with a genuine roster member as the attacker, a one-line swap that forges
nothing, and a negative control that proves the swap **lands** on the check-free path. Refs are
`kind_hex(sha256(plaintext))` on all platforms (`mediaref.rs:121`, `Media.swift:357`, `LocalMedia.kt:66`;
cross-platform digest pinned at `mediaref.rs:204`). Verification **fails closed** everywhere (Apple
`store`/`adopt` refuse; Android/desktop `checked`/`load` return null/None).

**The legacy path is NOT a downgrade vector** — for a reason worth stating precisely. The predicate is
the dangerous shape ("looks like a content address? if not, skip verification", `mediaref.rs:136`,
`Media.swift:393`, `LocalMedia.kt:390`), **but the attacker does not control the ref**: it lives inside
`EventKind::Post`, which is inside the sealed ciphertext, and the signature covers the transcript
binding that ciphertext (`social.rs:201`, verified `:234/:260`). Swapping a victim's `img_<sha256>` for
an `img_<uuid>` requires the victim's signing key. Confirmed no unsigned ref source exists.

**Residuals (accept knowingly):**
- **Legacy `img_<uuid>` posts are permanently unprotected** — freely substitutable by a relay operator,
  forever, with no expiry, re-mint migration, or user-visible "unverified" signal. The set shrinks only
  by attrition.
- **A malicious author can self-downgrade**: nothing forces minting, so an author can hand-craft an
  `img_<uuid>` in their *own* signed post and then equivocate (serve different bytes to different
  viewers, or mutate later) undetectably. Lower severity — they can post anything anyway — but the
  equivocation property is a real loss, and clients cannot distinguish a new legacy-shaped ref from a
  grandfathered one (no epoch/version field to gate on).
- **Apple verifies at store/adopt only, not at at-rest read** (`item()`/`rawBytes()` read unverified),
  unlike Android/desktop which verify on read too. Sound against a malicious *relay* (every inbound path
  funnels through the two verified chokepoints), but does not catch at-rest file tampering.
- **Android `videoFile` cache short-circuit** (`LocalMedia.kt:178-179`): returns a cached `.mp4`
  *before* verification; a crash between the decrypt-write and the verify leaves an unverified plaintext
  file that later calls return unchecked. Narrow (needs attacker timing + an OOM/crash window, which
  this codebase has a history of), but real.

---

## F11 / F17 — RESOLVED

**F11.** `DeviceKeyStore.loadSeed` is gone; `loadSeedStatus()` (`DeviceRoster.swift:89`) now returns a
three-way `SeedStatus` and preserves the `OSStatus`: `errSecSuccess`→`.found`,
`errSecItemNotFound`→`.notFound`, **everything else** (including `errSecInteractionNotAllowed`)→
`.lockedOrError`. `deviceAccount()` generates+saves **only** on `.notFound` (`:44-49`); a present-but-
underivable seed returns a throwaway and **never overwrites** (`:38-40`), and a locked read hands out a
retried temporary identity. This is a faithful copy of the `AccountStore` discipline round 1 praised.
The bug class is closed.

**F17.** `cargo audit` (554 crates, fresh db) still lists two `quick-xml` 7.5-high advisories — but
`cargo tree -i` shows the **attacker-reachable** copy, `haven-s3`'s direct dependency, is now
`quick-xml v0.41.0` (advisory-free). The remaining flagged `0.39.4` is transitive under
`iroh → netwatch → netdev → plist`, which parses **local** system plists, not the hostile-S3-endpoint
XML — exactly round 1's reachability call. `crossbeam-epoch`/`paste`/`anyhow`/`spin` are unchanged and
were already deemed carry-able. The one security-relevant bump is done.

---

## Video GPS strip (non-audit fix) — RESOLVED, empirically

The highest-value re-verification, and it holds under a real `exiftool`. A source `.mov` carrying a
QuickTime location atom was exported through **each** of the six `AVAssetExportSession` configurations
the app actually uses:

```
SOURCE (loci injected):       GPSCoordinates: 37 deg 46' N, 122 deg 25' W
OLD  (metadata = [] only):    LocationInformation: Lat=37.77489 Lon=-122.41940   ← THE BUG: leaks
NEW  (metadataItemFilter=.forSharing()):  (no location tags)                     ← stripped
```

Box-level grep exposed the mechanism the round-1 note only suspected: `metadata = []` didn't merely
fail to strip — AVFoundation **re-encoded** `©xyz` into a `loci` box while honoring the empty array.
All six paths (`Media.swift` :124/:129, :509/:515, :549/:552, :579/:583, :663/:670, :719/:728) set
`.forSharing()` and produced **no location tags**, including the passthrough remux most likely to skip a
filter. JPEG EXIF GPS is stripped on re-encode (`addImage`/`Platform.swift:49`, proven with exiftool),
and the Android instrumented test is genuine — it asserts the fixture *carried* GPS before testing the
strip, then remuxes via MediaExtractor/MediaMuxer without `setLocation`.

**Two documented leak paths remain, by design and disclosed in-code:** `importTrimmed`
(`Media.swift:597`) raw-copies (safe today only via an unenforced caller invariant), and the
"both exports failed" last-resort raw fallback (`Media.swift:495`, Android `readVideoBytes`) posts the
original bytes rather than nothing. Worth a `stripVideoMetadata` on `importTrimmed` to make it
self-defending.

---

## Epoch rotation & Revocation (non-audit) — rotation RESOLVED; revocation code honest, docs/UI NOT

**Rotation.** `rotate_if_stale` (`haven-ffi/src/lib.rs:1113`) advances the epoch once
`ROTATE_INTERVAL_SECS` (7d) elapses, driven from `epoch_sync_bundle_inner` (`:2098`) so every sync
attempts it, with a backward-clock guard (`:1118`) so skew can't force rotation. This is additive C2
forward-secrecy hardening; sound.

**Revocation.** Correctly **not** fixed, and the code is now brutally honest:
`recipients_with_devices` (`core/haven-p2p/src/device.rs:350`) **always** pushes the account key for
every member ("ALWAYS seal to the account key", `:362`) before adding device bundles, and its own
comment says "against a device whose seed was extracted, revoking is advisory… do not describe
revocation as cryptographic." A seed-holder keeps decrypting regardless of the roster. **But the
truth-telling landed on one surface out of several** — see R2 and R3.

---

## R1 — HIGH: WebRTC call signaling is unauthenticated **and** unsealed

Round 1 flagged this as unexamined ("call signaling is non-idempotent and was never examined"). It is
worse than non-idempotent: it is **unauthenticated and unencrypted**, and the code comment that says
otherwise is false.

**Unsealed.** `sendCallFrame` (`FeedView.swift`) sends `frame(type, payload)` via `sendIroh` **raw** —
no `seal_*` call anywhere in the call send path — and *additionally* forwards the identical raw inner
frame through the circle relays via `originateRelayInternet` (frame 9), which the relay host unwraps and
re-sends. `WebRTCCall.swift:22` claims signaling "rides Haven's existing sealed P2P channel" — it does
not; it rides the transport in cleartext. Every SDP offer/answer and ICE candidate (which contains
candidate **IP addresses**) is visible to any relay on the frame-9 path.

**Unauthenticated.** The FFI **does** deliver the QUIC-verified sender (`on_inbound(from_hex, payload)`,
`haven-ffi/src/lib.rs:862`; threaded into `handleInbound` as `senderDevice`, `FeedView.swift:651`),
and `handleHello` **uses** it (compares at `:2380`). But the `switch type` dispatches **every** call
frame (10/11/12/16/17/18/21/22) passing only `payload` to `CallManager` — the transport-verified id is
**discarded**. The frame-9 relay path (`:2028`) calls `handleInbound(inner, viaNearby: true)` with **no**
`senderDevice` at all. Authorization then rests entirely on the **self-declared** 64-hex prefix inside
the payload: `handleOffer`/`handleIce` gate on `roster.contains(from)`, `handleInvite` on
`knownContact(from)` — where `from` is attacker-chosen.

**Attack.** Node ids are semi-public (reach-me links, QR, signed rosters). A malicious relay — or any
node that can land a frame-9 or an iroh frame on the victim — sets `from` to a contact the victim knows
and:
1. **Spoofs the incoming-call UI** as a trusted contact (forged frame 10/16 → CallKit renders the
   spoofed name full-screen; this is F3's perceptual-impersonation, reached here without even a Worker).
2. **Forges call control** — a spoofed hangup (12) drops a live call; a spoofed invite rings the victim.
3. **MITMs the media** — this is the serious one. Because the SDP offer is neither signed nor sealed, a
   relay on the frame-9 path can rewrite the **DTLS-SRTP fingerprint** in the offer in flight. The
   victim accepts the attacker's fingerprint (the only check, `roster.contains(from)`, still passes —
   `from` is preserved), and the DTLS handshake terminates at the attacker → full call-media
   interception. WebRTC's media encryption is only as good as the fingerprint's authenticity, and
   nothing here authenticates it.

**Recommended fix.** (a) Bind every call frame to the transport-verified identity: thread `senderDevice`
into the call handlers and require `resolveAccount(senderDevice) == from` (mirroring `handleHello`), and
**refuse frame-9-relayed call-control frames** unless the inner frame is itself origin-signed. (b) Seal
signaling end-to-end like posts — the SDP/ICE payload should be a `SealedEnvelope` to the peer, so a
relay can neither read candidate IPs nor rewrite the DTLS fingerprint. Until (b), the "sealed P2P
channel" comment at `WebRTCCall.swift:22` must be corrected — it is the exact false-claim class as F7.

**RESOLVED (2026-07-15).** Both properties landed, the strong form of each. Every call frame is now
**sealed *and* signed to the recipient** before it leaves the device — one purpose-specific,
domain-separated primitive reused from the existing signed-notification path, not a new crypto path
and not a raw signing oracle (audit H3): `HavenSocial::seal_call_frame` / `open_call_frame`
(`haven-ffi/src/lib.rs`), the same `seal_media` + `sign` construction posts/notifications use.

- **(b) SDP/fingerprint — the MITM.** The whole signaling body (SDP offer/answer, ICE, control) is
  encrypted to the recipient's key, so a relay on the frame-9 path can neither read candidate IPs nor
  rewrite the DTLS-SRTP fingerprint: a flipped byte fails the AEAD and the frame is dropped. Chose the
  full seal over the signature-only minimum because it *also* closes the candidate-IP disclosure.
- **(a) Authentication.** The recipient verifies an Ed25519 signature over
  `domain ‖ recipient ‖ frame_type ‖ plaintext` against the *carried* sender bundle, then requires the
  proven sender to equal the self-declared `from` prefix the handlers key on. This works **identically
  on the direct and the frame-9 relay paths** — authentication now rests on the signature, not on a
  transport id the relay path never had — so the "refuse relayed control frames unless origin-signed"
  requirement is met by making *all* frames origin-signed. Binding `frame_type` blocks replay of a
  captured offer as another control type; binding `recipient` blocks cross-user replay. As
  defense-in-depth, the direct path additionally cross-checks the transport id via `account_for_device`.
- **No downgrade.** There is deliberately **no plaintext fallback**: if sealing fails nothing is sent,
  and an unsealed/legacy frame is refused on receipt, so a relay cannot strip the seal to force the old
  spoofable/rewritable form.
- **Group calls.** Frames are per-recipient already (`sendCallFrame(..., to: peer)`), so a mesh group
  call seals one frame per pairwise peer — covered exactly like a 1:1.
- **The false comment** (`WebRTCCall.swift`, `CallManager.swift`, `knownContact`) is corrected on every
  platform: it now describes the seal + signature accurately.

Shipped on all four surfaces (iOS/macOS `FeedStore.sendCallFrame` + `handleInbound`, Android
`CallManager` send/handle, desktop `engine.rs` `send_call_frame` + `handle_call`). Proven dead by
`call_frame_seal_defeats_relay_mitm` (`haven-ffi/src/lib.rs`), which exercises the frame-9 relay
path specifically: a genuine signed offer is ACCEPTED with Alice's real fingerprint; a relay-rewritten
offer, a Mallory-forged offer claiming to be Alice, an offer replayed as another type, a wrong-recipient
frame, and a legacy unsealed frame are each REJECTED. `cargo test -p haven_ffi` green (13/13); iOS +
macOS + Android + desktop all build. Live 1:1/group call is build-verified only in this environment.

---

## R2 — HIGH (docs): SECURITY.md still calls device-roster revocation "cryptographic, not advisory"

`docs/SECURITY.md:24-28`: "Removing/blocking a member, **or a device-roster change**, rotates the epoch
so the removed node **cannot decrypt content posted afterward** — cryptographic revocation, not
advisory." The `or a device-roster change` half is **false**, and it is the precise claim commit
186e25b ("Stop promising revocation defeats a compromised device — it doesn't") set out to kill —
still live in the security document a researcher reads first. Ground truth: `device.rs:362` always seals
to the account key; every linked device holds the master seed (`DeviceRoster.swift:11-20`), so a revoked
device keeps decrypting. SECURITY.md carries **no** revocation caveat anywhere. *Member* removal is
genuinely cryptographic (the account key leaves the set); *device* revocation is not. The sentence
conflates them. **Fix:** scope the claim to member removal; state device revocation is advisory until
the D16 seed-drop, matching `device.rs:367-374`.

**RESOLVED 2026-07-15.** `docs/SECURITY.md:24-28` rewritten into two bullets: member removal/block is
labelled cryptographic (unchanged truth), and a new bullet states device-roster revocation is
**advisory, not cryptographic** — because `recipients_with_devices` **always** also seals to the account
key (`core/haven-p2p/src/device.rs:358-363`) and a linked device holds a copy of the master seed, so a
revoked-but-seed-holding device keeps decrypting; made cryptographic only by the unbuilt D16 seed-drop
(`core/haven-p2p/src/device.rs:371-373`). "cryptographic revocation, not advisory" no longer appears for
device changes.

## R3 — MED-HIGH (UI): Android + desktop still promise a revoked device is cut off

186e25b fixed the Apple string only (`git show 186e25b --stat` = one file). Still shipping the promise:
- `android/.../ui/SettingsScreen.kt:790` — *"This device will no longer receive anything posted to your
  circles afterward."* (verbatim the string the fix commit names as false)
- `desktop/ui/app.js:2526` — *"Revoke "…"? It will no longer receive anything posted afterward."*

Both are false against every linked device today (all hold the seed). A user revoking a phone they
believe was compromised reads a safety guarantee they do not have. **Fix:** port Apple's corrected copy
(and its `revocationCaveat`) to both.

**RESOLVED 2026-07-15.** Both revoke dialogs now mirror 186e25b's honest caveat: `SettingsScreen.kt:790`
and `desktop/ui/app.js:2526` state revoking cuts off a **lost/stolen** device but cannot help against a
device whose master key was extracted (linked devices hold a copy), and that the only remedy there is a
new identity. Also corrected the parallel "revoke it at any time" role subtitles (`SettingsScreen.kt:731`,
`app.js:2514` → "holds a copy of your master key and syncs with your primary device, which can revoke it")
and the desktop devices footer's "each gets its own revocable key" (`app.js:2422`). Android + desktop
compile clean.

## R4 — MEDIUM (docs): TERMS.md overstates "cannot tell who reported whom"

`docs/TERMS.md:45-47`: "the report is signed by your key… but the signature is checked and discarded,
not stored. The developer therefore **cannot** tell who reported whom." The **actor is transmitted** on
the wire (`ReportUI.swift:30`, `Moderation.kt:41`, `engine.rs` all send `actor: nodeIdHex()`; the Worker
destructures and `verifyReg`s it, `worker.js:158,168`). Only **persistence** is ruled out
(`worker.js:174` stores no actor). So the honest verb is **"does not retain"**, an operator-policy
boundary, not **"cannot"**, a cryptographic one — and `docs/SECURITY.md:99-104` already gets this exactly
right ("the Worker observes the actor in memory… an operator-policy boundary, not cryptographic"). In a
document that attaches service refusal and legal disclosure to these rows, the overstatement matters.
**Fix:** change "cannot tell" to "does not retain, as a matter of code and policy", and cross-reference
`SECURITY.md:99-104`.

**RESOLVED 2026-07-15.** `docs/TERMS.md:43-47` rewritten: it now states the report is signed by the
reporter's key (not forgeable / not re-aimable), that verifying the signature means the key **is
transmitted** to the developer's server at report time, but is **not stored** — the saved record holds
only `{subject, action, category}` (`push/worker.js:174`) and its key derives from a one-way hash of the
signature (`worker.js:173`, `sigTag` `:298-301`), so the stored ledger carries "no record of who reported
whom." The absolute "cannot tell who reported whom" is gone; the real-time transmission (`worker.js:158`
actor in body, `:168` `verifyReg`) is now disclosed.

## R5 — MEDIUM (docs): appstore-metadata.md says reporting "is not technically possible"

`appstore-metadata.md:61`: "there is no copy of user content to moderate or **to report to** —
server-side filtering/**reporting is not technically possible**." Reporting to the developer **ships**
(`worker.js:146-176`, a 90-day ledger row, called from all three clients); `docs/SECURITY.md:72` now
says the opposite ("reporting exists and ships"). The 4178230 fix updated SECURITY.md and TERMS.md but
never touched this App-Review-facing file. (The same sentence's "a removed member… cannot decrypt
anything posted afterward" is **true** for member removal, so leave that clause.) **Fix:** state that
content-free reporting to the developer exists and is signed, matching `SECURITY.md:72`.

**RESOLVED 2026-07-15.** `appstore-metadata.md:61` rewritten: server-side **content** scanning is stated
impossible (no content leaves the device), but the copy now says user REPORTING **ships** — a circle-scoped
report (`EventKind::Report` authored per-circle, `core/haven-ffi/src/lib.rs:1960`, read via `reports()`
`:1964`) plus a content-free, cryptographically signed developer notice carrying only the reported
identity, action, and category, with the reporter's key verified but not stored. "reporting is not
technically possible" is removed; the true member-removal-is-cryptographic clause is kept.

## R7 — INFO: haven-wasm is dead code with a seed-exfil footgun; delete it

`core/haven-wasm` compiles (the `build_feed` arity break is fixed) but is **not built or shipped** —
`docs/WEB-PARITY.md:1,28-29` records the web client as ABANDONED and the crate as "a vestige… candidate
for removal"; no CI, no `wasm-pack`, no `.wasm` artifacts, no JS glue reference it. Its only tie to the
build is the `core/Cargo.toml` workspace member line. RNG is correct (`getrandom` `js`/`wasm_js`), no
secret is logged, no secret reaches a URL, and it holds **less** authority than native. But
`lib.rs:61-65` exports `seed_hex()` across the wasm-bindgen boundary and its doc comment **recommends
persisting the master seed to `localStorage`/IndexedDB** — a direct mandate violation (readable by any
XSS on the origin and by extensions, with no Enclave/Keystore/keyring equivalent) if the crate is ever
revived. Round 1's premise that the transfer-code flow "advertises moving the seed to a web client" is
**incorrect** — `AccountStore.swift:115-117` says the opposite — so that specific worry is closed.
**Fix:** drop `haven-wasm` from `core/Cargo.toml` and delete the crate, removing the footgun before
someone finds it.

**RESOLVED 2026-07-15.** Crate directory `core/haven-wasm` deleted and its workspace member entry removed
from `core/Cargo.toml`. Verified no dependents beyond that line (no Cargo.toml dep, no JS/wasm glue, no
`.rs` reference). `cargo check --workspace` is clean. Note: `docs/WEB-PARITY.md:28` still describes the
crate "as a vestige… candidate for removal" — now stale (out of this pass's scope; flag for a follow-up).

---

## Round-2 ship gate

**Additional fix-before-v1 (on top of round-1's list):**

1. **R1** — call signaling is the one genuinely new *code* vulnerability: unauthenticated and unsealed,
   enabling caller-ID spoofing and DTLS-SRTP call-media MITM by a relay. Bind frames to the
   transport-verified sender; seal signaling E2E. This is a mandate issue (a relay operator becomes a
   MITM chokepoint on calls).
2. **R2 + R3 + R4 + R5** — the revocation and reporting truth landed on some surfaces and not others.
   Every one of these is a public, load-bearing claim that the code contradicts. Cheapest category to
   fix, most damaging if a researcher finds it first (same reasoning as round-1 F7/F8).
3. **R6** — ~~close the HTTP devroster-PUT hole with `verify_devroster`; it reopens F4 for that
   namespace.~~ **RESOLVED**: `verify_devroster_put` gates the write on BOTH transports (fail-closed +
   rollback defense); the round-2 attack PUT now returns 403 while signed enrollment still lands 200.

**Acceptable to ship with, tracked:** F5's legacy/self-downgrade residuals, F9's no-TLS partial, the F1
sybil floor (documented), R7 (delete the dead crate).

**Does anything block a v1 announcement?** Yes — R1 (call MITM) and the R2–R5 false public claims. The
crypto core, the relay authorization rebuild (F2/F4-reads/F10), the signed `/flag`, content-addressed
media, F11, F17, and the video-GPS strip all **hold under attack** and would not, on their own, block a
ship. The blockers are the new call-signaling surface and the honesty gap between what several docs/UI
strings still promise and what the code does.

**Honest confidence.** *High* on everything I executed — F1 (live forgery suite), F2/F4-reads (probe
green), F4-writes/R6 (round-2 attack succeeded, then fixed — the attack PUT now 403), video GPS
(exiftool), F17 (`cargo tree`). *High* on R1,
R2, R3, R4, R5: R1 is a code-path traced end-to-end (send is raw, `senderDevice` is provably discarded
for call frames, frame-9 drops it) and the others are direct doc/UI-vs-code contradictions I read on
both sides. *High* on F11 (read completely). *Medium-high* on F5 (test green, legacy path reasoned not
executed as an attack — the ref-injection primitive genuinely does not exist, but that rests on the
signature covering the ref, which I verified by reading not by forging). *Not covered this round:* the
DTLS-SRTP media path itself beyond the fingerprint-authenticity argument, `SelfSync` reducer semantics,
the S3 tunnel internals, and any non-Apple platform layer beyond the specific strings and call sites
cited. `haven-wasm` is dead code (R7), so its latent issues are informational only.

**One-line summary for round 2:** round 1's fixes hold where I could attack them — the signed `/flag`,
the relay authorization, content addressing, and the video-GPS strip are real and survive an adversary;
the remaining gaps are one new code surface that never got the same treatment (call signaling), a device
roster write the HTTP path forgot to verify, and four public claims that still say the code does
something it doesn't.
