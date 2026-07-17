# Switch-Flip 1.0.7 — the client enable-sequence

The 1.0.7 crypto (seed-drop retirement, MLS/TreeKEM keying, admin authority, per-message DM forward
secrecy, self-sync key rotation, seedless enrollment) ships **dark** — every switch defaults OFF and
the wire is byte-identical to 1.0.6. This document is the exact sequence a client (Apple / Android /
Desktop) must perform to turn everything ON, derived from the end-to-end validation in
`core/haven-ffi/tests/enabled_paths.rs`. Follow it verbatim; the ordering constraints are load-bearing.

Design references: `docs/SEED-DROP-DESIGN.md` (§4.5, §5, §7) and `docs/TREEKEM-DESIGN.md` (§4.2/§4.3/
§4.5/§6/§7). The switch FFI lives in `core/haven-ffi/src/lib.rs` and `…/multidevice.rs`.

> **Golden rule — every switch is gated, none acts prematurely.** Flipping a switch ON does not change
> a single sealed byte until the *whole circle* (or the *whole own-device fleet*, for self-sync) is
> capable. A mixed-version circle with even one legacy member stays on the legacy path and everyone
> keeps reading. This is what makes shipping the switches ON in 1.0.7 safe: the gate, not the client,
> decides when the new path activates. (Proven in `mixed_version_circle_stays_legacy_until_fully_capable_then_reflips`.)

---

## 0. Preconditions (per device, once)

The build already advertises `sd=1` (seed-drop) and `ml=1` (MLS) capability inside every signed
profile card (`my_signed_profile`). Nothing to do — but understand the machinery you depend on:

- A peer becomes **seed-drop / MLS capable** in your eyes only after you have run their signed profile
  card through `profile_seed_drop_version(peer_bundle, card)` **and** ingested their device roster
  (which carries the capability trailer). Absence is never a downgrade and never an upgrade — a forged
  or missing marker reads as legacy (0).
- Your own account is self-seeded capable at birth (so a circle containing only you can still compute
  as fully capable).

---

## 1. Adopt a device identity and publish a **device-only** roster

```
use_device_identity(device_seed)                     // 32-byte per-device seed
register_device(my_device_bundle(), name, created_at) // → your signed roster wire; broadcast it
```

**Roster shape is decisive.** Live MLS keying and account-key retirement both require every tree leaf
to map to a live, joining device — i.e. a **device-only** roster that lists your device id(s) and
**not** the bare account id. `register_device` / `sign_device_list` should emit a device-only list for
a fully-upgraded account.

> ⚠️ **Migration caveat (see enabled_paths §1 FINDING).** An account's *own* roster is grow-only
> union-merged — it can never shed a leaf it already registered. A user who already had a legacy
> `{account, device}` roster therefore **cannot** shrink to device-only and will settle at **shadow**
> (dual-stack, legacy-keyed content), never **live**. That is safe (nothing is lost, the shadow tree
> converges), but such users do not get tree-keyed content or account-key retirement until core grows
> a device-only-roster migration path. New installs that register device-only from day one are
> unaffected. Do **not** try to force live keying on a migrated account+device roster.

Cross-learn peers both directions:

```
ingest_roster_wire(peer_roster_wire)                 // learn their devices + capability trailer
profile_seed_drop_version(peer_bundle, peer_profile_card) // mark them sd+ml capable
```

---

## 2. Pin the circle creator (authority root) — on **every** circle, at creation time

```
set_circle_creator(circle_id, creator_account_hex)   // the DEFINITION-bound authority root (AUDIT M2)
```

- Do this when the circle is created (the creator is the account that created it) and re-apply on every
  launch — it is **not** persisted as a keying decision; it rides the authenticated circle definition.
- The creator can delegate admin: `grant_circle_admin(circle_id, admin_account_hex)` (higher-version
  wins; the grant propagates on the control lane). Admin authority is what gates
  `mls_remove_member` — a non-admin's Remove is refused at the committer and rejected by receivers.

---

## 3. Turn on MLS keying (master switch, per device)

```
set_mls_keying(true)                                 // re-apply on every launch; not persisted
```

Then sync all-to-all. The circle transitions itself:

- `off` → `shadow` (switch on + capable, not yet all-joined; **KeyCommit still keys content**)
- `shadow` → `live` once **every** device leaf has joined the tree (§7.2 all-joined gate). At `live`,
  content is keyed by the tree and the legacy **KeyCommit STOPS** (§4.5).
- If a non-capable / not-yet-joined device (re)appears, the circle **parks** back to KeyCommit within
  one bundle (§7.3) and re-flips when the straggler becomes capable + joins. No content is ever lost
  across park/re-flip.

Observe state with `mls_keying_status(circle_id)` → `{ state, epoch }`. Never assume `live`; act on the
reported state. (Proven in `mls_keying_on_flips_live_stops_keycommit_and_content_round_trips`.)

### Membership changes once live

- **Add** is automatic: when a newly-authorized device's roster reaches the creator, the creator chains
  an `Add+Welcome` at the current epoch — the joiner enters at the **live** epoch (continuity, not a
  genesis rebuild) and reads history via the re-seal backfill. No explicit call.
- **Remove**: `mls_remove_member(circle_id, target_account_hex)` — creator/admin only. It authors a
  chained `Remove + UpdatePath` commit, advancing the epoch. The removed device cannot derive the new
  epoch, cannot open post-Remove content, and cannot re-enter (it is not an admin). A non-admin call
  returns `false` and authors nothing. (Proven in
  `circle_removal_cuts_off_the_device_and_non_admin_removal_is_rejected` +
  `creator_delegated_admin_can_remove_after_grant`.)

---

## 4. Turn on seed-drop retirement (per device)

```
set_seed_drop_retire(true)                           // re-apply on every launch; not persisted
```

- **Gated exactly like keying.** Inert until the circle is *fully capable*. While inert (OFF, or a
  mixed-version circle), a bare account key still opens content — backward compatible.
- Once fully capable AND ON, the bare account key is **dropped from the sealing set**: content is keyed
  device-only, and a holder of only the account seed (a revoked/leaked seed with no authorized device)
  is cryptographically cut off. (Proven in
  `retirement_on_keys_device_only_and_cuts_the_account_seed_holder`.)

Order relative to §3 does not matter (both are gated on the same all-capable predicate), but retire
should not be enabled before the fleet is device-only-rostered — otherwise it is simply inert.

---

## 5. Per-message DM forward secrecy — mark `dm:` circles as live lanes

```
set_circle_live_lane(circle_id, true)                // for dm:<a>-<b> circles; re-apply on launch
```

- Consulted **only** once the circle is keying-live. On a marked, live circle each message carries a
  monotonic **ratchet index** (0,1,2,…) and opens out-of-order via the receiver's skipped-key cache —
  the mailbox days-late/out-of-order contract holds, and message N's key does not reveal N-1.
- On an unmarked circle (feed traffic) or a not-yet-live circle, posts stay epoch-keyed with **no**
  ratchet field — byte-identical to today. Mark only actual DM lanes. (Proven in
  `dm_live_lane_ratchets_and_opens_out_of_order`.)

---

## 6. Self-sync key rotation — rotate on **every** device revocation

The account-state self-sync channel (`self/<account>/state/<device>`) must rotate its key whenever a
device is revoked, or a revoked device keeps reading and LWW-writing your account state forever.

### The gate (mirrors retirement exactly)

```
self_sync_key_should_rotate(retire_switch_on, own_devices_all_seed_drop_capable) -> bool
```

- `false` (switch OFF, or any own device not yet capable) ⇒ keep using the **v0** path:
  `seal_account_state(seed, state)` / `open_account_state(seed, blob)` — byte-identical to today.
- `true` ⇒ run the **v1** rotatable path below.

### On revocation (primary, holds the seed)

```
k = mint_self_sync_key()                              // fresh 32-byte key from the OS CSPRNG
// bump the epoch; re-grant ONLY to still-authorized device bundles:
for dev in still_authorized_devices:
    seal_self_sync_key_epoch_grant(seed, dev_bundle, epoch, k)   // → sealed, account-signed grant
seal_account_state_with_key_epoch(k, epoch, state)    // seal state under the rotated key
```

The revoked device is simply **not** a grant recipient — it keeps only the stale key.

### On the reader (every device, dual-key open)

```
open_account_state_dual(sealed, current_epoch, current_key, seed_key)
```

- `current_epoch` / `current_key` — the rotated key you currently honor. A blob at any *other* epoch (a
  revoked device's stale write) is refused.
- `seed_key` — the v0 seed-derived key **during the transition window**, or an **empty vec** once v0
  authority is retired (fully-capable + switch ON). Passing empty completes the cut: legacy blobs and
  stale-epoch writes are both rejected.

A revoked device can then neither open the post-rotation state nor have its write accepted; authorized
devices converge. (Proven in `self_sync_revocation_rotates_key_and_cuts_the_revoked_device`.)

> **Absence-as-deletion ordering constraint (§7).** Self-sync is CRDT-additive: import the primary's
> exported state as a *base* before applying any diff, and never let a peer's `None`/omitted field
> tombstone a locally-held value (e.g. a seedless device's own granted roster wire must survive a
> self-sync that omits it). Establish the self-sync base **before** the first diff.

---

## 7. Seedless enrollment (a device that never holds the account seed)

For a device enrolled without the seed (seed-drop S4), drive the enroll handshake
(`enroll_issue_ticket` → `enroll_build_request` → `enroll_verify_request` → `register_device` →
`enroll_assemble_grant` → `enroll_open_grant`), then `ingest_roster_wire(grant.roster_wire)`. The device
receives the granted (epoch-tagged) self-sync key and seals/opens its own slots with
`seal_account_state_with_key[_epoch]` / `open_account_state_dual`. It authors ACCOUNT-attributed content
in a fully-capable circle and never re-signs a roster (the primary is the sole authority). This path is
already exercised by `migration_harness::seedless_enrollment_receives_history_and_nothing_is_tombstoned`.

---

## What stays OFF / legacy until a circle is fully capable

| Feature | Activates only when | Until then |
|---|---|---|
| MLS live keying (`set_mls_keying`) | circle fully capable **and** all-joined | `shadow`/`parked` — KeyCommit keys content |
| Account-key retirement (`set_seed_drop_retire`) | circle fully capable | dual-seal — account key still opens content |
| DM ratchet (`set_circle_live_lane`) | circle keying-**live** | epoch-keyed, no ratchet field |
| Self-sync key rotation | `retire ON` **and** all own devices capable | v0 seed-derived seal/open |

Every one of these is byte-identical to 1.0.6 while its gate is unmet. Ship the switches ON; the fleet
migrates itself, circle by circle, as members upgrade — and no partially-upgraded circle is ever
stranded or loses data.

---

## Recommended client call order (summary)

1. `use_device_identity` → `register_device` (device-only roster) → broadcast roster wire.
2. Cross-learn peers: `ingest_roster_wire` + `profile_seed_drop_version` (both directions).
3. `set_circle_creator` on every circle at creation (+ `grant_circle_admin` for delegates).
4. `set_mls_keying(true)`; sync; watch `mls_keying_status` climb off→shadow→live.
5. `set_seed_drop_retire(true)` (gated; safe to set any time).
6. `set_circle_live_lane(true)` on `dm:` circles.
7. On each revocation: `mint_self_sync_key` → `seal_self_sync_key_epoch_grant` to survivors →
   `seal_account_state_with_key_epoch`; readers use `open_account_state_dual` (empty `seed_key` once
   fully retired). Establish the self-sync base before the first diff.
8. Re-apply steps 3–6 (the non-persisted switches) on every launch.
