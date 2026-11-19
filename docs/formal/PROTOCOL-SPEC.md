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

### 9.1 Keeping the results true

Every result quoted in this document is re-checked mechanically. [`verify.sh`](verify.sh) proves
each lemma of each model, one at a time, and compares the outcome with
[`EXPECTED.txt`](EXPECTED.txt); any difference fails, in either direction (a proof that stops
verifying, or a documented limit that starts verifying, which would mean the model no longer says
what this document says). `.github/workflows/security-proofs.yml` runs it, together with the whole
core test suite (the tests are what tie the code to the models), on every change to `core/` or
`docs/formal/`, and once a week so a new prover release that changes a result is noticed.

What that buys: the models and this document cannot drift apart unnoticed, and a code change that
breaks a tested security property fails CI. What it does not buy: evidence that the code matches
the model beyond what the tests exercise. That gap is closed only by review of the code against
this spec, and it is the first thing an outside audit should look at.

## 10. Remaining models (not done)

1. ~~Device roster / seed-drop revocation.~~ Done: §17.
2. ~~An observational-equivalence model for the deterministic seal.~~ Done: §18.
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

| # | Property | As wired | Stage 1, new circle | Stage 1, existing circle | Proposed fix | v2 tree as built |
|---|---|---|---|---|---|---|
| T1 | No epoch secret leaks with nothing compromised | verified | verified | verified | verified | verified |
| T2 | A removed member is locked out of the next epoch, even with all its keys and state | verified | verified | verified (see note) | verified | verified |
| T3 | Committer's stored state leaks → its Update heals | **falsified** | verified | verified | verified | verified |
| T4 | A member's stored state leaks → healing | **falsified** (the member never updates) | **falsified** | **falsified** | verified (the member's own Update) | verified |
| T5 | Forward secrecy vs a later committer seed compromise | **falsified** | verified | **falsified** | verified | verified |
| T6 | Forward secrecy vs a later member seed compromise | **falsified** | **falsified** | **falsified** | verified | verified |
| T7 | Healing after a committer seed compromise | **falsified** | verified | **falsified** | verified | verified |
| T8 | Forward secrecy vs a later member stored-state compromise | **falsified** (the kept Welcome) | verified | verified | verified | verified |
| T9 | Forward secrecy vs a later committer stored-state compromise | **falsified** (the stored root) | verified | verified | verified | verified |

Note on T2, stage 1, existing circle: this lemma needs more memory than the others. It verifies
in 13,995 steps in about 5 minutes with a 40 GB heap (35 GB peak, 2026-11-19) and exhausts a 14 GB
heap, so a CI runner cannot re-prove it. `VERIFY_BIG=1 docs/formal/verify.sh` re-proves it on a
machine with 48 GB; without that flag `verify.sh` writes the recorded line and says so. It concerns
the superseded stage 1 design only; T2 for the tree that ships (last column) is re-proved in CI.

"v2 tree as built" is [`haven_treekem_v2_built.spthy`](haven_treekem_v2_built.spthy): the tree the
engine runs after stages 1–4 (§14, §16). It differs from the "proposed fix" model in one way that
matters: the design deletes a device's previous-epoch state and its one-time key-package key the
moment it moves on, and the engine cannot (a competing commit may still arrive), so it holds them
until its checkpoint passes that epoch. The model gives the adversary everything the engine holds
at the moment of a leak; its header maps each fact and rule to the code. In it:

* T3 and T4 allow everything the device stored before its Update to leak, key-package secrets
  included, and even its kept previous-epoch state to leak afterwards.
* T8 and T9 are stated by time: everything the device holds leaks at any point after its
  checkpoint passed the epoch. With the deletion at the checkpoint switched off the prover
  falsifies both in 16 steps, so the result rests on that deletion.
* `W_window_exposes_the_previous_epoch` (a trace exists) records the cost: a leak before the
  checkpoint exposes the previous epoch too. The window is 3 commits (§15).
* The column is about a circle on the v2 tree. A circle that has not migrated (a member on an
  old build) is the "stage 1, existing circle" column.
* Stolen signing keys are not an excuse in any of these lemmas, but they are passive statements:
  a device seed lets its holder sign as that device, publish a key package and be re-seated until
  the device is revoked in its account's roster (§17).

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

## 14. Implementing the fix (items 1–5 implemented, not released)

Capability-gated like the `mls` marker (profile value `ml: 2`; a circle re-keys only when every device
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
3. **Key packages.** *Implemented ([`STAGE3-V2-TREE.md`](STAGE3-V2-TREE.md)).* A device publishes a signed (leaf public key, one-time init key); the
   committer Adds from it and Welcomes to the init key. (F-b, F-c.)
4. **Member updates.** *Implemented ([`STAGE4-MEMBER-UPDATES.md`](STAGE4-MEMBER-UPDATES.md)).*
   Receivers accept a path-only commit from any current member; every device runs the weekly
   Update. More concurrent commits means more forks, and under that load the stage-1 fork rule
   (a branch 4 commits deep is final) left devices stranded, so the v2 tree has its own fork
   rule (§15). (F-d.)
5. **Migration.** *Implemented with item 3 (§16.5).* When every member is `ml: 2` and every device
   has published a key package, the creator issues a v2 genesis with random secrets; devices drop
   the v1 tree state at the flip.

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
  bounded. As built, a device checkpoints three epochs behind its tip (`KEYING_FINAL_DEPTH`):
  the window is counted in epochs, not in time, and every device re-keys its own leaf weekly, so
  in a circle with any activity it is days. FK2 is the guarantee from that point on.
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

### 15.1 Which branch wins (v2 tree)

Not modelled in Tamarin: agreement is a property of a pure function of the public commits a
device holds, and is exercised by tests on the real engine (below). The v1 tree keeps the
stage-1 rule. The v2 rule (`keying_v2::best_child`, `chain_index`):

- Every chain of commits has a **weight** `(authority, length)`, compared in that order.
  *Authority* is the number of commits on it that Remove a leaf other than the author's own
  without Adding the same device back, and that only an admin could author. *Length* is the
  number of commits on it, except that **one account's commits in a row count only up to three**
  (`MAX_OWN_RUN`, any of its devices; the account that built the genesis is exempt).
- At a fork a device follows the child with the heaviest chain under it; on equal weight, the
  larger commit hash. There is no depth at which a branch becomes final.
- A device **authors nothing on a tip that is not the agreed one** (exception: an admin's plain
  Remove). A device that cannot derive the agreed tip, because the chain left from a point below
  its checkpoint, asks to **re-enter** (§16.3).

Why this converges where the stage-1 rule did not:

- *The agreed tip's weight only rises.* Commits are only ever added, a weight is a maximum over
  chains, and honest devices extend only the agreed tip. So a branch that has lost never wins
  again by honest action, and the device that authored the agreed tip never left it: there is
  always a device holding the state from which a stranded device can be re-entered.
- *A removed member cannot out-build its Remove.* The Remove is an authority commit; the member
  can author only path-only commits and re-entries, which carry none.
- *A seated member cannot strand the circle by out-lengthening it.* From any fork point one
  account can add at most three to a branch's length. A branch that wins a fork with three
  commits leaves from a point no further than three behind the tip it beats, and every device's
  checkpoint is that far behind its own tip: a fork one account can win is a fork every device
  can still follow. Two colluding member accounts can alternate and are not bounded by this; the
  recovery is an admin Remove, which outweighs any length.

Test evidence (`core/haven-ffi/src/net_tests/keying_v2_tests.rs`; four devices of three
accounts, every device re-keying, delivery delayed, reordered and duplicated; a run passes only
if every device ends on one tip with one epoch secret and **every** post made on the way opens
on every device):

| Max delay | Epochs | Schedules | Converged | Re-entries per schedule | Posts lost |
|---|---|---|---|---|---|
| 2 steps | ≥ 10 | 10 | 10 | 0 0 0 0 0 0 0 2 0 0 | 0 |
| 3 steps (one round) | ≥ 10 | 10 | 10 | 0 0 2 1 2 0 0 2 0 0 | 0 |
| 6 steps (two rounds) | ≥ 10 | 10 | 10 | 2 1 2 2 2 0 0 2 1 3 | 0 |
| 9 steps (three rounds, ignored soak) | ≥ 20 | 16 | 16 | 1 4 3 0 3 4 0 5 4 0 4 4 4 2 3 3 | 0 |

A round is three delivery steps and stands for one update period. Under the stage-1 rule 4 of 7
runs at six steps did not converge. A re-entry is a device that could not follow the agreed
chain and was seated again under a fresh key; it is automatic and not user-visible.

Named cases, each with a mutation that makes it fail: a removed member's twelve commits against
its Remove; a seated member's eight commits against the circle's five; a partition healed by a
plain member's re-entry of the committer's devices; an equal-weight fork decided by hash; a post
sealed on the other branch of a fork.

**Limits that remain, by design or deferred** (none weakens the secrecy results of §13):

- Two or more colluding member accounts with modified clients can alternate commits and
  out-lengthen the circle's chain; every honest device then re-enters. This is denial of service
  by insiders. An admin Remove of those members outweighs any length.
- A member can send one device a path ciphertext that does not open. That device re-enters; the
  others cannot see it happened.
- A stolen device signing key lets its holder publish a key package and be seated until the
  device is revoked in its account's roster. The secrecy results are stated for a passive thief
  of stored state; this is impersonation with a long-term key, as in §15.
- The commit set is not pruned. It grows by one commit per device per week.
- The roster tie (§17) is handled for contacts' rosters, not for an account's own roster as seen
  by its seedless devices.
- Returning a migrated circle to a build older than this one is not supported.

**Content keys across a fork.** A content key is filed under the tree's epoch *number*, which
both branches of a fork share. A device that moves to the other branch replaces the key (and
drops the DM ratchets derived from the old one). An envelope that does not open under the key a
device holds for a tree epoch is kept in the retry buffer, not dropped — the mailbox serves the
same bytes once — and is retried whenever a tree wire lands; it ages out with its epoch.

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
  that entry point is past the retention window (§15). Until then the opened Welcome is kept
  as the device's entry point (stage 1), and it is wiped at the same checkpoint.

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
(`tree_hash`). The Welcome must be sealed by that commit's author, and the delivered
`joiner_secret` must key the commit's confirmation MAC — anyone can seal to a published
one-time key, so without this a sender could choose the joiner's epoch secrets. A joiner
therefore never enters a state described by a Welcome alone (`enter_via_welcome_v2`).

### 16.3 Membership commits

```
TAG_MLS2_COMMIT = 0x11    a treekem::Commit on a v2 chain      TAG_MLS2_JOIN = 0x13    the v2 join ack
```

The v2 tree has its own tag family (`0x10`–`0x13`) instead of reusing the v1 tags: a v1 build
that receives a v2 commit under the v1 tag would park it as an orphan and retry it, and a v2 join
ack under the v1 tag would trigger a v1 re-Welcome. Unknown tags fall through harmlessly
(checked against the `v2.1.2` router: a per-envelope parse error, not parked, not retried).
The v2 join ack names the entry commit, so a re-entered device acks again.


- **Genesis** is built by the elected creator once it holds a valid key package for every
  authorized device; the Adds carry the packages' leaves verbatim. `init_0`, the creator's own
  leaf secret and all path entropy come from the OS RNG. The v2 genesis parent constant uses a
  new domain (`haven-mls-genesis-parent-v2`), so v1 and v2 chains can never be spliced.
- **Add** needs the new device's key package. **Re-entry** (a device stranded on a losing branch
  or asleep past retention) is a `Remove(old leaf) + Add(new key package)` in one commit — there
  is no separate "re-Welcome" that re-delivers an old leaf secret, because nobody but the device
  ever had it.
- **Re-entry may be authored by any current member**, not only an admin: a commit of k pairs
  `Remove(L) + Add(package)` where each package is signed by the same device and account that
  sits at `L`, `L` is never the author's own leaf, and the usual Add checks hold (device
  authorized in the roster, package used once on this chain). Membership does not change, and
  the device comes back under a key only it holds. The committer does it at once; any other
  device does it at once when the device asking is a committer's, and otherwise after one hour
  plus up to six (per device and package), so the committer normally gets there first. A device
  entering through a member's commit waits until it holds the commit's parent tree; it does not
  take a member's word for what was removed.
- **Remove** is unchanged: admin-authorized, or a member removing only its own leaves.
- A device seated under a package it holds whose Welcome has not arrived after one hour takes it
  for lost and offers another package; it is then re-entered like any other device.
- A device entering by a Welcome opens, from the public entry commit, the path secrets of the
  nodes its path shares with the committer's (`entry_path_secrets`). Without them it could not
  follow the next Update from a third device.

### 16.4 Member updates (F-d)

A commit with **no proposals** and an UpdatePath is valid from **any current leaf** when:

1. the UpdatePath leaf's credential names the same device as the sender's current leaf;
2. that device is **listed** in its account's verified roster, authorized or revoked;
3. the leaf binding and the commit signature verify under that device (`verify_leaf`);
4. the new leaf key differs from the one it replaces.

Rule 2 is "listed", not "authorized now", so that whether an Update is valid does not depend on
when a receiver learned of a revocation: a device that learned it first would refuse a commit
the rest of the circle built on. A revoked device is cut out by the Remove that follows, which
no number of Updates outweighs (§15.1).

Cadence: each device updates its own leaf at the weekly full-bundle chokepoint, offset by a
per-device jitter so devices do not collide by construction. The week is counted from when **the
key at the device's leaf on its adopted tip** was installed, so an Update that lost a fork is
re-issued at the next bundle (§15, FK4/FK5) and a commit that lost for another reason does not
trigger one. A device does not author on a tip that ends three commits in a row by its own
account. The update's leaf secret and entropy are random, stored with the pending commit, and
dropped at the checkpoint. A commit whose confirmation MAC fails for a device that opened its
path secret is void for every device and is never selected by the fork rule.

### 16.5 Migration (no user-visible step)

- New capability value `ml: 2` in the profile, monotonic and learned-never-inferred like `ml: 1`.
- While any member account is `ml: 1`, the circle stays on its v1 tree (with stage 1–2 hygiene
  on upgraded devices). Nothing is emitted that a v1 build cannot ignore.
- When every member account is `ml: 2`, devices publish key packages while the **v1 tree stays
  live and keeps keying content**. The creator builds the v2 genesis only once it holds a valid
  package for every authorized device, so one device on an old build simply leaves the circle on
  v1. Each device files the v2 epoch's content keys as soon as it can derive them, and flips its
  own authoring to the v2 lane when the v2 tree is all-joined; in the same step it wipes the v1
  tree and stops emitting v1 wires. The circle never parks during migration. Posts are never
  re-encrypted or lost: the content path only ever sees 32-byte epoch keys, and the daily
  re-seal republishes history under whichever key is current.
- After the flip, an authorized device with no key package (a new device on an old build) parks
  the circle on the KeyCommit lane until it is Added; a member account advertising `ml: 1`
  brings the v1 tree back from a new genesis.
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

**F5 — A revocation can be ignored on a version tie (low; fixed for contacts' rosters, not
released).** For a contact's roster, `store_verified_roster` returned `AlreadyCurrent` when the
incoming version equalled the stored one, without comparing contents. If two seed-holding devices of one account sign different
rosters with the same version (each bumped from the same base before seeing the other), a
contact who stored the one without the revocation never takes the one with it. The contact keeps
treating the revoked device as authorized — and keeps sealing to it — until a seed holder that
has seen both publishes the merged, higher version (`DeviceList::merge`, which keeps a
revocation on a tie). Reachable only for accounts with more than one seed holder; an outsider
cannot cause it. The fix is verifier-side and fail-closed (`apply_roster_tie`): on an
equal-version roster that verifies but differs, every device revoked in *either* is treated as
revoked until a strictly newer roster arrives; the verdict is stored and survives a restart.
Still open: the same tie on an account's **own** roster as seen by its seedless devices, and a
tied roster is not relayed to other contacts.

## 18. Deterministic event seal: what an observer can tell apart

Model: [`haven_deterministic_seal.spthy`](haven_deterministic_seal.spthy) (Tamarin `--diff`,
observational equivalence; five variants, one question each). Code: `seal_event_in_epoch`,
`seal_reproducible`.

`salt = PRF_ek(m)`, `event_key = KDF(ek, salt)`, envelope `= ⟨salt, senc(m, event_key)⟩`. The
same event under the same epoch key seals to the same bytes, on purpose: the mailbox is
content-addressed, so a re-sealed event dedupes. The observer is a relay or network attacker
without the epoch key.

| Variant | Question | Result |
|---|---|---|
| UNIQUE | One envelope; the plaintext is one of two fresh events. Can the observer tell which? | no (equivalence verified) |
| UNIQUE + ORACLE | Same, and the observer can have plaintexts of its choice sealed | no (verified) |
| RESEAL | The same event twice, versus two different events | **yes** (trace found) — the dedup property |
| GUESS | One envelope; the plaintext is one of two values the observer knows | no (verified): guesses cannot be tested without the epoch key |
| GUESS + ORACLE | Same, and the observer can have plaintexts of its choice sealed | **yes** (trace found) |

What this says about Haven:

- An observer learns **that two envelopes in the same epoch are the same event** and nothing
  else about content. Across epochs the keys differ, so the daily re-seal under a new epoch is
  not linkable this way (size and timing still are; envelopes also carry sender and circle ids
  in the clear — metadata, outside this model).
- The scheme relies on **events being unique**: every event carries a random id and a timestamp,
  so two different posts never share a plaintext. The last row is why that matters — if a member
  could be made to seal an attacker-chosen plaintext equal to a guessed one, the guess could be
  confirmed. No code path seals attacker-supplied bytes as a whole event; keep it that way.
- Symbolic limits: this treats the 16-byte truncated PRF output as collision-free and AES-GCM
  as ideal. A salt collision between two different events under one epoch key (about 2⁻⁶⁴ per
  pair) would reuse a GCM key and nonce; that bound, and the PRF/KDF assumptions, belong to the
  computational analysis in §10-4.
