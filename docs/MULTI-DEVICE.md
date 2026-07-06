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
> **Still ahead:** enrollment flow + UI (Phase 2), live device-to-device delivery + a personal
> forwarder (Phase 4), and the MLS leaf/commit hardening for per-message forward secrecy +
> post-compromise security (Phase 5). See **Implementation phases** below.

## Implementation phases (D16)

| Phase | Scope | Where | State |
|---|---|---|---|
| **1. Device-credential trust layer** | Per-device keys; account-signed `DeviceCredential`; versioned signed `DeviceList` (add/revoke, higher-version-wins, rollback defense); verify against the pinned account key. Own-account replicas UNION-merge; where two copies disagree about a revocation the **strictly-newer list's verdict wins**, so `with_self_added`'s explicit (version-bumped) re-authorization propagates instead of a stale copy re-adding the tombstone forever — the roster/epoch-churn flip-flop that kept a device's own id revoked and rotated every circle epoch per launch. Clients must self-register AFTER importing persisted state (the restored roster's higher version clobbers a pre-import self-registration). | `p2pcore::device` | **✅ core done & tested** |
| **2. Enrollment & UI** | FFI export (done): `issue/verify_device_credential`, `sign/verify_device_list`, `device_list_is_authorized`, plus an `AccountStateHandle` object + `seal/open_account_state`. Ahead: QR/short-code link of a new device + out-of-band verification phrase; the authorizing device issues the credential and publishes a new `DeviceList`; "Blaine linked a new device" notice. Per-client (iOS → Android → desktop). | `p2pcore-ffi::multidevice` + clients | 🟡 **FFI export done**; enrollment QR/verify + UI ahead |
| **3. Account-state self-sync** | A per-account state blob (roster, circles, contacts, profile, settings, blocked list, read state, **pinned conversations**) **self-sealed to the account's own devices** and synced via the mailbox; CRDT/LWW merge so devices converge. Gives "my devices show the same thing." Plus **own-device event convergence** (per-device epoch keys converge on the numerically-larger key) so authored/received posts + DMs sync across devices. | `p2pcore::selfsync` + `p2pcore-ffi::receive_key_commit` + relay/nearby channel | ✅ **all platforms**: iOS/macOS + desktop (relay+S3) + Android (relay) converge profile + settings + contacts + blocked + circles + message-pins, and own-device posts/DMs sync |
| **4. Device-aware circle sealing + revocation** | A circle's epoch key seals to each member's AUTHORIZED **device** bundles (`recipients_with_devices`), never a revoked one; receive accepts a member's authorized device as committer/sender; ingest/store signed rosters (rollback-defended) + rotate epochs on add/revoke; rosters ride the sync bundle (`TAG_DEVICE_ROSTER`). | `p2pcore::device` + `p2pcore-ffi` | ✅ **core done & tested** — `linked_device_receives_then_revocation_cuts_it_off` proves a device receives content and revocation cuts it off. App side ahead: enrollment (device keypair + issue credential on link) + Authorized-Devices UI/revoke. |
| **4b. Live delivery + personal forwarder** | Real-time device-to-device push when both are online; an always-on device (Mac) as the user's ordered store-and-forward node, complementing the relay. | `haven-net` + clients | ⏭️ |
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
4. It adds the new device as a **leaf** to all the user's active MLS groups (Add +
   Commit), so it starts receiving immediately.
5. Contacts' clients see a new leaf whose credential chains to the **pinned account
   key** → trusted automatically, optionally with a transparent *"Blaine linked a new
   device (MacBook)"* notice (iMessage-style).

## Receiving on all devices (how it maps to MLS)

Each device is its own **leaf** in every group the user belongs to. MLS encrypts to
all leaves efficiently, so a message is decryptable by **all** of the user's devices.
Adding/removing a device is an MLS Add/Remove commit. This is precisely what MLS was
designed for (chosen in D3), so multi-device is native, not bolted on.

## The always-on device as a personal forwarder

An always-on device (typically a **Mac** — a web tab is a weak always-on node) doubles
as the user's **personal store-and-forward node**, advancing the $0 goal because it's
infrastructure the user already owns:

- It caches encrypted group traffic and **forwards it to the user's other devices**
  when they come online — complementing or replacing a Haven relay mailbox / BYO
  S3 bucket for *your own* devices.
- It forwards **ciphertext**; it doesn't need to decrypt to relay (though, being your
  device, it legitimately could read its own copy).

**Honest MLS constraint:** MLS requires each device to process group changes
(commits) **in order** to stay in sync. So the forwarder must keep the **ordered
backlog** of handshake + application messages — not just the latest — or a
long-offline device can't catch up. This is the standard MLS "delivery service" role,
which our store-and-forward layer (D15) already plays.

## Revocation & recovery

- **Lost/stolen device:** the account key signs an updated device list excluding it;
  an MLS Remove commit re-keys the groups (post-compromise security — the removed
  device can't read anything after removal). You stay *you*; only that device goes
  dark. Contacts honor the signed update.
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
