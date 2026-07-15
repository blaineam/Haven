# Multi-device: one account, many authorized devices

> **Status — building the full model in phases (D16).** What already ships: a
> **multi-identity switcher**, **move-to-device** via a transfer code / QR (`haven-seed:…`),
> **iCloud-Keychain backup/restore** of identity history (the active seed stays device-only),
> and **multi-token push** (the relay holds several device tokens per identity, so every
> linked device gets pushes and authored events self-sync through the shared circle mailbox).
>
> **Phase 1 (done):** the **device-credential trust layer** is implemented and unit-tested in
> the core — [`p2pcore::device`](../core/p2pcore/src/device.rs): a per-device keypair, an
> account-signed [`DeviceCredential`] (`{account_id, device bundle, name, created_at}`), and a
> versioned, account-signed [`DeviceList`] (active + revoked, higher-version-wins merge,
> rollback-defended). This is deliberately **MLS-independent** — it's just signed bindings the
> existing per-recipient hybrid-KEM sealing can already encrypt to, so it works on today's
> engine and the MLS hardening (Phase 5) layers on without changing these signatures.
>
> **Phase 3 (shipped, all platforms):** the **convergence engine**
> [`p2pcore::selfsync`](../core/p2pcore/src/selfsync.rs) — an `AccountState` CRDT (last-write-wins
> registers for roster / contacts / profile / settings / blocked / **pinned conversations**,
> grow-only max read cursors) with a commutative/associative/idempotent `merge`, plus
> self-encryption via a seed-derived [`Identity::self_sync_key`] only the user's own devices can
> derive — is now wired end to end. The mailbox channel + sync loop run on **iOS/iPadOS, macOS,
> Android, and desktop**, so profile/settings/contacts/blocked/circles/message-pins converge and
> the mailbox only ever sees ciphertext.
>
> **Own-device event sync (shipped):** posts and DMs — authored *or received* on one device — now
> flow to the user's other devices. Two fixes made this real: (1) each device takes a **per-device
> transport identity** so multiple devices can run under one account without colliding on iroh
> discovery (the account seed stays the trust anchor / roster signer, never a transport address),
> and (2) **epoch-key convergence** — `ensure_epoch` mints a *random* epoch key per device, so a
> user's iPhone and Mac each generated a different key for the same circle+epoch and could never
> open each other's events; both devices now deterministically adopt the numerically-larger epoch
> key + circle secret ([`receive_key_commit`](../core/p2pcore-ffi/src/lib.rs)), so buffered events
> drain and future re-seals use the agreed key. Consistent across iOS/macOS, Android (shared `.so`),
> and desktop (links the crate directly).
>
> **Live delivery (shipped, Phase 4b):** an event authored on one device is now handed **straight to
> the user's other online devices** over iroh, instead of waiting out their next mailbox poll (~120s
> iOS / 30s+ Android/desktop). It is strictly additive — the mailbox put is unchanged and
> unconditional, so a sleeping device loses nothing. See
> [Live device-to-device delivery](#live-device-to-device-delivery-phase-4b).
>
> **Still ahead:** enrollment flow + UI (Phase 2), the **personal forwarder** half of Phase 4b (an
> always-on Mac as the user's own store-and-forward node — designed below, not built), and the MLS
> leaf/commit hardening for per-message forward secrecy + post-compromise security (Phase 5). See
> **Implementation phases** below.

## Implementation phases (D16)

| Phase | Scope | Where | State |
|---|---|---|---|
| **1. Device-credential trust layer** | Per-device keys; account-signed `DeviceCredential`; versioned signed `DeviceList` (add/revoke, higher-version-wins, rollback defense); verify against the pinned account key. Own-account replicas UNION-merge; where two copies disagree about a revocation the **strictly-newer list's verdict wins**, so `with_self_added`'s explicit (version-bumped) re-authorization propagates instead of a stale copy re-adding the tombstone forever — the roster/epoch-churn flip-flop that kept a device's own id revoked and rotated every circle epoch per launch. Clients must self-register AFTER importing persisted state (the restored roster's higher version clobbers a pre-import self-registration). | `p2pcore::device` | **✅ core done & tested** |
| **2. Enrollment & UI** | FFI export (done): `issue/verify_device_credential`, `sign/verify_device_list`, `device_list_is_authorized`, plus an `AccountStateHandle` object + `seal/open_account_state`. Ahead: QR/short-code link of a new device + out-of-band verification phrase; the authorizing device issues the credential and publishes a new `DeviceList`; "Blaine linked a new device" notice. Per-client (iOS → Android → desktop). | `p2pcore-ffi::multidevice` + clients | 🟡 **FFI export done**; enrollment QR/verify + UI ahead |
| **3. Account-state self-sync** | A per-account state blob (roster, circles, contacts, profile, settings, blocked list, read state, **pinned conversations**) **self-sealed to the account's own devices** and synced via the mailbox; CRDT/LWW merge so devices converge. Gives "my devices show the same thing." Plus **own-device event convergence** (per-device epoch keys converge on the numerically-larger key) so authored/received posts + DMs sync across devices. | `p2pcore::selfsync` + `p2pcore-ffi::receive_key_commit` + relay/nearby channel | ✅ **all platforms**: iOS/macOS + desktop (relay+S3) + Android (relay) converge profile + settings + contacts + blocked + circles + message-pins, and own-device posts/DMs sync |
| **4. Device-aware circle sealing + revocation** | A circle's epoch key seals to each member's AUTHORIZED **device** bundles (`recipients_with_devices`), never a revoked one; receive accepts a member's authorized device as committer/sender; ingest/store signed rosters (rollback-defended) + rotate epochs on add/revoke; rosters ride the sync bundle (`TAG_DEVICE_ROSTER`). | `p2pcore::device` + `p2pcore-ffi` | ✅ **core done & tested** — `linked_device_receives_then_revocation_cuts_it_off` proves a device receives content and revocation cuts it off. App side ahead: enrollment (device keypair + issue credential on link) + Authorized-Devices UI/revoke. |
| **4b. Live delivery + personal forwarder** | Real-time device-to-device push when both are online ([`haven_net::livedelivery`](../core/haven-net/src/livedelivery.rs)): an event authored on one device is handed straight to the user's other online devices, instead of waiting out their next mailbox poll. **Strictly additive** — the mailbox put is unchanged and unconditional, so live delivery only changes *how fast* a sibling learns, never *whether* (see below). Personal forwarder: not started. | `haven-net` + clients | 🟡 **live delivery done** (core + iOS/macOS + Android); forwarder ⏭️ |
| **5. MLS hardening** | Each device becomes an MLS leaf; Add/Remove **commits** give forward secrecy + post-compromise security on link/revoke. Gated on the separate MLS (D3) work. | `p2pcore` (mls-rs) | ⏭️ (after MLS) |

### Self-sync mailbox channel (the recipe clients implement)

The primitives are all shipped; a client's sync loop is just glue over them, using the **one
canonical key layout** defined in core (`selfsync::slot_key`/`slot_prefix`, FFI
`self_sync_slot_key`/`self_sync_slot_prefix`) so iOS/Android/desktop converge:

```
slot   = self/<account-node-hex>/state/<device-node-hex>   # this device owns its slot
prefix = self/<account-node-hex>/state/                    # all the account's slots
```

- **Push** (on local change / periodically): `relay.put(slot, seal_account_state(seed, state))`.
- **Pull + converge** (on a timer / push wake): for each key in `relay.list(prefix)`,
  `open_account_state(seed, blob)` → `state.merge(that)`. Then re-push your own slot so the
  merged view propagates. Because `merge` is commutative/associative/idempotent, order and
  duplicate delivery don't matter; because each device owns its own slot, devices never clobber
  each other. The relay only ever holds ciphertext.

> **Honest dependency:** the *fully drawn* design (device = MLS leaf, revocation = MLS Remove
> commit re-key) needs **MLS**, which is itself not yet built (the engine currently seals a
> fresh content key per recipient via the hybrid KEM — see `ARCHITECTURE.md`). Phases 1–4 are
> built on **today's** engine and deliver real live multi-device sync; Phase 5 upgrades the
> secrecy guarantees once MLS lands. Nothing in 1–4 has to change when 5 arrives.

A user is **one account identity** with a set of **authorized devices**, each holding
its *own* key. No private key is ever copied between devices. This gives "receive on
all my devices" plus instant revocation of a lost one — without ever changing who you
are to your contacts.

## The key hierarchy

```
Account identity key  (long-term; represents you to contacts; escrowed for recovery)
        │ signs
        ├── Device credential  →  iPhone   device keypair
        ├── Device credential  →  MacBook  device keypair
        └── Device credential  →  Web      device keypair
```

- **Account identity key** — the long-term key contacts pin (from the first QR/link
  verification). It signs device credentials and signed device-list updates. It is
  *not* needed for day-to-day messaging (devices use their own keys), so it can stay
  escrowed (passphrase-encrypted in the user's own iCloud Keychain, per D2) and only
  be unlocked when linking or revoking a device. Signed with the hybrid signature
  (Ed25519 + ML-DSA).
- **Device key** — generated on-device, never leaves it (Secure Enclave on Apple).
- **Device credential** — `{account_id, device_pubkey, device_name, created_at}`
  signed by the account identity key. Proves "this device is authorized by this
  account."

## Per-device transport identity (why your devices don't collide)

iroh discovery is **one-owner-per-id**: two devices publishing under the same account node id
collide, and the loser becomes unreachable. So the **account seed is the identity only** — the
signing key and the contact card friends pin — and is **never used as a transport address**.
Instead, each running client instance takes its **own per-device transport id** (derived from a
per-install `DeviceKeyStore` seed via `useDeviceIdentity`) and hosts its relay/mailbox on that id.
Friends reach each of a user's devices through the circle's relay list (the set of these ids),
learned from the device roster. Sealing stays account-based, so any of the user's devices can open
account-sealed content regardless of which transport id it is currently using.

## Own-device event convergence (the bug that broke device-to-device sync)

The epoch group-keying overhaul (see [`GROUP-KEYING.md`](GROUP-KEYING.md)) had each device run its
**own** epoch sequence, and `ensure_epoch` mints a **random** epoch key per epoch. That meant a
user's iPhone and Mac each generated a *different* key for the same circle+epoch. A naive "keep my
existing key, ignore the other" merge kept each device's stale key and refused its sibling's — so a
device could never open its own other device's events, and every self-forwarded post/DM buffered
forever ("my Mac never shows my iPhone's latest post / a received DM").

The fix is **deterministic convergence**: when a device receives a KeyCommit it authored itself
(same node id), it adopts the **numerically-larger** epoch key and circle secret. Because both
devices pick the same winner independently, they converge without coordination; adopting a new key
counts as "new" so buffered events drain and future re-seals use the agreed key. Received friends'
events are re-broadcast to the user's own devices as **self-sealed forwards** (author preserved,
sender = me), which the ingest path now accepts. This lives in the shared core
([`receive_key_commit`](../core/p2pcore-ffi/src/lib.rs) / `receive_epoch_event`), so iOS, macOS,
Android, and desktop all inherit it.

## Linking a new device (no PII)

1. New device generates its keypair and shows a QR / short code.
2. An already-authorized device scans it; both screens display a **short verification
   phrase** the user confirms (out-of-band check so a relay can't inject a rogue
   device).
3. The authorizing device issues a **signed device credential** for the newcomer.
4. It publishes an updated, account-signed **device list** including the newcomer, and
   rotates the circle epoch so the new device gets a KeyCommit it can open
   (`core/p2pcore-ffi/src/lib.rs:1960`).
5. Contacts' clients see a device whose credential chains to the **pinned account
   key** → trusted automatically, optionally with a transparent *"Blaine linked a new
   device (MacBook)"* notice (iMessage-style).

## Receiving on all devices (how it actually works today)

> **This is not MLS.** MLS is **not implemented** — there is no `mls-rs` dependency and no
> MLS code in the tree; it appears only in comments describing future work
> (`core/p2pcore/src/social.rs:14-16`, `device.rs:13-17`). The description below is the
> mechanism that actually ships. The MLS design this doc originally described is a *plan*
> (Phase 5), and D3's rationale for eventually preferring a PQ variant still stands — see
> `GROUP-KEYING.md`.

Each circle has an **epoch key**. When sealing, the recipient set is expanded from circle
members to each member's **authorized devices** (`recipients_with_devices` in
`core/p2pcore-ffi/src/lib.rs`), and the epoch key is wrapped to every device bundle with the
hybrid KEM. So a message is decryptable by **all** of the user's authorized devices. This is
multi-recipient public-key encryption — it works, it's tested, and it gives cryptographic
revocation, but it does **not** give per-message forward secrecy or post-compromise security.

## Live device-to-device delivery (Phase 4b)

Own-device sync is mailbox-mediated: a device writes to its slot / the circle mailbox, and its
siblings find out **on their next poll** — ~120s on iOS, 30s base on Android/desktop (stretching to
180s when idle). Correct, durable, and slow enough to feel broken when both devices are sitting on
the same desk.

Live delivery closes that gap: on authoring an event, a device also hands it **straight to its own
other devices** over iroh ([`livedelivery::deliver_to_own_devices`](../core/haven-net/src/livedelivery.rs)).
Note the client fan-out lists deliberately *exclude* self (`dialTargets`), because they're built for
reaching contacts — so before this, your own devices had no direct path at all and depended on the
poll (or, on iOS only, an APNs wake).

**It is an optimisation, and never a replacement.** The mailbox put stays unconditional:

- **The sender cannot know the recipient set.** A device that's offline now, or linked tomorrow, can
  only ever be served by the durable mailbox. "I reached both devices I know about" is not "everyone
  has it", so a successful live push can never license skipping the put.
- **Absence is not deletion.** A device that missed a live push has learned *nothing* — least of all
  that a record is gone. Everything here converges through the [`selfsync`](../core/p2pcore/src/selfsync.rs)
  CRDT, where a missed message is indistinguishable from one not yet sent and only an explicit,
  newer-stamped tombstone removes anything. Nothing may read "you didn't get it live" as information.
  (This is the same class of bug as the fresh-restored device that had its circles wiped; see
  `safeToTombstone`.)

So the failure mode of the whole path is "the sibling finds out on its next poll, as it always did".
Attempts are bounded (3s per device, 5s total) — something slower than that has already lost to the
poll it was meant to beat, and must not hold a user-triggered post behind iroh's ~30s dial timeout.
Targets are **device** ids only: the account id resolves to no endpoint under per-device transport
seeds (it's a contact handle), and our own id is filtered because dialing yourself loops iroh's path
discovery unboundedly.

**What ordering actually buys.** Phase 4b is sketched as "ordered store-and-forward", but for account
state that oversells it: `AccountState::merge` is commutative, associative and idempotent, so a live
push that arrives out of order, twice, or never converges to the same state anyway. Ordering matters
for the **epoch KeyCommit backlog** — a device must see a commit to hold the key that opens content
sealed under it — and that is a property of the mailbox backlog, not of this path. Live delivery
therefore promises no order and doesn't invent one the engine doesn't need.

Proven by `core/haven-net/tests/live_delivery.rs`: a post reaches a sibling with **no relay node in
the test at all**, and with the direct path dead the identical event still arrives via the mailbox.

## The always-on device as a personal forwarder

> **Design sketch — not built.** This is the second half of Phase 4b and no code implements it. What
> exists today is the live-delivery half above, plus the fact that a Mac can already host the
> ordinary circle relay/mailbox in-process (`enable_relay`), which covers much of the intent below.
> Treat this section as the plan, in the future tense.

An always-on device (typically a **Mac** — a web tab is a weak always-on node) would double
as the user's **personal store-and-forward node**, advancing the $0 goal because it's
infrastructure the user already owns:

- It caches encrypted group traffic and **forwards it to the user's other devices**
  when they come online — complementing or replacing a Haven relay mailbox / BYO
  S3 bucket for *your own* devices.
- It forwards **ciphertext**; it doesn't need to decrypt to relay (though, being your
  device, it legitimately could read its own copy).

**Ordering constraint (applies today, and more strictly under MLS later):** a device must
see each KeyCommit to hold the epoch keys it needs, so the forwarder keeps an **ordered
backlog** — not just the latest — or a long-offline device can't catch up. Only the last 4
epochs are retained (`prune_epoch_keys`), so a device offline across more than 4 rotations
loses the ability to open content sealed in the epochs it missed. If MLS lands (Phase 5),
in-order commit processing becomes a hard requirement rather than a practical one.

## Revocation & recovery

- **Lost/stolen device:** the account key signs an updated device list excluding it, and
  the circle **epoch rotates** so the removed device is not a recipient of any future
  KeyCommit — it can't read content posted after removal (`core/p2pcore-ffi/src/lib.rs:2516`).
  You stay *you*; only that device goes dark. Contacts honor the signed update.
  > ⚠️ **Known limitation — revocation is not yet adversary-proof.** Today a linked device
  > holds a **copy of the account master seed** (that's what `haven-seed:` move-to-device
  > transfers), and the engine still runs under that copied seed rather than under a
  > per-device key. Revoking a device marks it revoked; it does **not** invalidate the seed
  > that device already has. Because device lists merge higher-version-wins
  > (`core/p2pcore/src/device.rs`), a *cooperative* device honors revocation, but an
  > attacker in possession of the seed can sign a fresh, higher-version device list and
  > re-add itself. The "seed-drop that finalizes revocation" is explicitly still to build
  > (`apple/HavenApp/DeviceRoster.swift:11-12`, `:52-54`). **Treat revocation as effective
  > against a lost device, not against a compromised one.** If a device is stolen and you
  > believe the seed is extractable, roll your identity. Closing this is the top item in
  > `ROADMAP.md` → Outstanding.
- **Lost one device, others remain:** revoke as above, link a replacement.
- **Lost all devices:** restore the **account key from escrow** (passphrase + iCloud
  Keychain), then re-authorize fresh devices. This is the one place the account key
  must be recoverable — hence escrow (D2).

## Device-list authentication (anti-rogue-device)

Contacts encrypt to the user's *current* device set, so that set must be trustworthy:
the device list / each credential is **signed by the account key**, contacts **pin**
that account key at first verification, and any new device must present a credential
that chains to it. A malicious relay cannot forge or inject a device. The optional
"new device linked" notices make additions visible to contacts.

## Honest limits

- **Account-key compromise = full-account compromise.** Mitigated by escrow + Secure
  Enclave + keeping it offline-ish (not needed for daily messaging). It is the crown
  jewel; protect accordingly.
- **Long-offline devices** must replay the ordered backlog to catch up (MLS in-order
  commits) — the forwarder/relay must preserve order.
- **Web as always-on is weak** (open-tab / service-worker lifetime limits); native
  desktop is the real always-on node.
