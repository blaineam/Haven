# Haven circle keying — protocol specification (for formal verification)

Status: derived from code on 2026-11-17; model machine-checked 2026-11-18 (results in §7).
Companion model: [`haven_circle_keys.spthy`](haven_circle_keys.spthy) (Tamarin).
Design rationale lives in [`../GROUP-KEYING.md`](../GROUP-KEYING.md); this file states *what the
code does*, precisely enough to model, and flags where code and design prose disagree.

Scope: §1–§9 cover the **epoch / sender-keys layer** (KeyCommit + epoch-sealed events);
§11–§14 cover the **TreeKEM key schedule**. Out of scope: the per-message DM ratchet (M6),
seed-drop device revocation, multi-device key convergence, fork resolution, calls, relay metadata.

## 1. Adversary

Dolev–Yao network adversary who also operates or records every relay and mailbox (they see and
may replay, reorder, copy between mailboxes, and drop any envelope). Additionally the adversary
may, at chosen times, learn:

| Compromise | Meaning |
|---|---|
| `RevealSig(X)` | X's hybrid signing key (Ed25519 + ML-DSA-65) |
| `RevealKC(X)` / `RevealKQ(X)` | X's classical (X25519) / post-quantum (ML-KEM-768) KEM secret, **independently** — a seed compromise reveals both |
| `RevealOwn(A,c,e)` | the epoch key A currently holds for its own epoch (device state) |
| `RevealPeer(R,A,c,e)` | an epoch key R currently holds for peer A (device state) |

A "malicious member" is modelled as a member whose keys the adversary holds.

## 2. Identities and primitives

Each member X has `sig_X`, `kemC_X` (X25519), `kemQ_X` (ML-KEM-768); public parts are known and
authentic (contact approval / safety-phrase anchors this; **not modelled**).

* **Hybrid wrap** (`crypto.rs::encapsulate_to`): ephemeral X25519 ECDH against `kemC_R` plus ML-KEM
  encapsulation against `kemQ_R`, combined by HKDF-SHA256 with the full KEM transcript, giving a
  32-byte KEK. Static recipient keys; **no sender authentication inside the KEM**.
* **AEAD**: AES-256-GCM.
* **Signature**: hybrid Ed25519 + ML-DSA-65 over a BLAKE3 transcript hash.

Modelling: hybrid wrap = nested asymmetric encryption (needs both secrets); AEAD = symmetric
encryption with open-check; signature = one signature.

## 3. Epochs (sender keys)

Every member A runs **its own** epoch sequence per circle `c`. Epoch `e` of A has a random 32-byte
`ek(A,c,e)`. A creates a new epoch on: block/remove, roster change, and every 7 days
(`ROTATE_INTERVAL_SECS`, `lib.rs`). Adding a member does not rotate. Clients keep the last
`KEEP_EPOCHS = 4` epoch keys per peer and delete older ones (`prune_epoch_keys`).

## 4. KeyCommit (sender side)

`inner = JSON{circle_id, epoch, epoch_key, circle_secret}`.
`social::seal_bytes`: fresh content key `K`; `ct = AEAD(K, inner)`; for every member `R` in the
**new** member set, `wrapped_R = AEAD(KEK_R, K)` with `KEK_R` from the hybrid wrap.
`sig = Sign(sig_A, BLAKE3("haven-envelope-v1" ‖ A ‖ ct ‖ for each R: R ‖ eph ‖ pq_ct ‖ wrapped_R))`.

Properties worth stating: the signature covers sender, ciphertext and the recipient entries; it
does **not** cover `circle_id` or `epoch` (they are inside `ct`).

## 5. KeyCommit (receiver side) — `receive_key_commit`

1. Parse envelope; resolve committer from `sender` (park if unknown).
2. Verify signature, find own recipient entry, hybrid-decap, AEAD-open → `inner`.
3. Store `ek` under slot `(committer_account, inner.epoch)` **inside the circle the envelope was
   routed into** (`idx`). Same-slot conflicts converge: numerically larger key wins, loser kept as
   an alt (`converge_epoch_key`, `ALT_KEYS_PER_SLOT = 4`).
4. `inner.circle_id` must equal the routed circle, else the commit is dropped. (Added with the
   F2 fix; before it there was no comparison.)

## 6. Events

`salt = BLAKE3-keyed(ek, "haven-event-salt-v1" ‖ c ‖ e ‖ plaintext)[..16]` (deterministic);
`evk = HKDF(salt, ek, "haven-event-key-v1" ‖ c ‖ e)`; `ct = AEAD(evk, plaintext)` (derived nonce);
`sig = Sign(sig_A, BLAKE3("haven-epoch-envelope-v1" ‖ c ‖ e ‖ salt ‖ A ‖ ct))`.
Receiver: the envelope's `c` must equal the circle it arrived in (F2 fix); verify `sig`, look up
`ek(A,c,e)`, derive `evk`, open, and require the plaintext's `author` to match the sender's account.

## 7. Properties and machine-checked results

Tamarin 1.12.0, `--auto-sources --prove`, no wellformedness warnings, ~3–5 s per variant
(2026-11-18). "As built" is the code before the circle-binding fix; `-DCHECKED` is the code with it.

| # | Property | Lemma | As built | With fix (`-DCHECKED`) |
|---|---|---|---|---|
| — | Model is executable (honest run completes) | `executable` | verified | verified |
| P1 | Epoch-key secrecy, hence **revocation**: a removed member cannot learn later epoch keys, even with all their keys; and the hybrid wrap needs **both** KEM halves broken | `epoch_key_secrecy` | verified | verified |
| P2 | Event confidentiality (same compromise conditions as P1) | `event_confidentiality` | verified | verified |
| P3 | Event sender authentication, **including the circle** | `event_authentication` | **falsified** | verified |
| P4 | A stored epoch key belongs to the circle it is stored in | `commit_circle_binding` | **falsified** | verified |
| P5 | Epoch-key forward secrecy against later long-term key compromise, sender-keys path only (`-DFS`) | `bounded_forward_secrecy` | **falsified** | **falsified** (by design, see F1) |

Non-vacuity: two mutated versions of P1 (dropping the KEM disjunct; claiming one KEM half
suffices) are both falsified, so P1 is not true for trivial reasons.

## 8. Findings

**F2 — Circle binding was missing on receive (fixed).** `receive_key_commit` did not compare the
commit's `circle_id` with the circle it arrived in, and `receive_epoch_event` did not compare the
envelope's `circle_id` either; the key is looked up by arrival circle. A relay, or any member of
two circles, could copy a genuine commit and post from circle A into circle B's mailbox; a reader
in both circles then filed the key and showed the post **in circle B**. No plaintext reached
anyone who could not already read it (the reader had to be a recipient of the circle-A commit), so
this was an integrity/context break, not a confidentiality break. Tamarin finds it as the P3/P4
counterexamples. Fixed by the two equality checks in `core/haven-ffi/src/lib.rs`; regression test
`commit_and_event_replayed_into_another_circle_are_rejected` fails before the fix and passes after.

**F1 — Forward secrecy on the sender-keys path is weaker than one sentence in
`GROUP-KEYING.md` implies (known limitation; TreeKEM is the remedy).** On this path every
KeyCommit is wrapped to the recipient's long-lived KEM keys, so an adversary who recorded commits
and later obtains those keys recovers every recorded epoch key, whatever the clients have pruned
(P5 counterexample, 14 steps). Client-side pruning helps only against theft of device state
without the long-term keys. This is the gap `TREEKEM-DESIGN.md` §6 names and closes for circles
running the tree (owned, every member MLS-capable): leaf keys are replaced on update and the epoch
schedule is one-way. It remains true for legacy and not-yet-capable circles. Whether the tree
as wired actually closes it is the subject of §11–§13 (it does not: finding F4).

**F3 — Observations, not findings.** A signer the receiver knows can re-sign another member's
commit ciphertext and have the key filed under the re-signer's own slot; the author bind inside
the event plaintext stops this being used to re-attribute posts (P3 holds with the fix).
Deterministic sealing reveals identical-plaintext equality within an epoch, and envelopes carry
sender and circle ids in the clear; bounding that needs an observational-equivalence model.

## 9. What a proof here would and would not cover

Covers the abstract protocol above under the stated adversary. Does not cover: the Rust/Swift/
Kotlin implementations, side channels, key storage, the KEM combiner's computational security
(needs a game-based proof), relay metadata (`IP ↔ node id`), or anything in §Out-of-scope.

## 10. Remaining models (not done)

1. ~~Device roster / seed-drop revocation.~~ Done: §17.
2. An observational-equivalence model for the deterministic seal.
3. Fork resolution without a delivery service (`TREEKEM-DESIGN.md` §5). The *secrecy* side
   (what the retention window costs, healing across a fork) is done: §15. *Agreement* — every
   device with the same commits picks the same branch — is a property of a pure function, tested
   by simulation in `treekem.rs`, not modelled.
4. A computational (game-based) argument for the hybrid KEM combiner — outside what a symbolic
   tool can establish; needs a cryptographer.

## 11. TreeKEM as the engine wires it

Model: [`haven_treekem_as_wired.spthy`](haven_treekem_as_wired.spthy). Source: `treekem.rs`
(`build_commit`, `apply_commit`, `advance_epoch`) and the `mls_*` / `keying_*` wiring in
`core/haven-ffi/src/lib.rs`.

The tree code itself (`treekem.rs`) is a conventional TreeKEM: path secrets, node keys, a
one-way `joiner → epoch → init` schedule, confirmation MAC, transcript hash. What decides the
security properties is how the **engine** feeds it:

1. **No stored random secrets — the engine replays.** `mls_replay` recomputes the current keying
   state by walking the commit chain from a Welcome or the genesis every time (memoised).
2. **The committer's inputs are deterministic functions of its long-term device seed.**
   `root = H(device_seed, group)` (`keying_secret_root`); `init_0 = H(root)` (`keying_base_init`);
   every member's leaf secret `H(root, device_id)` (`keying_leaf_secret`) — the committer assigns
   all of them; each update's "fresh" leaf secret and encapsulation entropy `H(root, epoch)`
   (`keying_update_material`).
3. **The root is persisted** (`PersistShadow.my_secret_root`).
4. **Only the elected committer authors commits.** `mls_pcs_leaf_update` is gated on
   `mls_am_committer`, and `mls_commit_authorized` rejects a chained commit from a non-admin
   unless it removes only the committer's own leaves. No other device ever refreshes its leaf.
5. **A Welcome delivers `joiner_secret` and the joiner's `leaf_secret`, sealed to the device's
   long-term bundle**, and the member keeps the decrypted Welcome (`ShadowTree.my_welcomes`) in
   persisted state so it can replay.

Model shape: one group, committer C and members D, E; epoch 1 = genesis; epoch 2 = a leaf Update
or "remove D"; the tree flattened to a star (a path secret is wrapped to each remaining member's
leaf key — depth changes cost, not who can open what). Two compromises are kept apart:
`RevealSeed` (long-term seed) and `RevealState` (what the device has stored at an epoch).

## 12. The proposed fix

Model: [`haven_treekem_fixed.spthy`](haven_treekem_fixed.spthy). Same group, same schedule,
same lemma names. Four changes:

| | Change | Replaces |
|---|---|---|
| F-a | Tree secrets are **random and stored**, deleted on schedule | derivation from the device seed; the persisted root; unbounded replay |
| F-b | Each device generates its **own** leaf key and publishes the public half in a signed key package | the committer assigning every leaf secret |
| F-c | A Welcome is wrapped to a **one-time** key-package key, deleted on joining; the decrypted Welcome is not kept | wrapping to the long-term device bundle |
| F-d | **Any member** may author a leaf-Update commit (no membership proposals) | committer-only updates |

The long-term device key then only signs. Its theft enables impersonation from then on (an
active attack these passive-secrecy lemmas do not cover), but reveals no epoch secret.

## 13. TreeKEM results

Tamarin 1.12.0, `--auto-sources --prove`, bounded to one group with one genesis.

"Stage 1" is [`haven_treekem_stage1.spthy`](haven_treekem_stage1.spthy): the engine after
§14 items 1–2 ([`STAGE1-STORED-STATE.md`](STAGE1-STORED-STATE.md)). It has two columns because
stage 1 cannot change a genesis that already exists: "new circle" is a circle created under
stage 1; "existing circle" (`-DLEGACY`) is one whose genesis predates it.

| # | Property | As wired | Stage 1, new circle | Stage 1, existing circle | Proposed fix |
|---|---|---|---|---|---|
| T1 | No epoch secret leaks with nothing compromised | verified | verified | verified | verified |
| T2 | A removed member is locked out of the next epoch, even with all its keys and state | verified | verified | verified | verified |
| T3 | Committer's stored state leaks → its Update heals | **falsified** | verified | verified | verified |
| T4 | A member's stored state leaks → healing | **falsified** (the member never updates) | **falsified** | **falsified** | verified (the member's own Update) |
| T5 | Forward secrecy vs a later committer seed compromise | **falsified** | verified | **falsified** | verified |
| T6 | Forward secrecy vs a later member seed compromise | **falsified** | **falsified** | **falsified** | verified |
| T7 | Healing after a committer seed compromise | **falsified** | verified | **falsified** | verified |
| T8 | Forward secrecy vs a later member stored-state compromise | **falsified** (the kept Welcome) | verified | verified | verified |
| T9 | Forward secrecy vs a later committer stored-state compromise | **falsified** (the stored root) | verified | verified | verified |

Reading the stage-1 columns:

* T3 holds because the stored state no longer contains the root, and the leaf secrets the
  committer assigned are stored wrapped under a seed-derived key. It is a statement about a
  stolen state blob *without* the seed; seed and state together still open everything.
* T5 and T7 move only for circles created under stage 1. In an existing circle the genesis init
  and every leaf assigned before the upgrade are still functions of the committer's seed, and a
  later commit's path secret is wrapped to those leaves.
* T8 and T9 are about epochs the checkpoint has passed. The model has two epochs; the engine's
  checkpoint trails the tip by 3, so read "epoch 1" as "an epoch older than the retention window".
* T4 and T6 are untouched: members still never update, and a Welcome is still wrapped to the
  member's long-term device key.

In the fixed model T5–T7 are one lemma (`T1_T5_T6_T7_no_secret_from_longterm_keys`): a long-term
key alone reveals nothing, so there is no excuse clause for it.

**F4 — TreeKEM as wired gives no forward secrecy and no post-compromise security against
compromise of a device's seed or stored state.** Every counterexample is short (16–24 steps) and
is the same idea: the adversary recomputes `root` (committer) or reopens the recorded/kept
Welcome (member) and replays the public commit chain. `TREEKEM-DESIGN.md` §6.4's healing argument
("a fresh `leaf_secret` from OsRng — entropy the attacker does not have") describes the design,
not the wiring: the wired value is `H(root, epoch)`.
What still holds as wired: confidentiality against anyone who never obtains a member device's
seed or stored state (T1), and cryptographic removal (T2).

## 14. Implementing the fix (plan; items 1–2 implemented, not released)

Capability-gated like the `mls` marker (a `mls2` marker; a circle re-keys only when every device
advertises it; reversible; legacy circles unchanged). The content path does not change — it is
keyed by the 32-byte per-epoch sender keys wherever they come from — so no post is re-encrypted
or lost, and nothing is user-visible.

1. **Stored, checkpointed keying state.** *Implemented on the stage-1 branch
   ([`STAGE1-STORED-STATE.md`](STAGE1-STORED-STATE.md)).* Persist a checkpoint of the
   `KeyingState` (tree, own path secrets, `init_secret`, transcript hash, tip) once an epoch is
   past the fork window; delete what the checkpoint supersedes. Stop replaying from genesis.
   Removes: the persisted root, kept Welcomes, seed derivation. (F-a, part of F-c.) It needed one
   change to fork selection — a branch 4 commits deep is final — because the walk rule below the
   genesis was hash-only, and a device that has deleted old state cannot follow a late short
   branch.
2. **Random secrets.** *Implemented with item 1.* `init_0`, leaf and update secrets from `OsRng`;
   own commits are no longer rebuilt from the seed, so their build inputs are stored until
   checkpointed. (F-a.) Existing circles keep their seed-derived genesis until item 5.
3. **Key packages.** A device publishes a signed (leaf public key, one-time init key); the
   committer Adds from it and Welcomes to the init key. (F-b, F-c.)
4. **Member updates.** Receivers accept a path-only commit from any current member; every device
   runs the weekly Update. More concurrent commits means more forks, so the fork rule
   (`TREEKEM-DESIGN.md` §5) needs re-testing under that load before this stage ships. (F-d.)
5. **Migration.** When a circle is fully `mls2`-capable the committer issues a fresh genesis with
   random secrets; devices drop the v1 tree state after the flip.

Each stage needs its own core tests and a model re-run; stages 3–4 change wire formats.

## 15. Forks and the retention window

Model: [`haven_treekem_forks.spthy`](haven_treekem_forks.spthy) (the fixed design of §12, plus
two commits extending the same epoch, a retention window, and a re-issued Update).

Haven has no delivery service, so two commits can extend the same epoch
(`TREEKEM-DESIGN.md` §5). A device therefore cannot delete its epoch-n state the instant it
applies a commit; it keeps it, plus one branch state per commit it knows, until it **checkpoints**:
settles on a branch and deletes the epoch-n state and every other branch. The model asks what
that retention costs.

| # | Property | Result |
|---|---|---|
| FK1 | With forks, no epoch secret leaks unless some device's stored state does | verified |
| FK2 | After the checkpoint, a leak of the settled state exposes neither the earlier epoch nor the losing branch | verified |
| FK3 | The epoch a device's own Update creates is secret whatever leaked from that device before | verified |
| FK4 | A **competing** branch is not healed by that Update (a trace exists) | confirmed |
| FK5 | Re-issuing the Update on the winning branch heals, even if everything the device stored before leaked | verified |

What this fixes as rules for the implementation:

- **Forward secrecy is delayed by the window, not lost.** Until a device checkpoints, a leak of
  its state exposes the epoch it is leaving and every branch it holds. So the window must be
  bounded: checkpoint when the next epoch has a child the device has applied, or after a fixed
  age, whichever comes first. FK2 is the guarantee from that point on.
- **A healing Update only counts once it is on the adopted chain** (FK4). A device whose Update
  lost a fork must re-issue it at its next bundle (FK5). The cadence code has to track "my last
  Update is an ancestor of my tip", not "I sent an Update this week".
- **Old leaf secrets die at the checkpoint**, not at the Update. Between the two the device holds
  both, because the branch that still needs the old leaf key may win.
- FK2 and FK5 assume no signing key is compromised. Dropping that premise, the prover finds the expected
  active attack: with the committer's signing key an adversary forges a Welcome and seats a
  joiner in a group whose secrets it chose. That is impersonation with a stolen long-term key,
  which these secrecy properties do not cover; §16.2 binds a Welcome to a public commit so
  nothing short of that key suffices.

Not modelled here: *which* branch wins. Agreement is a property of a pure function of the commits
a device has seen (longest chain, then larger hash) and is exercised by the convergence
simulation in `core/haven-p2p/src/treekem.rs` (random commits by any member, partitions,
redelivery, forced forks). A device that checkpointed a branch that later loses to a longer chain
cannot switch; it re-enters with a fresh key package (§16.3).

## 16. Version 2 of the tree: wire formats and rules (stages 3–5)

Stage 1–2 (stored state, random secrets) change nothing on the wire, so they apply to existing
trees in place. Everything below is a new tree version and takes effect only after the
re-genesis in §16.5. Primitive layer: [`core/haven-p2p/src/keypackage.rs`](../../core/haven-p2p/src/keypackage.rs).

### 16.1 Key package (F-b, F-c)

```
TAG_MLS2_KEYPACKAGE = 0x10
KeyPackage = version(1)=1 ‖ lp(group_id) ‖ kp_id(16) ‖ lp(LeafNode) ‖ lp(init_bundle) ‖ lp(sig)
             # LeafNode  : the device's OWN leaf public key, its account-signed credential, and the
             #             leaf binding — now really DEVICE-signed, because the device holds the key
             # init_bundle: public bundle of a throwaway identity drawn from a random 32-byte seed
             # sig       : DEVICE hybrid signature over "haven-mls-kp-v1" ‖ all preceding bytes
```

- The device keeps `(kp_id, leaf_secret, init_seed)` in its state blob and re-emits the same
  package bytes in every bundle until it is used (byte-stable, so the mailbox stays deduped).
- A receiver accepts a package only if: the credential chains to the pinned account key, the
  device is authorized in that account's verified roster, the leaf binding and the package
  signature verify under that device, and `group_id` is the circle it arrived in.
- **One use.** A committer uses a given `kp_id` for at most one Add; the device publishes a new
  package whenever it needs to (re-)enter. `init_seed` is deleted when the device has joined and
  that entry point is past the retention window (§15); the Welcome plaintext is never stored.

### 16.2 Welcome v2

```
TAG_MLS2_WELCOME = 0x12           SealedEnvelope to the key package's init identity (seal_bytes rail)
plaintext = commit_hash(32) ‖ epoch(8) ‖ leaf_index(4) ‖ joiner_secret(32) ‖ cth(32) ‖ kp_id(16)
            ‖ u32 tree_len ‖ tree_bytes
```

No leaf secret travels: the joiner already holds it. The joiner checks that the tree's leaf at
`leaf_index` carries exactly the leaf key of its package `kp_id`, else it rejects (fail closed,
as today). Every v2 Welcome is self-contained (carries the tree), genesis included.

A Welcome is also bound to the **public commit** it enters at: the joiner must hold the commit
whose hash is `commit_hash`, that commit must be for this circle and epoch, pass the same
signature and authority checks every member applies, and claim exactly the delivered tree
(`tree_hash`). A joiner therefore never enters a state described by a Welcome alone
(`enter_via_welcome_v2`).

### 16.3 Membership commits

```
TAG_MLS2_COMMIT = 0x11    a treekem::Commit on a v2 chain      TAG_MLS2_JOIN = 0x13    the v2 join ack
```

The v2 tree has its own tag family (`0x10`–`0x13`) instead of reusing the v1 tags: a v1 build
that receives a v2 commit under the v1 tag would park it as an orphan and retry it, and a v2 join
ack under the v1 tag would trigger a v1 re-Welcome. Unknown tags fall through harmlessly.


- **Genesis** is built by the elected creator once it holds a valid key package for every
  authorized device; the Adds carry the packages' leaves verbatim. `init_0`, the creator's own
  leaf secret and all path entropy come from the OS RNG. The v2 genesis parent constant uses a
  new domain (`haven-mls-genesis-parent-v2`), so v1 and v2 chains can never be spliced.
- **Add** needs the new device's key package. **Re-entry** (a device stranded on a losing branch
  or asleep past retention) is a `Remove(old leaf) + Add(new key package)` in one commit — there
  is no separate "re-Welcome" that re-delivers an old leaf secret, because nobody but the device
  ever had it.
- **Remove** is unchanged: admin-authorized, or a member removing only its own leaves.

### 16.4 Member updates (F-d)

A commit with **no proposals** and an UpdatePath is valid from **any current leaf** when:

1. the UpdatePath leaf's credential names the same device as the sender's current leaf;
2. that device is authorized in its account's verified roster;
3. the leaf binding and the commit signature verify under that device (`verify_leaf`).

Cadence: each device updates its own leaf at the weekly full-bundle chokepoint, offset by a
per-device jitter so devices do not collide by construction, and **re-issues** at its next bundle
whenever its last Update is not on the chain it has adopted (§15, FK4/FK5). The update's leaf
secret and entropy are random, stored with the pending commit, and dropped at the checkpoint.

### 16.5 Migration (no user-visible step)

- New capability value `ml: 2` in the profile, monotonic and learned-never-inferred like `ml: 1`.
- While any device of the circle is `ml: 1`, the circle stays on its v1 tree (with stage 1–2
  hygiene on upgraded devices). Nothing is emitted that a v1 build cannot parse.
- When every authorized device is `ml: 2`, upgraded devices drop the v1 tree and wipe its
  secrets; content keys fall back to the KeyCommit lane for the interval (the existing park
  path), devices publish key packages, the creator builds the v2 genesis, and content flips to
  the v2 tree at all-joined (the existing second gate). Posts are never re-encrypted or lost:
  the content path only ever sees 32-byte epoch keys, and the daily re-seal republishes history
  under whichever key is current.
- A v1 device (re)joining reverses the gate exactly as §7.3 of the design does today.

## 17. Device roster

Model: [`haven_device_roster.spthy`](haven_device_roster.spthy). Code: `device.rs`
(`DeviceCredential`, `DeviceList::adopt_if_newer`, `merge`) and `store_verified_roster`.

An account has a long-term signing key that contacts pin out of band. It signs a credential for
each device and a versioned roster; a verifier adopts a roster only if it verifies under the
pinned key and has a strictly higher version, and treats a device as authorized only per the
roster it currently holds. A *seed holder* is a device that also holds the account key (the
primary; every device before seedless enrollment). The model's roster speaks about one device;
the real one is a set (sound for the per-device properties below).

| # | Property | Result |
|---|---|---|
| R1 | If a verifier treats (device, key) as a device of the account, the account enrolled it and a seed holder signed the roster relied on — unless the account key leaked | verified |
| R2 | A revocation is not rolled back: after adopting it, the device counts as authorized again only on a strictly newer roster a seed holder signed. Replays, and a seedless device's own keys, do nothing | verified |
| R3 | A revoked device that **holds the account key** can re-authorize itself (a trace exists) | confirmed — known limit |
| R4 | Two seed holders can sign different rosters with the **same version**; a verifier holding the one that still authorizes a device never adopts the one that revokes it (a trace exists) | confirmed — finding F5 |
| R5 | With a single seed holder, a version identifies one roster | verified |

Mutation check: removing the signature check from the verifier falsifies R1, R2 and R5.

**R3 is the known reason for seedless enrollment.** Revoking a device that holds the account key
is advisory, because that key signs rosters. Only seedless devices can be cryptographically
revoked. The primary (and any device restored from a backup of the account seed) is outside that
guarantee; so is the account recovery phrase.

**F5 — A revocation can be ignored on a version tie (low; not fixed).** For a contact's roster,
`store_verified_roster` returns `AlreadyCurrent` when the incoming version equals the stored
one, without comparing contents. If two seed-holding devices of one account sign different
rosters with the same version (each bumped from the same base before seeing the other), a
contact who stored the one without the revocation never takes the one with it. The contact keeps
treating the revoked device as authorized — and keeps sealing to it — until a seed holder that
has seen both publishes the merged, higher version (`DeviceList::merge`, which keeps a
revocation on a tie). Reachable only for accounts with more than one seed holder; an outsider
cannot cause it. Proposed fix, verifier-side and fail-closed: on an equal-version roster that
verifies but differs, treat every device revoked in *either* as revoked until a strictly newer
roster arrives.
