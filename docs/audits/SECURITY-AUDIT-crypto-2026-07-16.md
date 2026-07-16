# Security Audit — Seed-drop + MLS/TreeKEM Cryptography

- **Date:** 2026-07-16
- **Commit audited:** `593a72fe665b7b4351358f4f6de36e30da10b282` (branch `main`)
- **Reviewer:** Claude (Opus 4.8) — adversarial static review, human-directed
- **Scope:**
  - `core/haven-p2p/src/device.rs` — DeviceCredential/DeviceList, SeedDropCapability, admin authority (AdminGrant/admin_closure), recipients gating, self-sync grant.
  - `core/haven-p2p/src/treekem.rs` — tree math, UpdatePath build/apply, epoch schedule (advance/wipe), fork rules, build/apply_commit, Welcome.
  - `core/haven-ffi/src/lib.rs` — signer_of, receive_key_commit, S1 authored-open verifier, keying flip (set_mls_keying/mls_refresh_keying/all-joined gate/park-resume), mls_commit_authorized, admin/creator wiring, enroll wiring.
  - `core/haven-p2p/src/enroll.rs` — seedless enrollment ticket/request/grant.
  - `core/haven-p2p/src/crypto.rs`, `identity.rs` — hybrid primitives.
  - `core/haven-p2p/src/groupkey.rs`, `selfsync.rs` — epoch substrate and account-state CRDT (supporting).
- **Method:** Read the committed code (not the design docs' aspirational text), traced every inbound-object verification path, attacked each of the 8 claim areas below, cross-checked the crypto primitives for nonce/domain/label discipline, and confirmed the production gating of the dark M3 keying path.

## Honest limitation

This is an **AI-driven adversarial code review**. It is a strong first line — it read every line of the crypto and its wiring and tried concrete attacks — but it is **not a substitute for a formal human cryptographer's audit** of the novel TreeKEM construction, and in particular of the **fork-resolution protocol (§5) and the M3 keying re-key**, which are the parts with no imported proof and no reference implementation. Treat the "holds" verdicts as "no defect found by this pass," not "proven correct." The design's own M7 gate (external crypto review before the master switch goes default-ON) remains necessary and is not discharged by this document.

---

## Executive summary

The shipped seed-drop machinery and the TreeKEM primitives are, on inspection, **carefully built and internally consistent**. The hybrid PQ combiner is transcript-bound; domain separation between identity / content / tree / enroll contexts is thorough and correct; every inbound signed object (credential, roster, capability marker, admin grant, commit, join-ack, welcome, event) is verified against a pinned key before it is used; the fork tie-break is a total, deterministic order over full commit bytes; and the account-state CRDT and circle import are additive (no absence-as-deletion). The headline claim — **cryptographic revocation of a seedless device** — holds in the code path the s5 test exercises, and the production default correctly refuses to drop the account-key seal (or flip keying) until an all-present-positive capability signal holds.

The **material findings are two MEDIUMs**, both about *completeness* of revocation and authority rather than a break of the core content-confidentiality guarantee:

1. **The self-sync key is never rotated on revocation.** A revoked seedless device keeps `self_sync_key` and can continue to read *and* LWW-write the account-state stream (profile / contacts / circles / settings).
2. **The circle creator (the admin-authority root) is pinned first-grant-wins (TOFU).** A malicious member can race a self-signed grant to install itself as the authority root on a peer that hasn't yet learned the real creator, after which the real creator's grant is rejected. This is only *consumed* under the M3 keying switch, which ships OFF ("dark").

Neither breaks circle-content revocation or confidentiality. Everything in M3 (the TreeKEM keying flip + Remove authority) is gated behind `mls_keying`, which defaults OFF, so findings #2–#4 are latent until that switch is turned on per fully-capable circle.

**Severity counts:** Critical 0 · High 0 · Medium 2 · Low 3 · Info 3.

---

## Findings (ranked by severity)

### M1 — MEDIUM — Self-sync key is never rotated, so revocation does not cut the account-state channel
- **Where:** `identity.rs:198` (`self_sync_key`, seed-derived, immutable); `device.rs:505` (`seal_self_sync_key` grants the *same* permanent key); `selfsync.rs:143` (`AccountState::merge`, LWW); revocation path `device.rs:203/225` + `lib.rs:4620` rotates only *epoch* keys, never the self-sync key.
- **Scenario:** A seedless device is enrolled (S2/S4) and receives `self_sync_key` sealed to its bundle. It is later revoked (DeviceList v+1). Revocation + epoch rotation cut it off from **circle content** (proven — s5). But `self_sync_key` is a fixed HKDF of the master seed; it is neither rotated nor re-granted on revocation. The revoked device still holds it and can `open_account_state` (read the user's profile, contact list, circle list, settings, pins) and, worse, `seal_account_state` a **newer-stamped** LWW blob into the user's self-sync mailbox — tombstoning a circle/contact or editing the profile on the user's *other* devices, which accept it as authentic (valid key ⇒ authentic per `selfsync.rs:142`).
- **Why it works:** The seed-drop threat model rotates the *circle epoch* on device change but treats `self_sync_key` as static account material (it must be identical across a user's devices). Nothing re-keys it when a device leaves, so a "revoked" seedless device retains full read/write on the account-state replication stream.
- **Impact:** Revocation is **incomplete**: it cryptographically cuts circle content but not the account-state channel. A compromised-then-revoked seedless device remains a live writer to the user's own settings/contacts/circles convergence for the life of the account seed.
- **Remediation:** On revocation, rotate the self-sync key (mint a fresh 32-byte key, re-grant it via `seal_self_sync_key` to every *still-authorized* device only, and stop accepting blobs sealed under the old key after a grace window). This mirrors the epoch-rotation-on-membership-change discipline the circle path already has. Until then, document that seed-drop revocation covers circle content, not the self-sync stream.

### M2 — MEDIUM — Circle creator (admin-authority root) is pinned first-grant-wins (TOFU), permanently wedgeable by a malicious member
- **Where:** `lib.rs:2102-2106` (`receive_admin_grant` learns the creator from the *first* validly-signed grant, and thereafter *rejects* any grant naming a different creator); `lib.rs:4541` (import adopts `pc.creator` learn-once); consumed at `lib.rs:2069` (`circle_admin_set`) → `lib.rs:1963` (`mls_commit_authorized`).
- **Scenario:** The only network mechanism by which a *non-creator* member learns the circle creator is the control-lane admin grant. `receive_admin_grant` pins `creator` from the first grant that verifies against its own grantor. A malicious member Mallory issues `AdminGrant{creator=Mallory, grantor=Mallory, admin=Mallory, v=1}`, signed with her own account key — it verifies (grantor==signer). If it reaches a victim before the real creator's self-grant (a newly-added member, or any peer that hasn't synced the real creator yet), the victim pins `creator=Mallory`. The victim then **rejects** the genuine creator's grant (`creator != Some(g.creator)` ⇒ `Ok(false)`), so the wedge is permanent, and `circle_admin_set` for that victim is rooted at Mallory — Mallory can author Remove commits the victim will accept (`mls_commit_authorized` ⇒ true for an "admin"), and the honest creator's Removes are *not* honored.
- **Why it partially works / is contained:** The grant itself is unforgeable (Mallory must sign her own; a relay cannot mint one). The impact is **authority-root confusion / divergence**, not key theft — Mallory gains no content she couldn't read as a member. Crucially, `mls_commit_authorized` is only consulted for **TAG_MLS_COMMIT** processing, and content only *keys* off the tree when `mls_keying` is ON, which **ships OFF**. So today this is latent.
- **Impact (when M3 is enabled):** A malicious member can (a) get an unauthorized Remove accepted on victims and (b) split the fleet's authority root, which is the "two halves of a family diverge" class the design most fears.
- **Remediation:** Bind the creator to a value that cannot be independently TOFU'd per peer — e.g., carry the pinned creator id inside the *circle definition* that members already agree on (signed/derived alongside `circle_id`), or require the creator pin to arrive over an authenticated per-member channel (the roster/profile lane) rather than "first grant wins." At minimum, prefer a creator whose grant is self-consistent with an out-of-band circle-origin fact instead of accepting any first grantor as the root.

### L1 — LOW — Genesis commit is selected by leaf-count, not authenticated to the elected creator
- **Where:** `lib.rs:1892` (`receive_mls_commit`: a genesis commit — epoch 1, parent = `shadow_genesis_parent` — is stored with **no signature/authority check**, unlike chained commits at `:1914`); `lib.rs:2170` (`keying_winning_genesis` picks the genesis with the most Add leaves, then larger hash).
- **Scenario:** Any mls-capable member can craft a competing genesis (it need not be signed by the elected creator, `am_shadow_creator`). Because selection prefers *more* leaves, a member cannot win with an *exclusionary* (fewer-leaf) genesis, and cannot force a **live** flip with outsider leaves because the **all-joined gate** (`keying_all_joined` → `receive_mls_join` → `resolve_shadow_sender`/`authorized_device_and_account`) requires each leaf's device to be a **roster-authorized device of a circle member** and to have broadcast a device-signed join ack (unforgeable). So a bogus leaf never marks "joined" and the circle never flips.
- **Impact:** Bounded to a **liveness/DoS** on the flip (competing geneses, parked state) and to member-level content access (a malicious member controlling the winning genesis learns secrets it could already derive as a member). No confidentiality escalation and no forged Remove authority.
- **Remediation:** Verify the genesis commit's signature and require its signer to be the elected creator (lowest account id) or a current admin before admitting it, so genesis selection is over *authenticated* candidates, not arbitrary ones.

### L2 — LOW — Non-constant-time comparison of the confirmation MAC and tree hash
- **Where:** `treekem.rs:2322` (`confirmation_mac(&s.confirm_key, &cth)[..] != commit.confirmation_mac[..]`) and `:2313` (`th != commit.tree_hash`), both variable-time slice compares. Contrast the enrollment MAC, which is compared via `blake3::Hash` equality (constant-time) — `enroll.rs:227,331`.
- **Scenario:** `confirm_key` is a secret derived from `epoch_secret`. A timing oracle on `apply_commit` could in principle leak how many leading MAC bytes match, aiding forgery of a confirmation MAC without knowing `confirm_key`.
- **Why impact is low:** Commit application is local, one-shot, and in a noisy store-and-forward model; the attacker also authors the commit and gains little from a matching MAC alone (the tree hash and signature are still checked). Still, defense-in-depth wants the secret-keyed MAC compared in constant time.
- **Remediation:** Compare the confirmation MAC with a constant-time equality (e.g., `subtle`/`blake3::Hash` equality as enroll already does).

### L3 — LOW — Update-path encapsulation entropy is a deterministic function of (device seed, tree epoch) only
- **Where:** `lib.rs:1657` (`keying_update_material` = blake3(root ‖ epoch)); `treekem.rs:1415` (`ct_seed`) and `:1426` (`seal_path_secret` via `seal_reproducible`, key-derived nonce).
- **Analysis:** Within one build, `ct_seed` varies per `(direct-path node, resolution node)`, so each ciphertext gets a distinct key/nonce — no reuse. Across builds, entropy repeats only if the same device authors two commits at the **same tree epoch**; the audited flow advances the tip by exactly one per commit (`mls_replay` re-derives the tip and rebuilds the committer's own commit), so a same-epoch double-author does not occur, and no `(key, nonce)` pair encrypts two distinct plaintexts today. It is nonetheless a latent AES-GCM nonce-reuse hazard if future code ever authored sibling commits at one epoch.
- **Remediation:** Bind `parent_commit_hash` (and ideally the removed-leaf set) into `keying_update_material`'s entropy so any two distinct commits — even at the same epoch — draw independent encapsulation randomness.

### I1 — INFO — M3 keying delivers revocation but **not** the FS/PCS the TREEKEM design headline claims (by design, unshipped)
- **Where:** `lib.rs:1628` (`keying_secret_root` = blake3(device_seed ‖ gid)); `:1638` (`keying_leaf_secret` from the *creator's* root); `:1657` (`keying_update_material` deterministic from seed). No OsRng leaf refresh exists in M3.
- **Observation:** Leaf secrets are deterministic from the device seed and, at genesis, are *generated by the creator* and delivered via Welcome. There is no fresh-entropy leaf Update (that is design stage **M5**, not shipped). Consequently the M3 tree provides cryptographic **revocation** (a removed leaf cannot derive the next `commit_secret`, verified in `apply_commit`/`decrypt_update_path`) but **no post-compromise security and no per-epoch forward secrecy against a device-seed compromise** — an attacker with the seed reconstructs every tree secret. This matches the docs (PCS = M5; M3 "lands dark") and the `advance_epoch`/`wipe_secret` deletion discipline is correctly in place for when M5 arrives. Flagged only so the security-page claims are not read onto the shipped M3.

### I2 — INFO — Default posture: revocation is advisory (account-key always a recipient) until the retire switch flips
- **Where:** `device.rs:351` (`recipients_with_devices` always seals to the account key) and `lib.rs:3840` (production passes `st.retire_account_key`, default `false` → byte-identical to always-seal). The cryptographic cut only exists in the `retire_account_key = true` + fully-seed-drop-capable path (`recipients_with_devices_gated`, proven by s5).
- **Observation:** This is the documented, intentional dual-seal coexistence contract, correctly gated on an all-present-positive signal (`circle_fully_seed_drop_capable`). Not a vulnerability; recorded so the "cryptographic revocation" claim is understood to be conditional on the (correctly gated) retire flip.

### I3 — INFO — Enrollment ticket single-use is caller policy, not enforced in core
- **Where:** `enroll.rs:23,102,207` — expiry arithmetic and MAC/freshness are enforced in core, but single-use consumption of a ticket is explicitly left to the caller (the primary tracks pending/consumed tickets).
- **Observation:** Correct division of responsibility, but the security of "a ticket authorizes exactly one device" depends on the platform actually consuming the ticket. Verify each platform's primary marks tickets consumed on first successful grant. The freshness window (both-direction) and MAC binding otherwise make replay require the live secret within the TTL.

---

## Verdicts by claim area

| # | Claim area | Verdict | Evidence |
|---|---|---|---|
| 1 | **Revocation soundness** | **HOLDS** (circle content) / caveat | In the retire-ON, fully-capable path a revoked seedless device is not a recipient and its stale epoch key opens nothing (`device.rs:1260` s5 test; `recipients_with_devices_gated`). Cannot re-enter: a device-signed roster fails `DeviceList::verify` against the pinned account key (`device.rs:188`, s4/s5). Default is advisory by design (I2). **Caveat: the self-sync channel is *not* revoked (M1).** |
| 2 | **Admin authority forgery** | **HOLDS-WITH-CAVEAT** | A grant is unforgeable (`AdminGrant::verify`, id-match + hybrid sig, `device.rs:677`); `admin_closure` is a monotone fixpoint that admits nothing from a non-admin grantor (`device.rs:736`, test `admin_closure_only_follows_chains_rooted_at_the_creator`); grants are circle- and creator-bound and rollback-defended (`lib.rs:2076`, `adopt_if_newer`). **The weak link is the creator *pin* itself — first-grant-wins TOFU (M2).** A non-admin cannot escalate given a correct creator pin; but the pin can be captured. |
| 3 | **Downgrade / park-resume abuse** | **HOLDS** | Capability is signed, monotonic, learned-never-inferred (`SeedDropCapability`, `circle_fully_*_capable` all-present-positive, `device.rs:534/556`). The all-joined gate needs a **device-signed** join ack per current leaf (`keying_join_payload` verified in `receive_mls_join`, `lib.rs:2410`) — not spoofable and not absence-inferred. Park/resume recompute from verified state every bundle (`mls_refresh_keying`, `lib.rs:2499`), so a withheld ack or a re-added legacy device parks *back* to KeyCommit; it cannot reopen a revoked device (park keeps sender-keys revocation). No absence path drops capability. |
| 4 | **Enrollment** | **HOLDS** | Ticket carries a CSPRNG secret + full-bundle verification hash (`enroll.rs:81`); request and grant are MAC'd with domain-separated keys and freshness-checked both directions (`:179,208,271`); grant acceptance is all-positive: MAC, bundle==ticket, credential names *this* device, roster authorizes *this* device, self-sync sealed to *this* device (`open_enroll_grant`, `:316`). A seedless device cannot mint a verifying roster (s4). No seed appears in any artifact (test `no_wire_ever_contains_the_account_seed`). Single-use is caller policy (I3). |
| 5 | **Absence-as-deletion** | **HOLDS** | `merge_circle` is pure union — members, events, epoch keys, secrets, grants only grow (`lib.rs:4482`); creator is learn-once. Self-sync is LWW with *explicit stamped* tombstones and stale-resurrection resistance (`selfsync.rs:101,143`, tests); an empty/fresh device contributes no records and can tombstone nothing. Seed deletion is not in this commit's reachable production path. |
| 6 | **Fork / convergence** | **HOLDS** | `compare_commits` is a total order over blake3 of full signed bytes (`treekem.rs:1985`); `select_chain` is longest-valid-then-larger-tip, skips invalid candidates, monotone in information (`:2024`); `apply_commit` verifies the reproduced tree hash *and* the confirmation MAC and fails closed (`:2313,2322`); `decrypt_update_path` verifies each derived node public key against the path (`:1850`). Convergence tests pass for concurrent commits and welcomed joiners. |
| 7 | **Crypto primitive misuse** | **HOLDS** (minor L2) | Hybrid combine is transcript-bound with a v2 salt and folds eph/ct/recipient keys into HKDF info (`crypto.rs:106`); tree wraps use the same salt but a distinct `haven-treekem-ct-v1` info leading with length-prefixed group_id/epoch/node (`treekem.rs:1382`) — no cross-context replay. `seal_reproducible` is only used where the key is unique per plaintext (event salt binds plaintext hash; tree ct binds fresh ephemeral). Labels are distinct across identity/selfsync/content/tree/enroll/join/admin/leaf/proposal/commit/groupinfo. Every inbound signed object is verified before use. Only defect: non-constant-time MAC compare (L2). |
| 8 | **Relay-blindness** | **HOLDS** | Mailbox/media/presign prefixes are keyed-MAC of a per-member `circle_secret` a non-member cannot derive (`groupkey.rs:108`); all content, key commits, welcomes, and self-sync blobs are sealed; capability markers, rosters, and admin grants are account-signed so a relay can neither forge nor silently strip them (verified on receive). The relay is non-authoritative: authority derives from pinned account keys and the creator root, never from delivery. |

---

## Residual risks / needs human-crypto review

1. **The fork-resolution protocol (§5) and the M3 removal re-key** are novel surface with no imported proof. This review found them internally consistent and convergent in the exercised cases, but the "two halves diverge" failure mode lives here — it is the correct target for the design's M7 external review.
2. **Creator-pin provenance (M2).** The authority model is sound *given* a correct creator pin; the pin's TOFU propagation is the gap to close before M3 is enabled.
3. **Self-sync key lifecycle (M1).** Rotating the self-sync key on revocation is unaddressed and should be designed before seed-drop revocation is described as complete.
4. **M5 forward-secrecy/PCS is unshipped (I1).** The `advance_epoch`/`wipe_secret` deletion discipline is present and correct, but leaf secrets are seed-deterministic in M3; the PCS claim must wait for the M5 OsRng leaf-refresh and its byte-scan/one-way tests.
5. **Timing side channels (L2, L3).** Constant-time MAC comparison and parent-bound update entropy are cheap hardening that remove latent hazards before the switch flips.
6. **Cross-platform enrollment single-use (I3).** Confirm every primary implementation consumes tickets on first grant.

*No findings were invented to pad this report. Where the strong claims hold, they hold on concrete evidence cited above; where they do not, the exploit or gap is made concrete.*
