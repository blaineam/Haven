# Seed-drop S4 — Seedless enrollment for NEW devices: implementation plan

Companion to `SEED-DROP-DESIGN.md` §8 stage S4: *"New links get a device key + credential + granted
self-sync key and NEVER receive the seed; replace the `haven-seed:`/`haven-link:` seed transfer with a
credential-grant link flow; primary is sole authorizer."* Written 2026-07-16 against commits
`bdcc199`/`dca6141`/`2c19628`/`920d36a`. File:line references are to that tree.

## 0. Where the tree stands (verified)

- Core S2–S5 primitives are landed: `seal_self_sync_key`/`open_self_sync_key`
  (`core/p2pcore/src/device.rs:505-526`), `SeedDropCapability` (`device.rs:429-485`),
  `circle_fully_seed_drop_capable` + `recipients_with_devices_gated` (`device.rs:534-577`),
  `author_and_bundle_for_device` (`device.rs:399-411`). The S4 core proof exists:
  `s4_seedless_new_device_is_credentialed_but_cannot_forge_a_roster` (`device.rs:1010-1035`) and the
  S5 headline test (`device.rs:1038-1100`).
- FFI wiring: `signer_of` (`core/p2pcore-ffi/src/lib.rs:2925-2931`) signs commits/re-seals under the
  device key gated on `circle_fully_seed_drop_capable` (`lib.rs:2278-2279`, used at `:2309`, `:2332`);
  `set_seed_drop_retire` default OFF (`lib.rs:1617-1619`); receive-side device→account resolution
  (`authorized_device_and_account`, `lib.rs:2938-2953`; consumed at `:1315`, `:1400`).
- **But the FFI is NOT exposing the S2 grant fns**: `core/p2pcore-ffi/src/multidevice.rs` still only
  has seed-taking `seal_account_state`/`open_account_state` (`:179-183`, `:302-307`). No FFI wrapper
  for `seal_self_sync_key`/`open_self_sync_key` exists. S4 must add them.
- `HavenSocial::new` (`lib.rs:1582-1603`) requires the 32-byte account seed; `NetState.me: Identity`
  (`lib.rs:1203`) is the account private identity everywhere.

## 1. Today's link flow end-to-end

**Generation (all carry the raw master seed):**

| Platform | Site | Form |
|---|---|---|
| Apple | `apple/HavenApp/AccountStore.swift:123-131` `transferCode()` | `haven-seed:<b64url(seed)>` or `haven-link:<b64url(JSON{s: seed, r: relays})>` |
| Apple UI | `apple/HavenApp/DeviceLink.swift:69-121` `LinkDeviceView` (link flow, code at `:86`); `:11-63` `TransferIdentityView` (move flow) — reached from `DeviceRoster.swift:321` and onboarding | QR + copy |
| Android | `android/.../core/HavenCore.kt:47` `exportSeedUri()` (`haven-seed:` only, no relays) | Settings QR |
| Desktop | `desktop/src-tauri/src/commands.rs:874-878` parses `haven-seed:`; generation is UI-side (`desktop/ui/app.js`) | code |

Note: `core/p2pcore/src/link.rs` (`HavenLink`, `haven://invite#id.verify`) is the **contact** reach-me
link — a different thing — but its id + 16-byte verification + discovery-fetch pattern is exactly what
the S4 enrollment ticket copies (§3): a full hybrid `HavenId` bundle (~3.2 KB: ML-KEM-768 EK +
ML-DSA-65 VK) does not fit a scannable QR.

**Consumption (new-device onboarding):**

- Apple: `RestoreIdentityView.attempt` (`DeviceLink.swift:237-251`) → `AccountStore.restore(fromTransferCode:)`
  (`AccountStore.swift:135-167`) installs the seed as the device's authoritative identity, then
  `FeedStore.reconfigure(seed:)` and (in linkMode) `requestDeviceEnrollment()` after 1.5 s (`:244`).
- The **existing enrollment handshake** then merely decorates the already-seeded device with a device
  key: type-24 request / type-25 grant / type-26 full-state (`apple/HavenApp/FeedView.swift:1545-1548`,
  `requestDeviceEnrollment :1566-1579`, `handleDeviceEnrollmentRequest :1604-1625`,
  `handleDeviceEnrollmentGrant :1630-1641`, `pushFullStateToMyDevices :1660-1678`). Android mirror:
  `android/.../core/HavenNet.kt:898-940`. Desktop mirror: `desktop/src-tauri/src/engine.rs:826-882`
  (`wire::DEVICE_ENROLL`/`DEVICE_GRANT`).
- Engine boot after linking: Apple `FeedView.swift:133-163` (`HavenSocial(accountSeed:)` at `:135`,
  `useDeviceIdentity` at `:148`, `registerDevice` at `:160`); Android `HavenNet.kt:233-248`; Desktop
  `engine.rs:218-236`.

S4's job: keep the 24/25/26 *rails* (nearby broadcast + directed iroh to the primary), but make the
request self-authenticating (the new device has no seed with which to already "be" the account) and
make the grant carry everything a seedless device needs.

## 2. The seedless engine — constructor and the `st.me` private-key gap inventory

### 2.1 Constructor design

Add to `core/p2pcore-ffi/src/lib.rs`:

```rust
#[uniffi::constructor]
pub fn new_seedless(account_public_bundle: Vec<u8>, device_seed: Vec<u8>) -> Result<Arc<Self>, HavenError>
```

Restructure `NetState` (`lib.rs:1200-1234`) from `me: Identity` to:

- `me_pub: HavenId` — always present (authorship id, contact id, roster verification anchor, `hex(...)` sites).
- `me_secret: Option<Identity>` — `Some` on primary/legacy, `None` on seedless.
- `device: Option<Identity>` — unchanged; **always `Some` on seedless** (enforce in the constructor).

This is deliberately the `Option` refactor, not a `seedless: bool` flag next to a dummy `Identity`:
every account-key use becomes a compile-checked decision, which is the only safe way to sweep ~60
sites. `new_seedless` also seeds `seed_drop_capable` with the account id (mirror of `lib.rs:1594-1598`)
and adopts the device identity internally.

### 2.2 The gap inventory (the critical correctness list)

Every `st.me` private-key operation in `core/p2pcore-ffi/src/lib.rs` + `multidevice.rs`, and what a
seedless device does instead:

**A. Roster authority — primary-only; seedless must hard-refuse:**
1. `register_device` `lib.rs:2191-2218` (`with_self_added`/`DeviceList::signed`/`DeviceCredential::issue`
   with `st.me` at `:2199-2206`) → returns empty on seedless. Clients call this unconditionally on every
   launch (`FeedView.swift:160`, `HavenNet.kt:248`, `engine.rs:232`) — they must skip it in seedless
   mode, and the engine must guard it anyway.
2. `verify_and_store_roster` own-account union-merge **re-sign** `lib.rs:2856-2857`
   (`b.merge(&list, &st.me, ...)`) → seedless replacement: verify + `adopt_if_newer` + credential union
   only, never re-sign. The primary is the sole multi-master resolver.
3. `my_roster_wire` `lib.rs:2960-2963` signs a **fresh `SeedDropCapability` trailer with `st.me` on
   every emit** → a seedless device cannot mint this. Fix: store the primary-signed roster **wire bytes
   verbatim** (from the grant / from sync) in `NetState` + `PersistState`, and rebroadcast those bytes
   at the emit sites (`lib.rs:2283-2286`, `:2176-2183`, `:2007`, `:2215`). Verbatim rebroadcast also
   preserves the capability trailer, which contacts need to mark the account capable.

**B. Content authoring:**
4. `author()` (~`lib.rs:2788-2806`) still calls `seal_event_in_epoch(&st.me, ...)` **unconditionally**
   — the live post/DM path never went through `signer_of`. S4 must route it through `signer_of` with
   the same capable-circle gate; on seedless there is no account fallback, so `signer_of` must resolve
   to the device (and the gate becomes an enrollment/UX precondition — see Risks).
5. `epoch_sync_bundle_inner` commit + re-seal (`lib.rs:2309`, `:2332`) already use
   `signer_of(st, author_under_device)` — but `signer_of`'s fallback branch (`lib.rs:2929`) returns
   `&st.me`; on seedless it must return the device (or error).

**C. Media/legacy sealing (a real S4 blocker, currently invisible because every device holds the seed):**
6. `seal_circle_media` `lib.rs:2538-2548` and `seal_circle_media_file` `:2560-2568` sign with `st.me`
   **and seal only to account bundles** (`members = vec![st.me.public()] + circle.members`). A seedless
   sibling can never open circle media sealed this way. Fix both directions: seal via
   `recipients_with_devices_gated` and sign via `signer_of`; and `open_circle_media`/`open_circle_media_file`
   (`:2584-2598`, `:2617-2644`) must resolve a **device** sender via `authorized_device_and_account`,
   not only members/me.
7. `seal_media` `lib.rs:2410-2435` seals to ONE account bundle by hex. When the recipient hex is a
   device hex (media requests already arrive from device transports), resolve against known device
   bundles too; otherwise a seedless requester can't open chunks.

**D. Account-signed artifacts:**
8. `my_signed_profile` (`st.me.sign(&profile_signing_bytes(...))`, `lib.rs:1760`) → seedless devices do
   not mint profile cards; they cache and rebroadcast the primary's signed card (it already rides
   self-sync/full-state push). Return the cached card or empty.
9. `seal_signed_notification` `lib.rs:2442-2453` and `seal_call_frame` `:2466-2477` (`st.me.sign`) →
   sign with the device key and carry the **device** bundle. Receive side today drops these:
   `FeedView.swift:1505-1517` requires `declared account hex == verified signer hex`. Extend the check:
   accept when `accountForDevice(verified) == declared` (the FFI oracle already exists and is already
   called there as defense-in-depth at `:1514-1516`). Same change on Android/desktop receive paths.
10. Push registration (`Account.sign_push_registration`, `lib.rs:173-178`; the worker verifies against
    the account node id) → out of S4 scope per the design doc: **the primary owns push registration**;
    a seedless device gets no push until the S6 worker change. Document it in the linking UI.

**E. Openers (dual-open account fallback)** — `lib.rs:1326-1332` (commit), `:1458-1461` (legacy event),
`:2530-2531`, `:2596-2597`, `:2637-2638`: on seedless these become device-only (the `.or_else(account)`
arm is simply absent). Safe *provided* C is fixed so everything relevant is sealed to device bundles.

**F. Self-sync (the S2 handoff, FFI still missing):**
11. `multidevice.rs:179-183` / `:302-307` take `account_seed` and derive `self_sync_key`. Add:
    `seal_account_state_with_key(key32, state)`, `open_account_state_with_key(key32, sealed)` (core
    `AccountState::seal/open` already take a bare key — `selfsync.rs:216-228`), plus FFI wrappers
    `seal_self_sync_key_grant(account_seed, device_bundle) -> Vec<u8>` (primary) and
    `open_self_sync_key_grant(device_seed, account_bundle, envelope) -> Vec<u8>` (device) over
    `device.rs:505-526`. Apple callers to branch: `apple/HavenApp/SelfSync.swift:357, 370, 424, 432`.

**G. Transport / relay auth** — already device-keyed everywhere (`FeedView.swift:148, 639, 665-666`;
`SharedStore.swift:510`; `engine.rs:231, 508-509, 2434-2435`; `HavenNet.kt:236, 273, 2425`). No change.

## 3. The enrollment handshake

### 3.1 The link (no seed, QR-sized)

New scheme `haven-enroll:`, encoded/parsed **in core** (new `core/p2pcore/src/enroll.rs`, FFI-exposed)
so all platforms share bytes — the same convergence discipline as `encode_circle_sync`
(`multidevice.rs:209-217`):

```
EnrollTicket {
  account_id:         [u8;32],  // account node id (like HavenLink.id)
  verification:       [u8;16],  // tamper hash of the FULL account bundle (HavenId::verification)
  secret:             [u8;32],  // one-time enrollment secret, CSPRNG, single-use, expiring
  primary_device_hex: [u8;32],  // the primary's device transport id (directed iroh dial target)
  issued_at:          u64,
  relays:             Vec<String>, // bootstrap relays (what haven-link: added for the same reason)
}
```

`haven-enroll:` + base64url(length-prefixed binary) ≈ 150 bytes + relays — comfortably QR-able. The
full account bundle deliberately does **not** ride the link (3.2 KB); it rides the grant and is
tamper-checked against `verification`, exactly the `HavenLink::matches` pattern (`link.rs:100-104`).

### 3.2 Request — new frame type 28 (`SEEDLESS_ENROLL_REQ`)

Built by core `enroll_request_wire(ticket_secret, device_bundle, name, ts)`:

```
ver(1)=1 ‖ lp(device_bundle) ‖ lp(name) ‖ ts(8 LE)
        ‖ mac(32) = blake3::keyed_hash(secret, "haven-enroll-req-v1" ‖ device_bundle ‖ name ‖ ts)
```

Sent over both existing rails: nearby broadcast (the new device advertises the nearby name using the
**account hex from the ticket** — mirroring `FeedView.swift:639`'s `accountPrefix-devicePrefix`
convention — so the primary's mesh discovers it) and directed iroh to `primary_device_hex`. New frame
types (28/29) rather than reusing 24/25 keep this absence-safe: an old primary ignores 28 and the new
device shows "your primary device needs updating"; the old seeded 24/25 path remains for legacy links
during the transition.

Primary-side verification (core `verify_enroll_request(secret, wire)`): MAC valid, ts within window
(e.g. 10 min), ticket unused. The MAC is what today's type-24 path lacks entirely
(`handleDeviceEnrollmentRequest` at `FeedView.swift:1604` accepts any mesh peer) — S4 strictly
improves authorization.

### 3.3 Grant — new frame type 29 (`SEEDLESS_ENROLL_GRANT`)

Built by core `enroll_grant_wire(...)` on the primary after it (a) issues the credential, (b) unions
the device into its roster, (c) seals the self-sync grant:

```
ver(1)=1
‖ lp(account_bundle)     // full HavenId — device checks it against ticket.verification
‖ lp(credential)         // DeviceCredential::to_bytes, account-signed
‖ lp(roster_wire)        // full TAG_DEVICE_ROSTER bytes incl. SeedDropCapability trailer
‖ lp(self_sync_grant)    // SealedEnvelope from seal_self_sync_key (device-bundle-sealed)
‖ lp(relays_json)
‖ mac(32) = blake3::keyed_hash(secret, "haven-enroll-grant-v1" ‖ all previous bytes)
```

New-device acceptance (core `open_enroll_grant(ticket, my_device_identity, wire)`), all-positive checks:
1. MAC verifies; `account_bundle` matches `ticket.{account_id, verification}`.
2. `credential.verify(account)` and `credential.device_id() == my device id`.
3. Roster verifies against the account and `is_authorized(my device id)`.
4. `open_self_sync_key(device, account, grant)` yields 32 bytes.

Only after all four does the client persist and flip into seedless mode. A failed/partial grant leaves
the device in linking mode (idempotent, re-scannable) — never a half-identity.

After the grant, the existing state-sync rails run unchanged: the device sends type-26 (request full
state), the primary answers with type-23 self-sync slot + type-1 re-sealed events
(`pushFullStateToMyDevices`, `FeedView.swift:1660-1678`) — all of which the seedless device can now
open because commits seal to its device bundle and its self-sync opens with the granted key.

## 4. Primary-side authorization flow

1. `LinkDeviceView` (`DeviceLink.swift:69`) forks into `EnrollDeviceView`: mints `EnrollTicket`
   (CSPRNG secret), registers it as pending (in-memory + short-lived), renders the `haven-enroll:` QR
   (keep `.screenshotProtected()` — the ticket is one-time but still an authorization credential).
2. On frame 28: verify MAC → confirmation sheet ("Link 'Blaine's iPad'?" with the device name from the
   request) → on confirm:
   - `DeviceRosterManager.enable(...)` + `addLinkedDevice(...)` (`DeviceRoster.swift:158-174`) — the
     existing `register_device`/`set_my_device_roster` path, unchanged (roster union + epoch rotation
     happen inside `verify_and_store_roster`/`register_device`, `lib.rs:2191-2218`).
   - New FFI `seal_self_sync_key_grant(accountSeed, deviceBundle)`.
   - Assemble + send frame 29 via `sendToMyDevices`-style dual-transport (`FeedView.swift:1653-1656`)
     plus directed to the requesting device hex.
   - Mark ticket consumed; `pushFullStateToMyDevices()`.
3. Only the primary answers: the `guard AccountStore.storedSeed()` pattern (`FeedView.swift:1605`)
   already makes seed-holding the gate; with S4, "primary" additionally means
   `DeviceRosterManager.isEnabled` — require it (prompt "Make this my primary device" if not).

## 5. Persistence per platform (what a seedless device stores)

| Item | Apple | Android | Desktop |
|---|---|---|---|
| Account **public** bundle + hex | New `AccountPublicStore` (keychain generic item, non-sync; tamper matters more than secrecy) — `AccountStore` grows a `.seedless(publicBundle)` mode | new keys in `EncryptedSharedPreferences` (`HavenCore.kt`) | `device-roster.json` sibling field (`roster.rs`) |
| Device seed | existing `DeviceKeyStore` (`DeviceRoster.swift:21-111`) — unchanged; optional hardening: SE-wrap like the account seed | existing `DeviceKeyStore` (`DeviceRoster.kt:23`) | existing `roster.device_seed` (`roster.rs:38`) |
| DeviceCredential | existing `DeviceCredentialStore` (`DeviceRoster.swift:116-122`; consider UserDefaults→keychain) | mirror | existing `roster.credential` (`roster.rs:40`) |
| **Granted self_sync_key (32 B secret)** | New `SelfSyncKeyStore`: SE-wrapped via `SecureEnclaveBox` with the full four-state `loadSeedStatus` discipline (`AccountStore.swift:255-309`) — this key decrypts all account state and gets seed-grade treatment | `EncryptedSharedPreferences` | file next to roster (0600), or OS keyring |
| Roster wire (verbatim, incl. capability trailer) | persisted engine state (`PersistState.device_rosters` exists, `lib.rs:1555-1562`; add the raw wire/trailer) | same (engine-level) | same |
| `SharedSeed` (NSE mirror) | **never written** in seedless mode (`SharedSeed.write` call sites: `AccountStore.swift:34, 44, 63, 74, 106, 525, 583`); NSE falls back to generic alerts until S6 | n/a | n/a |

Engine boot: `FeedStore.configure(seed:)` (`FeedView.swift:133`) becomes `configure(mode:)` —
`.seeded(seed)` (today's path) or `.seedless(accountBundle, deviceSeed)` → `HavenSocial.newSeedless`,
**skip** `registerDevice` (`:160`), skip push registration. Same fork in `HavenNet.kt:233-248` and
`engine.rs:218-236`.

## 6. Staged plan, ordering, scope

| Step | Scope | Ships | Est. |
|---|---|---|---|
| **S4.1 core** (`p2pcore`) | `enroll.rs`: `EnrollTicket` encode/parse, `enroll_request_wire`/`verify_enroll_request`, `enroll_grant_wire`/`open_enroll_grant`; unit tests incl. MAC tamper, wrong-device grant, expired ticket | dark | ~1 day |
| **S4.2 FFI** (`p2pcore-ffi`) | `NetState` `me` → `me_pub` + `me_secret: Option` refactor; `new_seedless`; gap items A1–A3, B4–B5, C6–C7, D8–D9, F11; enroll FFI; account-public-info helper (node hex/verification from a bundle) | dark (no client calls) | 3–5 days |
| **S4.3 FFI integration tests** | `s4_ffi_seedless_enrollment_end_to_end` (primary grants → seedless authors in a fully-capable circle → contact reads → seedless `register_device` returns empty → forged roster rejected — the FFI sibling of `device.rs:1010`); seedless self-sync via granted key; seedless opens circle media; legacy peer still reads under dual-seal | dark | 1–2 days |
| **S4.4 Apple** | `EnrollDeviceView` + linking-mode onboarding; frames 28/29 in `FeedView.handleFrame`; `AccountPublicStore`/`SelfSyncKeyStore`; `FeedStore.configure(mode:)`; `SelfSync.swift` granted-key branch; call/notification receive-path device-sender acceptance | user-visible behind "Link (new, seedless)"; legacy seed link kept | 3–4 days |
| **S4.5 Android + Desktop parity** | mirror S4.4 on `HavenNet.kt`/`Onboarding.kt`/`HavenCore.kt` and `engine.rs`/`roster.rs`/`commands.rs`/`app.js` | user-visible | 2–3 days each |
| **S4.6 retire the seed link for LINKING** | `LinkDeviceView` stops offering `transferCode()`; `TransferIdentityView` (move) and escrow restore (`AccountStore.swift:411-455`) are **kept** — they are the recovery/primary-rotation story, not the linking flow. Parsers for `haven-seed:`/`haven-link:` remain (old primaries in the wild) | flag/staged | ~1 day |

Ordering rationale: S4.1→S4.3 land as one core+FFI release (all dark; the `Option` refactor must prove
no-diff via the existing test suite); clients follow per platform. This mirrors how S0–S3 landed
(`bdcc199`, `dca6141`, `2c19628`).

## 7. Risks

- **Absence-as-deletion (the house specialty).** Two exposures: (a) a freshly-enrolled seedless device
  starts with an **empty** self-sync state; if `SelfSyncCoordinator` diffs its empty engine against a
  base before ingesting the primary's slot, it tombstones the account's circles/contacts (exactly the
  `MULTI-DEVICE.md:186-191` class; Android already resets the base on `importSeed`,
  `HavenCore.kt:56-58`). The enrollment flow must initialize the self-sync base from the primary's
  pushed slot *before* the first local diff/push — an explicit ordered step of grant acceptance.
  (b) The seedless device's roster copy must only ever move forward via verified `adopt_if_newer`;
  "I can't see my credential right now" must never clear `DeviceCredentialStore` or re-enter linking.
- **Keychain locked-read overwrites.** The granted self-sync key and the account public bundle are new
  persisted secrets; both stores must copy the four-state discipline of `AccountStore.loadSeedStatus`
  (`AccountStore.swift:255-309`) / `DeviceKeyStore.loadSeedStatus` (`DeviceRoster.swift:89-103`):
  locked/`.seError` ≠ absent, never regenerate, never delete on a failed read, and grant acceptance
  writes are the only writers.
- **`register_device` on launch.** All three platforms call it unconditionally at boot; the
  `Option<Identity>` design makes a missed guard a compile error rather than a runtime bug; still, an
  explicit test that a seedless engine's `register_device` returns empty.
- **Seedless device in a not-fully-capable circle cannot author readable content** (the `signer_of`
  gate at `lib.rs:2277-2279` is the S4 precondition, per the code's own comment). Mitigation: the
  primary offers the seedless link only when its circles are affirmatively fully capable (all-present
  positive, same shape as S5's gate), and falls back to the legacy seed link with a warning during the
  transition window. Do not silently enroll a device that would post into the void.
- **Ticket theft.** An unexpired `haven-enroll:` ticket lets an attacker enroll a device — visible in
  the roster and *cryptographically revocable* (that's the whole point of S4), a categorical
  improvement over seed theft. Still: single-use, ~10-minute expiry, screenshot-protected QR, and a
  "new device linked" notification on the primary.
- **Capability-trailer fidelity.** A seedless device that re-encodes (rather than verbatim-rebroadcasts)
  its roster would silently strip the primary-signed `SeedDropCapability` trailer (`my_roster_wire`,
  `lib.rs:2960-2963`), stalling the circle's capability convergence and therefore S5 retirement.
  Persist and rebroadcast the exact wire bytes.
- **Pushes/calls degrade on seedless devices until receive-path changes land everywhere:**
  notifications sealed to the account key won't decrypt (generic alert fallback exists), and
  device-signed call frames are dropped by pre-S4 receivers (`FeedView.swift:1511`). Both are bounded,
  documented S6 follow-ons; the S4 UI should say the primary keeps push duty.
