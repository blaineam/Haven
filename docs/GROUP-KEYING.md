# Group keying — access revocation + forward secrecy (PQ-preserving)

Status: **in progress** (increment 1 — core `groupkey` module landed + tested). This refines decision
**D3** (which named classical MLS) with a post-quantum-preserving design.

## Why not classical MLS (`mls-rs`)

The 2026-06 security audit found two structural gaps in the original "seal every event to each
recipient with the hybrid KEM" scheme (`social.rs`):

1. **No access revocation** — a removed/blocked member keeps the ability to decrypt content posted
   *after* their removal (every event is wrapped to their static KEM key; nothing rotates).
2. **No forward secrecy** — content keys wrap to long-term static KEM keys, so one seed compromise
   decrypts all history.

Classical MLS (RFC 9420, `mls-rs`) fixes both — but at two costs that are unacceptable for Haven:

- **It is not post-quantum.** MLS's standard ciphersuites are X25519/Ed25519/AES. Adopting it would
  *drop* the hybrid X25519+ML-KEM-768 / Ed25519+ML-DSA property that is Haven's headline guarantee
  ("harvest now, decrypt later" resistance). PQ-MLS is still research-stage.
- **It assumes ordered handshake delivery.** MLS epochs advance via Commits that every member must
  apply in order. Haven is **offline-first and eventually-consistent**: posts and key material gossip
  over iroh + relays + S3 mailboxes, arrive out of order, and a member can be offline for days. A
  strict per-message ratchet (TreeKEM) breaks under that delivery model.

## The design: epoch group keys distributed via the hybrid KEM ("circle ratchet")

This is the well-understood *sender-keys-with-rekey-on-membership-change* construction (the pre-MLS
WhatsApp/Signal-group approach), adapted to carry the epoch key over Haven's **hybrid PQ KEM** so the
post-quantum property is preserved end to end.

- Each circle has an ordered sequence of **epochs**. Epoch *E* has a random 32-byte `epoch_key`.
- A **KeyCommit** is a signed envelope that seals the epoch key to a specific member set, wrapping it
  per-recipient via the existing hybrid KEM (`encapsulate_to` → X25519+ML-KEM-768, AES-256-GCM). It
  carries `circle_id` + `epoch` in its authenticated payload. This is the *only* place the per-recipient
  KEM wrap is still used — once per epoch, not once per event.
- **Events** (posts/messages/media/comments/reactions/…) are sealed with a per-event key derived from
  the current epoch key: `event_key = HKDF(salt, ikm = epoch_key, info = "haven-event-key-v1" ‖ circle ‖ epoch)`,
  then AES-256-GCM, and hybrid-signed by the author. The envelope carries `circle_id` + `epoch` +
  ciphertext + signature — **no per-recipient wrapping**, so it is true group encryption and smaller.
- **Event sealing is deterministic** (per `(plaintext, circle, epoch, epoch_key)`): the carried `salt`
  is a keyed BLAKE3 PRF over the plaintext (keyed by the epoch key), and the AES-GCM nonce is derived
  from the resulting per-plaintext `event_key`; the hybrid signature (Ed25519 + ML-DSA's deterministic
  variant) was already deterministic. Re-sealing the same event therefore reproduces the envelope
  byte-for-byte, so the relay mailbox's content-addressed key (`SHA256(envelope)`) is stable and a
  history backfill dedupes instead of accumulating a fresh copy of every event per run (the unbounded
  mailbox growth that made cold starts re-pull thousands of duplicates). Safety: a different plaintext
  (e.g. an edited event) derives a different salt → a different key + nonce, so a (key, nonce) pair
  never covers two distinct plaintexts. Tradeoff (accepted): an observer holding two envelopes from the
  same epoch can tell whether they seal the *identical* plaintext — that equality is exactly what the
  mailbox dedup relies on, and without the epoch key the salt is indistinguishable from random.
  Determinism is also what powers **mailbox GC**: each member can re-derive the exact refs of its
  own live envelopes and TOUCH-refresh them daily on every relay, so relays TTL-expire everything
  no member re-asserts — the legacy random-seal duplicates and stale-epoch copies (a rotation
  re-seals history under the new epoch → the old epoch's envelopes become dead weight). See
  [`RELAY-AND-DEPLOY.md`](RELAY-AND-DEPLOY.md) "Mailbox garbage collection".

### Membership change → new epoch (this is what gives revocation)

On **add** or **remove/block**, the actor (any current member; conflicts resolve by highest-epoch-then-
lowest-committer-id) generates a fresh random `epoch_key`, bumps the epoch number, and emits a KeyCommit
sealing it to the **new** member set:

- **Remove/block:** the removed node is not in the recipient set → never receives the new `epoch_key`
  → cannot derive any `event_key` for the new (or any later) epoch. Revocation is **cryptographic**,
  not advisory. (Their access to *already-delivered* past-epoch content cannot be retroactively pulled —
  that is inherent to E2EE and is documented as such.)
- **Add:** the new member is in the recipient set → gets the current `epoch_key` forward. Whether they
  also receive *past* epochs is exactly the existing **"Add & share history" vs "new posts only"**
  choice: share-history re-seals prior epoch keys to them; new-posts-only does not.

### Forward secrecy (bounded, by design)

True per-message FS (Double Ratchet) is incompatible with multi-recipient, offline, eventually-consistent
delivery. Instead:

- Epoch keys rotate on **removal/block**, on a device-roster change, **and** on a periodic schedule
  (time/-volume based). Adding a member does NOT rotate — and doesn't need to: a joiner is handed the
  *current* epoch, so earlier epochs stay unreadable to them without rotating anything. Rotation exists
  to revoke, not to admit. (Said precisely because "rotates on every membership change" once leaked into
  the relay walkthrough's UI copy as "add or remove someone and the key rotates", which is not true and
  implies a guarantee the code doesn't make.)
- Clients **delete** epoch keys older than the circle's retention window. A seed/device compromise then
  reveals only the *current* epoch plus retained-history epochs — not all history forever.

This is "bounded forward secrecy": strictly stronger than today (which has none), and the strongest the
delivery model admits without breaking offline use.

## Properties

| Property | Old (per-recipient static) | New (epoch group keys) |
|---|---|---|
| Post-quantum (hybrid) | ✅ | ✅ (KEM still wraps epoch keys) |
| Sender authentication | ✅ (hybrid sig) | ✅ (hybrid sig per event + per commit) |
| Access revocation on remove | ❌ | ✅ cryptographic (new epoch excludes them) |
| Forward secrecy | ❌ | ✅ bounded (rotation + retention-bounded deletion) |
| Offline / eventually-consistent | ✅ | ✅ (epochs are content-addressed, order-independent within an epoch) |
| Envelope size | O(members) per event | O(1) per event; O(members) once per epoch |

## Rollout (increments)

1. ✅ **Core `groupkey` module + tests.** Epoch-key generation, KeyCommit seal/open (revocation proven),
   per-event key derivation, seal/open-under-epoch.
2. ✅ **Engine integration** (`p2pcore-ffi`). Implemented as **sender keys**: each member runs their own
   epoch sequence (`my_epoch`/`my_epoch_keys`) and stores peers' keys by `(author, epoch)`. `post` seals
   under my current epoch; `remove`/`block` rotate my epoch (next commit excludes the removed node);
   `receive` routes tagged envelopes (key commit / epoch event / legacy) with a pending buffer for
   out-of-order delivery. Engine test proves a removed member can't read post-removal content.

   > **Own-device caveat + fix (important for multi-device).** Because `ensure_epoch` mints a *random*
   > epoch key per device, a user's own devices (which share the account seed but each run their own
   > sender-key sequence) generate **different** keys for the same circle+epoch and can't open each
   > other's events. `receive_key_commit` resolves this by **converging** an own-authored commit onto
   > the numerically-larger epoch key + circle secret (both devices pick the same winner independently),
   > so own-device posts/DMs sync. See [`MULTI-DEVICE.md`](MULTI-DEVICE.md) → *Own-device event
   > convergence*.
3. ✅ **Wire/migration (read path).** 1-byte wire tag (`0x02` epoch event, `0x03` key commit; untagged
   `{…}` = legacy). Circles bootstrap epoch 0 on first post; legacy envelopes still open. *Alpha cutover:*
   new posts are epoch-sealed, so peers must be on a build that understands the tags — acceptable for alpha.
4. ✅ **FFI + platforms — no change required.** The FFI surface is unchanged and key commits ride the
   existing `sync_envelopes`/`export_my_envelopes` channel (delivered as ordinary event frames + via the
   relay mailbox), so iOS/macOS/Android/desktop inherit this through the shared core with **zero**
   networking changes. (Validation: rebuild bindings + smoke-test each platform.)
5. ✅ **Relay:** unaffected (still ciphertext-only); KeyCommits ride the same transports as events.
6. ✅ **FS scheduling (bounded).** `prune_epoch_keys` keeps only the last 4 epoch keys (mine + per
   peer) and deletes the rest on every rotation/commit, so a later compromise can't decrypt older
   wire/relay ciphertext. `rotate_circle(circle_id)` forces a fresh epoch for periodic rotation (call
   on a schedule). *Remaining (minor): wire the periodic `rotate_circle` cadence into each platform's
   timer; a "share history → re-seal prior epochs to a new member" path; retire the legacy per-recipient
   path once all clients are migrated.*

## Test obligations (per increment)

- Revocation: a removed member cannot open a post sealed under the post-removal epoch (proven in #1).
- Add semantics: a new member opens current-epoch content; only sees history when history was shared.
- Round-trip: every member opens every same-epoch event; tamper/forgery rejected (GCM + signature).
- Offline: events from an epoch open regardless of arrival order, with or without later epochs present.
- Migration: a feed mixing legacy + epoch envelopes reduces correctly.
