# Seed-drop: making device revocation adversary-proof (D16 Phase 2)

> **Status — shipped in 1.0.7 (S2–S5 core); this document is the design it was built from.** It began
> as the implementation plan for what was then the top outstanding security item in `ROADMAP.md` and
> the "revocation is not adversary-proof" finding in `docs/SECURITY-AUDIT-2026-07.md` (R2/R3). Both are
> now closed: per-device keys, seedless enrollment, the gated retirement of the bare account-key seal,
> and self-sync re-keying on revocation all ship, with onboarding UI on iOS, macOS, Android and
> desktop. Read the sections below as the design of record, not as pending work — the client
> enable-sequence and the per-circle gate that governs activation are in `docs/SWITCH-FLIP-1.0.7.md`.
>
> **Mandate (from the maker, 2026-07):** seed-drop is **mandatory for a near-term release** and must
> be a **proper cryptographic fix**, not "advisory revocation with better docs." The upgrade must be
> **graceful and in-place** — no re-onboarding, no new identity, no flag day, no loss of circles,
> history, or contact with un-upgraded peers. Those are hard requirements, and the migration design
> below is the core of this plan, not a caveat.

---

## 0. TL;DR

**The gap this closed.** Before 1.0.7, every one of a user's linked devices held a **copy of the
account master seed** and the engine ran under it. Revocation marked a device revoked in a signed
`DeviceList`, but the seed it already held kept decrypting everything, and — because the roster's
authority *is* the account key — a seed-holder could sign a fresh higher-version `DeviceList` and
re-add itself. Revocation was therefore real against a **lost** device (honest holder stops) and
**advisory** against a **compromised** one (attacker extracted the seed).

**Seed-drop closes it by re-rooting day-to-day operation on per-device keys.** After migration a
non-primary device holds only its own device keypair plus an account-signed `DeviceCredential`; it
**authors and signs under the device key**, contacts **verify the device→account credential chain**,
content **seals to authorized device bundles and no longer to the bare account key**, and the master
seed lives on **exactly one primary device (Secure-Enclave-wrapped) plus the SE-wrapped iCloud-Keychain
escrow** for recovery. A revoked device's key is then cut off by epoch rotation, and a seedless device
**cannot forge a higher-version roster** because roster authority is the account key it no longer holds.

**How it was staged.** The foundation already existed when this plan was written — per-device keys,
account-signed credentials, versioned rollback-defended `DeviceList`s, device-bundle sealing,
**dual-open**, per-device transport, and account-state self-sync. Five pieces were named as the
remaining work, and **all five shipped in 1.0.7**: (a) **move the signer** from the account key to the
device key with credential-chain verification on the receive side; (b) **gate off the unconditional
account-key seal**; (c) **hand each device the self-sync key without the seed**; (d) **stop shipping
the seed** at link time; (e) a **capability-negotiated, absence-safe migration** that keeps 1.0.x peers
readable throughout.

---

## 1. The identity root as it exists today (traced)

### 1.1 One seed, three derived capabilities

Everything roots in the 32-byte **account master seed**. `Identity::from_seed`
(`core/haven-p2p/src/identity.rs:161`) HKDF-expands it into Ed25519 + ML-DSA-65 signing keys, an X25519
secret, and an ML-KEM-768 decapsulation key. From that one seed hang exactly three primitives that the
rest of the app consumes:

- **`Identity::sign`** — hybrid Ed25519+ML-DSA signature (`identity.rs:216`).
- **`Identity::node_secret_bytes`** — the Ed25519 half, used as the transport/relay-auth key
  (`identity.rs:190`).
- **`Identity::self_sync_key`** — a symmetric key HKDF'd from the seed, identical on every device that
  holds the seed and derivable by no one else (`identity.rs:198`).

A `HavenId` public bundle (`identity.rs:45`) carries **both** the signing keys **and** the KEM
encryption keys (`kem_x`, `kem_pq`). This matters for §4: a device bundle already exposes everything
needed to seal to it — **there is no missing encryption key to add.**

### 1.2 `st.me` is always the account; `st.device` only opens

In the engine, `HavenSocial`'s `me: Identity` field (`core/haven-ffi/src/lib.rs:1195`,
constructed `:1544`) is **always the account identity built from the master seed**. The
`device: Option<Identity>` field (`:1199`, set by `use_device_identity` at `:1565`) is used **only to
open/decapsulate** — it never signs or authors (open sites: `:1293`, `:1414`, `:2401`, `:2467`,
`:2508`). So today **every** signing/authoring/sealing path consumes the account key. That single fact
is the blast radius.

### 1.3 Blast radius — every account-seed consumer

Grouped by the capability each consumes. This is the list seed-drop must re-point at the device key
(sign paths) or otherwise sever from the seed (self-sync, seed transfer).

**A. Signs with the account key (`Identity::sign`, hybrid):**

| What | Site |
|---|---|
| Device credential issue | `core/haven-p2p/src/device.rs:75`; FFI `multidevice.rs:38`, `lib.rs:2098` |
| Device list sign / union-merge re-sign | `device.rs:182`, `:224`; FFI `multidevice.rs:63`, `lib.rs:2091`, `:2714+` |
| Social event / bytes envelope sign | `social.rs:201` (`seal_event`), `:228` (`seal_bytes`) |
| **Production post/DM authoring** (epoch-sealed) | `groupkey.rs:205` (`seal_event_in_epoch`); called `lib.rs:2672` (author), `:2204` (backfill re-seal) |
| **Key commit committer** | `groupkey.rs:84` (`seal_key_commit`) via `seal_bytes`; committer is `st.me` at `lib.rs:2181` |
| Signed profile card | `lib.rs:1695` (`my_signed_profile`, `st.me.sign`) |
| Push-registration signature | `lib.rs:165` (`sign_push_registration`, Ed25519 half; worker verifies vs account node id) |
| Signed notification payload | `lib.rs:2317` (`seal_signed_notification`, `st.me.sign`) |
| WebRTC call-frame signature | `lib.rs:2341` (`seal_call_frame`, `st.me.sign`) |

**B. Binds the transport / relay-auth (Ed25519 `node_secret_bytes`):**

| What | Site | Note |
|---|---|---|
| iroh node / discovery record | `lib.rs:915` (`HavenNode::start` → `Node::spawn`) | **Already per-device at runtime** — the app passes the device seed via `useDeviceIdentity` (`apple/HavenApp/FeedView.swift:148`); the account seed is used only as the trust anchor, not the transport address (`docs/MULTI-DEVICE.md:109-118`). |
| Relay HTTP auth header | `httprelay.rs:127` (`auth_header`); FFI `lib.rs:434` (`http_auth_header`) | **Already device-keyed on Apple** — `apple/HavenApp/SharedStore.swift:510` passes `DeviceKeyStore.deviceAccount().secretSeed()`, not the account seed. The FFI is seed-generic, so audit other platforms, but on Apple this consumer is already outside the account-seed blast radius. |

**C. Derives the symmetric self-sync key from the seed:**

| What | Site |
|---|---|
| `self_sync_key` | `identity.rs:198` |
| Seal / open account-state CRDT | `selfsync.rs:218` / `:228`; FFI `multidevice.rs:180` (`seal_account_state`), `:303` (`open_account_state`) |

> ⚠️ **Critical dependency.** `self_sync_key` is derived from the seed and must be *identical on every
> device*. A seedless device **cannot derive it** and therefore cannot participate in account-state
> self-sync (profile/contacts/settings/blocked/circles/pins convergence — the thing that makes "my
> devices show the same thing" work). Seed-drop **must** deliver this key to devices another way. See
> §4.3 and Stage 3.

**D. Opens (decapsulates) with the account seed — requires the seed present, doesn't sign:**

`open_sealed_with_seed` (`lib.rs:270`), `open_signed_notification_with_seed` (`lib.rs:357`), and the
`st.me` fallback openers (`:1293`, `:1414`, `:2401`, `:2467`, `:2508`). These are why history stays
readable; they are *not* a problem to sever — the seed-holding primary keeps them, and seedless devices
replace them with device-key opens (which already work — see §1.4).

**E. Ships the raw seed to other devices (the thing to stop):**

- `AccountStore.transferCode()` (`apple/HavenApp/AccountStore.swift:123-131`) base64-encodes
  `secretSeed()` into `haven-seed:` / `haven-link:` QR; consumed by
  `restore(fromTransferCode:)` (`:135-167`), which installs it as the new device's authoritative seed.
- `SharedSeed.write` (`apple/Shared/SharedSeed.swift:46-55`) mirrors the whole seed (SE-wrapped) into
  the shared app-group keychain so the Notification Service Extension can decrypt pushes.

### 1.4 What is already built (this is not a from-scratch identity system)

Tracing corrects any impression that Phase 2 is greenfield. Shipped and tested today:

- **Per-device keys + account-signed credentials + versioned signed rosters** with higher-version-wins
  adoption, 2P-set union merge for own-account replicas, and "newer verdict wins" revocation defense
  (`core/haven-p2p/src/device.rs` in full; tests `:435-670`).
- **Device-bundle sealing already works.** `recipients_with_devices` (`device.rs:350`) expands members
  to authorized device bundles and drops revoked ones; `revoked_device_cannot_open_the_key_commit`
  (`device.rs:641`) proves an authorized device opens a commit and a revoked one cannot.
- **Dual-open is implemented and tested.** The engine tries the device key then falls back to the
  account key on every open path; `device_identity_dual_opens_old_account_and_new_device_sealed`
  (`lib.rs:3421`) proves a device opens *new* device-sealed content while *old* account-sealed content
  stays readable — this is the migration's readability guarantee, already green.
- **The LOST-device baseline test passes.** `linked_device_receives_then_revocation_cuts_it_off`
  (`lib.rs:3380`) proves a linked device receives content and that after revocation + epoch rotation it
  is not a recipient of the new key commit. It does **not** prove the compromised case, because the
  revoked device in the test never had the seed. Seed-drop's headline test is the compromised sibling
  of this one (§7).
- **Per-device transport, live device-to-device delivery, and account-state self-sync** are all shipped
  (`docs/MULTI-DEVICE.md`).

**So the residual gap is exactly three things**, and everything below is about closing them without
breaking a live install base:

1. `recipients_with_devices` **always** adds the bare account key as a recipient (`device.rs:362-364`),
   so any seed-holder opens everything regardless of the roster.
2. Linked devices **hold the seed** and the engine **signs as the account** (`st.me`), so a device is
   cryptographically the account — a device key is additive decoration.
3. Roster authority **is** the account key, so a seed-holder can re-sign a higher-version roster and
   re-add itself.

Corollary correction to the threat model: the audit's "always seals to the account key" is accurate
(`device.rs:362`), but the surrounding machinery (device sealing, dual-open, revocation-by-rotation) is
**more built than "future work" implies**. The fix is a re-rooting of *who signs* and *what we seal to*,
riding rails that already exist — not a new crypto stack.

---

## 2. What the account key becomes, and where the master seed lives

After seed-drop the **account key is a root-of-trust that authorizes devices and anchors identity to
contacts** — it is *not* used for day-to-day messaging. This is exactly what D16 decided originally
(`docs/DECISIONS.md:280-307`: "one account identity with per-device keys… the account key is the crown
jewel… not needed for daily messaging… escrowed for recovery"). Seed-drop realigns the *implementation*
with the *decision already on record*.

The account key is needed for exactly four operations, all rare and user-initiated:

1. Authorize a new device (issue a `DeviceCredential`).
2. Revoke a device (sign a higher-version `DeviceList`).
3. Rotate/replace the primary.
4. Recover after total device loss.

**Recommendation: the master seed lives on exactly one PRIMARY device (Secure-Enclave-wrapped,
device-local, non-synchronizable) plus the existing SE-wrapped iCloud-Keychain escrow for recovery.
Every other device is seedless.**

Options weighed:

| Where the seed lives | Recovery | Exposure | Verdict |
|---|---|---|---|
| **(1) One primary device (SE-wrapped) + iCloud-Keychain escrow** | Restore escrow to any device; primary is re-designatable | One device holds it at rest instead of all of them; escrow is the only synced copy and is opt-in + passphrase-gated (D2) | **Recommended.** Minimal delta over today's machinery; matches D16 + D2; the primary is a single, user-known authorizer. |
| **(2) Escrow-only; primary unwraps on demand** | Same escrow path | Strongest at rest (no device holds it persistently) but the seed still transits into primary memory to authorize, and each authorize needs an iCloud-Keychain unlock | Good **long-term hardening**; fold in at Stage 6, not required for the security win. |
| **(3) Threshold / split (k-of-n)** | Complex; needs multiple live devices to authorize | Best compromise resistance | **Reject.** No server to hold a share, huge UX + code complexity, and the $0/serverless mandate (`project_haven_distribution`) makes a robust threshold ceremony impractical. Overkill for the threat. |

**Why (1).** The whole point of seed-drop is that a *stolen non-primary device yields a revocable
device key, not the master*. That is fully achieved when the seed lives on one primary + escrow. Moving
the primary to escrow-only-unwrap (2) hardens the *primary's* at-rest posture but does not change the
revocation guarantee for the other devices, which is the finding we must close. So (1) delivers the
security result now; (2) is a follow-on. The residual — **primary compromise = full-account
compromise** — is inherent to any single-root design and is exactly the "crown jewel" trade-off D16
already accepts and documents (`DECISIONS.md:303-307`). We shrink its attack surface from *N devices*
to *one device the user knows is special*, and §6 gives the recovery/rotation story that makes losing
or suspecting the primary survivable without identity loss.

The escrow machinery already exists: `AccountStore.storeHistory` writes a synchronizable, plaintext (or
SE-wrapped-local) recovery archive to iCloud Keychain when the user opts into backup
(`AccountStore.swift:411-433`), and `previousIdentities` reads it back (`:438-455`). Recovery = restore
the seed from that archive onto a fresh primary. Nothing new is needed for recovery except UI wording
(§6).

---

## 3. Migration — the graceful, in-place, no-flag-day upgrade (the core of this design)

This is the section the mandate makes central. The constraint: an existing user, mid-conversation, on a
device that holds the seed, with real circles and real history, and with contacts still on 1.0.4, must
end up holding only a device key + credential **without losing identity, circles, history, or reach**,
and **without ever wiping anything on an absence signal**.

### 3.1 The three invariants the migration must never violate

1. **Old content stays readable forever.** Content sealed to the account key before migration must keep
   opening. The seed-holding primary opens it natively; seedless devices open it because the migration
   hands them the account *decapsulation* material too (§3.4) — or, more simply, because the primary
   re-seals history under the epoch keys the device already holds. Dual-open (`lib.rs:1293` etc.) is the
   mechanism and it is already green.
2. **Absence is never deletion.** Not seeing a roster entry, not seeing a capability flag, not seeing a
   sibling's state — none of these may drop a device, wipe a circle, or delete the seed. This codebase
   has been bitten by absence-as-removal repeatedly (`reference_selfsync_absence_tombstone`,
   `reference_haven_removal_lww`, `reference_es_rclone_conf_tombstones`; and `MULTI-DEVICE.md:186-191`
   spells out the fresh-restored-device-wiped-its-circles class). Every transition here is an
   **explicit, stamped, additive** local decision. In particular, **a device deletes its own seed only
   after it has positively proven** (to itself) that it can author and open under its device key and
   that its credential is live in the account's roster — never because it "looks migrated."
3. **A dropped seed is a one-way, local, deliberate act.** Seed deletion is gated behind (a) the device
   being non-primary, (b) a live account-signed credential for its device key present in the
   highest-version roster it has seen, (c) a successful self-authored+opened round-trip under the device
   key, and (d) the account advertising seed-drop capability for long enough that the device has synced
   at least one post-capability roster. It is idempotent and re-entrant: a crash mid-migration leaves the
   seed in place and retries.

### 3.2 The graceful-upgrade path, step by step

For an **already-linked device that holds the seed** (the hard case; a brand-new link is the easy case
covered by Stage 4):

1. **Adopt the device key (already wired).** On upgrade the device calls `use_device_identity` with its
   `DeviceKeyStore` seed (`lib.rs:1563`; Apple already does this at `FeedView.swift:148` for transport).
   Now `st.device` exists.
2. **Self-register + get a credential from the primary.** The device self-registers its device id into
   the roster (`with_self_added`, `lib.rs:2091`) and, via the existing type-24/25 enrollment handshake
   (`FeedView.swift:1566-1641`), obtains an account-signed `DeviceCredential` for its device bundle.
   Exactly one device is the **primary** (the seed-holder that signs the roster); the enable/step-down
   UI for choosing it already exists (`DeviceRoster.swift:156-203`).
3. **Contacts learn the roster + capability.** The device's roster and a new **seed-drop capability
   flag** (§5) ride the sync bundle (`TAG_DEVICE_ROSTER`, `lib.rs:2160`) and the signed profile
   (`my_signed_profile`, `lib.rs:1695`). Contacts now know to seal to this account's device bundles and
   that it can *author* under a device key.
4. **Switch authoring to the device key.** New posts/DMs/commits sign under `st.device`, with the
   author field still the account id and the sender field the device id; the credential proves the
   binding (§4.2). Old account-signed content is untouched.
5. **Retire the account-key seal for this member** once §5's negotiation says every device in the circle
   is seed-drop-capable.
6. **Deliver the self-sync key to the device** sealed to its bundle (§4.3), so it keeps converging
   account state without the seed.
7. **Drop the seed** — only on non-primary devices, only after 3.1's four gates hold. The device
   deletes its `AccountStore` seed and its `SharedSeed` mirror (replacing the NSE's decrypt path with a
   device-key path — §4.4). The primary keeps the seed (SE-wrapped) + escrow.

The primary itself **keeps the seed** — it is the authorizer and the recovery root. "Seed-drop" is
literally: *every device except the one designated primary stops holding the master seed.*

### 3.3 One-paragraph migration strategy

Already-linked devices keep their seed and keep reading account-sealed history throughout (dual-open is
already green); on upgrade each adopts its device key (already wired) and self-registers a credential
from the single user-designated primary (enable/step-down UI already exists), then contacts — learning
the roster and a new seed-drop capability flag that rides the existing sync bundle and signed profile —
begin sealing to device bundles while the account-key seal continues in parallel for any circle
member still on 1.0.x; authoring moves to the device key with the author≠sender credential-chain
verification the codebase already uses for self-forwards; the self-sync key is handed to each device
sealed to its device bundle at enrollment so a seedless device keeps converging; and finally, and only
on non-primary devices, the seed is deleted **after** the device positively proves a device-key
author+open round-trip and sees its own live credential in the highest-version roster — never inferred
from any absence — with the account-key seal path retired per-circle only once capability negotiation
confirms every member device has upgraded. Nothing is a flag day, nothing re-onboards, and a device
that never upgrades or is offline throughout simply keeps working on the account-key path.

### 3.4 Offline devices, and old-app-version devices

- **A device offline during the transition** keeps its seed and its account-key seals; when it returns
  it sees the higher-version roster and the capability flag, runs the same idempotent steps, and
  migrates then. It is never dropped for having been absent (invariant 2).
- **A device on an old app version (1.0.x)** never learns the capability flag and never authors under a
  device key. Its peers keep sealing to it via the account-key fallback (§5). It reads seed-drop devices'
  content because those devices *also* seal to the account key until §5 says the whole circle has
  upgraded. It is fully functional; it simply does not get the revocation guarantee until it updates.
  This is the cross-version coexistence contract, specified in §5.

---

## 4. Sealing, signing, and the self-sync key under seed-drop

### 4.1 Sealing: gate off the bare account key

`recipients_with_devices` (`device.rs:350`) must change from *always* pushing the account key
(`:362-364`) to pushing it **only when at least one circle member lacks a seed-drop-capable roster**.
Concretely: keep the account key as a recipient for members with **no known roster** (pre-multidevice
peers keep working — the existing fallback at `:375`), and for members whose roster exists but who have
**not** advertised seed-drop capability. Drop it for a member once **all** members of the circle are
seed-drop-capable and every device is enrolled. This is the one-line-in-spirit change that turns
"advisory" into "cryptographic," but its *gating* is the whole §5 negotiation — do not ungate it
prematurely or a legacy device goes dark.

Device bundles already expose the full hybrid-KEM material (`kem_x` + `kem_pq` in `HavenId`), and
`seal_key_commit` already KEM-wraps the epoch key to each recipient bundle (`groupkey.rs:84` →
`social::seal_bytes` → `encapsulate_to` per member, `social.rs:214`). **No new device encryption key is
needed.** The audit's open question "does the device have a published encryption key or only a signing
key?" resolves to: **it has both, the full bundle.** That is a real scope reduction.

### 4.2 Signing: move the committer/author to the device key, verify the chain

This is the deepest change and the one with the most surface. Today `seal_key_commit(&st.me, …)`
(`lib.rs:2181`) and `seal_event_in_epoch(&st.me, …)` (`lib.rs:2204`, `:2672`) sign with the account
key. Under seed-drop a seedless device has no account private key, so:

- **Sender/committer becomes the device identity** (`st.device`), and the envelope carries the device
  id in its `sender` field (it already does — `groupkey.rs:201` writes `sender.public().node_id_bytes()`).
- **The receive side must accept a device-signed envelope whose sender is an authorized device of the
  claimed author.** The template already exists: `open_event_in_epoch`'s `allow_forwarded` path
  (`groupkey.rs:211-228`) already decouples `author` from `sender` for own-device self-forwards. Seed-drop
  generalizes this to *contacts'* devices: resolve `sender` → the account whose roster authorizes that
  device id (via `ContactDevices`/`DeviceCredential` already verified against the pinned account key at
  ingest, `lib.rs:2751+`), then require `author == that account` and the credential live in the current
  roster. The verification data (`device_lists`, credentials chained to pinned account keys) is already
  maintained; the change is to *use* it as the sender-authorization oracle instead of matching a single
  `sender_pub`.
- **Key commits** likewise are signed by the device and verified by chaining the committer device id to
  the author account. `open_key_commit` (`groupkey.rs:88`) takes a `committer_pub`; the caller must
  resolve it from the roster rather than assuming the account key.
- **Profiles, signed notifications, call frames** (`lib.rs:1695`, `:2317`, `:2341`) move to device
  signing + credential chain on the same pattern. **Push registration** (`sign_push_registration`,
  `lib.rs:165`) is special: the push worker verifies against the *account node id*. Either the primary
  continues to register (it holds the seed), or the worker is taught to accept a device-signed
  registration whose credential chains to the account (a worker change, `push/worker.js`). Simplest for
  the first release: **the primary owns push/VoIP registration**; seedless devices register their own
  token under a device-signed registration once the worker supports it (later stage).

> 🔴 **Residual to call out.** Until the *verify* side (contacts) accepts device-signed content, a
> seedless device that authors under its device key is unreadable by anyone who hasn't upgraded the
> verification path. This is why §5's capability negotiation is a **hard gate on switching the signer**,
> not just on dropping the account-key seal. A device must keep signing under the account key (i.e. keep
> the seed, or have the primary counter-sign) until its audience can verify device signatures. The
> clean sequencing (Stage 1 ships verify-side to *everyone* before Stage 5 drops seeds) is what removes
> this residual.

### 4.3 The self-sync key handoff (the non-obvious blocker)

A seedless device cannot derive `self_sync_key` (§1.3). Fix: **treat the self-sync key as a piece of
account secret material delivered to each authorized device sealed to its device bundle**, exactly like
an epoch key is delivered in a `KeyCommit`. At enrollment (or in a dedicated self-sealed slot), the
primary KEM-wraps the 32-byte `self_sync_key` to the new device's bundle; the device stores it and uses
it for `seal_account_state`/`open_account_state` (`multidevice.rs:180`, `:303`) instead of deriving it
from a seed it no longer has. The key is unchanged and identical across devices, so convergence is
untouched; only its *provenance on a given device* changes from "derived" to "granted." This rides the
same hybrid-KEM-to-device-bundle rail as everything else and needs no new crypto.

### 4.4 The Notification Service Extension

The NSE decrypts push payloads using the shared-group seed mirror (`SharedSeed`,
`PushManager.swift:157`). A seedless device has no seed to mirror. Options: (a) mirror the **device**
key into the shared group and seal notifications to the device bundle (payloads already sealed
per-recipient — `seal_signed_notification`, `lib.rs:2317` — so sealing to the device bundle is natural);
or (b) keep a *purpose-scoped* SE-wrapped notification-open key in the shared group that is not the full
seed. (a) is cleaner and consistent with device-bundle sealing. Either way the full-seed mirror
(`SharedSeed.write`) is retired on seedless devices.

---

## 5. Cross-version coexistence (hard constraint)

1.0.4 is live; a seed-drop device and an account-key-seal device share circles for months. The interop
contract:

### 5.1 Capability negotiation

Add a **seed-drop capability marker** to two places peers already exchange:

- the **signed profile card** (`my_signed_profile`, `lib.rs:1695` — extend the `{n,b,l,a,e}` payload
  with a versioned capability field; it is account-signed so it can't be forged), and
- the **device roster bundle** (`encode_roster`/`TAG_DEVICE_ROSTER`, `lib.rs:2160`), so capability is
  learned even before a profile refresh.

A device advertises `seedDrop=v1` once it (a) can author under its device key and (b) can *verify*
device-signed content from others (i.e. it has the Stage 1 verify path). Capability is **monotonic and
signed** — it can only be learned, never inferred-absent, so a missing marker means "assume legacy," never
"downgrade."

### 5.2 The dual-seal transition window

During the window, a seed-drop device **seals both ways**: to authorized device bundles **and** to the
account key, so:

- an **old (1.0.x) contact** opens it via the account key (their only path), and
- a **new contact** opens it via its device key, and revocation bites on the device-key path.

Reciprocally, an old device seals only to the account key, which every seed-drop device can still open
(the primary holds the seed; seedless devices were granted account decap material or the primary
re-seals — §3.1 invariant 1). So **everyone reads everyone** throughout. The cost is that during the
window the account-key path remains open, so revocation is not yet cryptographic *for that circle* —
which is fine and expected until the circle fully upgrades.

### 5.3 When the account-key seal retires (per circle)

The bare-account-key recipient is dropped for a circle **only when every member's roster is known and
every member advertises `seedDrop≥v1`, and every device in every member's roster is enrolled with a
live credential.** This is an **all-present positive signal**, never an absence: we retire the legacy
path only when we have affirmatively seen capability from everyone, not when we fail to see a legacy
marker. A single un-upgraded member keeps the whole circle on dual-seal. Users get a subtle "everyone's
on the secure version" indicator; there is no hard cutoff that could strand a straggler. If a new legacy
device joins later, the circle re-enters dual-seal (capability is per-current-membership, recomputed on
roster change).

> This is the same shape as the epoch-rotation-on-membership-change logic already in place, so it slots
> into `ensure_epoch`/`rotate_if_stale` (`lib.rs:2142-2144`) rather than being a new subsystem.

---

## 6. Recovery, and reconciling with the SE-wrapped escrow

- **Lose a non-primary device:** revoke it from the primary; rotate the epoch (already the flow). Its
  device key is cut off cryptographically, and it never held the seed, so there is nothing to extract —
  **this is the whole point, and it now holds for a compromised device, not just a lost one.**
- **Lose the primary (but have another device):** promote another device to primary by restoring the
  seed from the SE-wrapped iCloud-Keychain escrow (`previousIdentities`/`storeHistory`,
  `AccountStore.swift:411-455`) onto it, then revoke the old primary. Because the escrow is the seed,
  the new primary is fully the account. The old primary, if compromised, still held the seed until it
  was lost — so **primary compromise remains full compromise** (the inherent crown-jewel risk), and the
  honest guidance for *a primary you believe was extracted* is still "rotate identity." Seed-drop shrinks
  the set of devices for which that's true from "all of them" to "the one primary."
- **Lose all devices:** restore the seed from escrow onto a fresh device, which becomes the new primary;
  re-authorize replacements. Unchanged from D16's recovery story (`MULTI-DEVICE.md:252-255`).
- **`.seError` / locked reads stay "never overwrite."** The existing four-state `loadSeedStatus`
  (`AccountStore.swift:257-309`, and the mirror `DeviceKeyStore.loadSeedStatus`,
  `DeviceRoster.swift:89-103`) already refuses to treat a locked/erroring read as absence. Seed deletion
  in §3 must use the same discipline in reverse: **only delete the seed on a positive, explicit
  migration success**, never as a side effect of a failed read, and the delete is guarded so a transient
  keychain error can never trigger it.

The escrow is what makes "drop the seed from devices" reconcilable with "the user can still come back":
the seed does not vanish, it **concentrates** — onto one primary and the opt-in encrypted backup — instead
of being smeared across every device.

---

## 7. The headline test (proof obligation)

Extend the existing baseline into the compromised case.

- **Baseline (exists, LOST device):** `linked_device_receives_then_revocation_cuts_it_off`
  (`lib.rs:3380`) — a linked device receives content, then after revocation + rotation is not a
  recipient of the new commit.
- **New (COMPROMISED device):** `revoked_seedless_device_cannot_reenter_or_decrypt`. Construct a device
  that holds **only its device key + credential** (no account seed), authorized in roster v1. Then:
  1. Revoke it (roster v2 by the primary) and rotate the epoch.
  2. Author content after revocation, sealed via `recipients_with_devices` **with the account-key
     recipient gated off** (circle fully seed-drop-capable).
  3. **Assert it cannot decrypt** the post-revocation content with its device key (no epoch key reaches
     it) — the cryptographic cut.
  4. **Assert it cannot re-add itself:** it attempts to sign a higher-version `DeviceList` re-adding its
     id; because it lacks the account key, the list **fails `verify()` against the pinned account key**
     (`device.rs:187`), so no honest peer adopts it. Contrast the current world, where the same device
     *holds the account key* and its forged roster verifies.

Passing both — cut off *and* cannot re-enter — is the definition of the fix. A supporting interop test
must also assert a **legacy (account-key-only) device still reads circle history** throughout, so we
prove we didn't buy revocation by breaking coexistence.

---

## 8. Staged plan and release sequencing

Each stage is independently landable behind a capability flag, with a proof obligation. The stages are
ordered so the **verify side ships to everyone before any device stops signing as the account** — that
ordering is what removes the §4.2 residual.

| Stage | Scope | Proof obligation | Realistic release |
|---|---|---|---|
| **S0. Capability negotiation + dual-seal scaffolding** | Add the signed `seedDrop` capability marker to profile + roster; teach `recipients_with_devices`'s *gating* (compute "circle fully capable") without yet dropping the account key. No behavior change yet. | A seed-drop-flagged device and a legacy device share a circle and both read each other; capability is observed, never absence-inferred. | **1.0.6** (safe, additive, no re-rooting) |
| **S1. Device-signed content + credential-chain verify (receive side to EVERYONE)** | Accept device-signed events/commits/profiles whose sender chains to the pinned account via the roster (generalize `allow_forwarded`). Devices still *sign* as the account. | A device-signed post opens on a contact that validates the chain; an account-signed post still opens; tamper/foreign-signer rejected. | **1.0.6** (receive-side only; ships the verifier ahead of any signer switch) |
| **S2. Self-sync key handoff to device bundles** | Deliver `self_sync_key` sealed to each device bundle at enrollment; open account-state from the granted key. | A device given only the granted key (no seed) converges account state identically. | **1.0.7** |
| **S3. Switch authoring + committing to the device key** | Seed-drop devices author/commit/sign profile+notif+call under `st.device`; dual-seal (device bundles **and** account key) so legacy peers still read. | Device-authored content is read by both new and legacy contacts; own-device sync intact. | **1.0.7** |
| **S4. Seedless enrollment for NEW devices** | New links get a device key + credential + granted self-sync key and **never receive the seed**; replace the `haven-seed:`/`haven-link:` seed transfer with a credential-grant link flow; primary is sole authorizer. | A newly linked device holds no seed, authors+opens, participates in sync, and **cannot** produce a roster that verifies. | **1.0.7** |
| **S5. Seed-drop on EXISTING non-primary devices + retire account-key seal per fully-upgraded circle** | The graceful in-place path (§3.2 step 7): a non-primary device deletes its seed after positively proving device-key operation and a live credential; `recipients_with_devices` drops the account-key recipient once §5.3's all-present signal holds. | **The headline test (§7):** a revoked seedless device can't decrypt post-revocation content and can't re-add itself; legacy device still reads history. | **1.0.7** (the headline of the release) |
| **S6. Hardening follow-ons** | Escrow-only-unwrap primary option (§2 opt 2); device-signed push registration in the worker; NSE device-key path; wire periodic epoch rotation (`ROADMAP.md` Outstanding #2 — the cryptographic cut depends on rotation actually firing); eventual MLS leaf/commit forward secrecy (D16 Phase 5). | Rotation timer fires on each platform; push worker verifies device-chained registrations. | **1.0.8+** |

### 8.1 Which release carries seed-drop, honestly

**Recommendation: 1.0.6 ships the current security fixes plus the safe, additive groundwork (S0–S1);
seed-drop proper lands as the headline of 1.0.7 (S2–S5); hardening rides 1.0.8+.**

Reasoning, from the risk, not convenience:

- **S0–S1 are safe to ship immediately in 1.0.6** because they are strictly additive: a capability flag
  and a *receive-side* verifier. Nothing stops signing as the account, nothing drops a seal, no device
  loses a seed. Shipping the verifier early is what lets 1.0.7 switch signers without stranding anyone —
  by the time 1.0.7 devices sign under device keys, a large fraction of the install base already
  verifies them. This is the single most important sequencing decision and it costs nothing to do in
  1.0.6.
- **S2–S5 must land together in 1.0.7** and not be rushed into 1.0.6, because they re-root the identity:
  they change who signs, what we seal to, how self-sync is keyed, and — in S5 — they *delete master
  seeds from real devices*. A bug in that sequence bricks identities or (via an absence-as-deletion
  slip) wipes circles, in the exact codebase that has hit that class of bug more than once. That work
  needs its own release, its own beta soak, and the headline test green before it ships. Trying to cram
  the re-rooting into the same release as the current security fixes is how a master-key redesign goes
  wrong.
- **The user's "next update" is 1.0.7**, and it can carry seed-drop *done properly* precisely because
  1.0.6 lays the additive rails (S0–S1) that make 1.0.7's switch graceful. That is the honest answer:
  not "later," but "1.0.7, with 1.0.6 doing the groundwork that keeps 1.0.7 from cutting corners."

If S2–S4 prove faster and soak clean in beta, S5 (the seed deletion + account-key retirement) is the
only piece that strictly *must* have the full headline-test gate; S2–S4 could in principle ride 1.0.6 if
their betas are clean, but the safer default is to keep the re-rooting as one coherent 1.0.7 story so the
capability flags flip together and the migration is tested end-to-end as a unit.

---

## 9. What makes this hard (the honest picture)

- **The signer, not just the sealer, moves.** The audit frames the gap around
  `recipients_with_devices`, but the deeper work is that *everything authored is signed by `st.me`*
  (§1.3 group A). Re-pointing that to the device key means every contact must verify a device→account
  chain for every artifact — a receive-side change that has to ship *before* the signer switch or peers
  go dark. This is the crux and the reason S1 precedes S3–S5.
- **Self-sync silently depends on the seed.** `self_sync_key` is seed-derived; a naïve seed-drop breaks
  "my devices show the same thing." Easy to miss, easy to fix once seen (§4.3), but it must be in the
  plan or the first seedless device desyncs.
- **Absence-as-deletion is a live landmine.** Seed deletion and account-key-seal retirement are both
  "stop doing something" transitions, which are exactly where this codebase has resurrected bugs. Every
  such transition here is gated on a *positive* signal and is idempotent/re-entrant; getting that
  discipline wrong wipes identities or circles.
- **Cross-version coexistence has no server to coordinate it.** Capability negotiation is peer-to-peer
  and eventually-consistent, so "the whole circle has upgraded" is an all-present positive computation
  that must tolerate stragglers indefinitely and never hard-cut. Dual-seal is the cost we pay for
  months.
- **Revocation is only cryptographic if the epoch actually rotates.** `ROADMAP.md` Outstanding #2:
  periodic rotation is not wired and rotation only fires on membership/roster change. Seed-drop's cut
  depends on the post-revocation epoch existing, which it does on revoke (rotation is triggered there),
  but the periodic-rotation gap should be closed alongside (S6) so a churn-free circle isn't stuck on
  one epoch.
- **Primary compromise is still full compromise.** Seed-drop shrinks the seed's footprint from N
  devices to one primary + escrow; it does not eliminate a single root of trust. That residual is
  inherent, is the D16-accepted crown-jewel trade-off, and the honest user guidance for a suspected
  *primary* extraction remains identity rotation. Say so; don't oversell.

---

## 10. Corrections to the prior threat-model characterization

Tracing turned up three places where the situation differs from how the audit/docs read at a glance —
recorded here because correcting the model is as valuable as the plan:

1. **Device sealing and dual-open are already built and tested**, not future work. `recipients_with_devices`
   already seals to authorized device bundles and drops revoked ones (`device.rs:375`), and
   `device_identity_dual_opens_old_account_and_new_device_sealed` (`lib.rs:3421`) proves device-key
   opens coexist with account-key opens. The gap is narrowly the *unconditional* account-key recipient
   (`device.rs:362`) plus devices holding the seed and signing as the account — not an absent device-key
   path.
2. **Device bundles already carry encryption keys.** A `HavenId` is the full hybrid bundle (signing +
   ML-DSA + X25519 + ML-KEM), so "seal to the device" needs no new key material. The audit's open
   question here resolves in our favor.
3. **Relay-auth and transport are already device-keyed in the running Apple app.** `http_auth_header` is
   called with the *device* seed (`SharedStore.swift:510`) and the iroh node runs under the device
   transport id (`FeedView.swift:148`). So two items that look like account-seed consumers in the FFI
   are, in practice on Apple, already off the account key. Audit Android/desktop for parity, but the
   Apple blast radius is smaller than the FFI surface suggests.

None of these weaken the finding — the seed still smears across devices and revocation is still advisory
— but they shrink the amount of *new* mechanism seed-drop must invent, which is why a proper fix is
achievable in a single well-soaked release rather than a ground-up rebuild.
