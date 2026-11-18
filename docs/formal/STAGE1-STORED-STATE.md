# Stage 1 of the TreeKEM keying fix — stored, checkpointed state with random secrets

Status: design for the implementation on this branch. Scope is `PROTOCOL-SPEC.md` §14 items 1–2
(F-a, and the "kept Welcome" half of F-c). No wire format changes. Everything below was read
from `core/haven-ffi/src/lib.rs` and `core/haven-p2p/src/treekem.rs` at commit 464c5d18.

Not for publication until the later stages ship: it describes weaknesses that remain.

## 0. What the code does today (the parts this stage touches)

* `mls_replay` is a pure, memoised function of `{commits, my_welcomes, device seed}`. It starts
  from every entry point the device holds (the elected genesis' Welcome, and every self-contained
  Welcome), walks each forward with `replay_walk`, and keeps the best end by
  `(on the elected genesis, epoch, tip hash)`.
* `replay_walk` picks, at each epoch, **the child with the largest commit hash**. There is no
  chain-length rule below the genesis. `TREEKEM-DESIGN.md` §5.1 says "chain extension beats
  hash"; in the code that holds only for the genesis election (`keying_winning_genesis` ranks by
  `keying_chain_height` first). This matters for (b).
* A device's own commits are reproduced by rebuilding them (`keying_rebuild_own_commit`) from
  `keying_update_material(root, epoch)`, `root = H(device seed, group)`. The rebuild result is
  used without being compared to the stored commit.
* The committer assigns every leaf secret as `keying_leaf_secret(root, device)` and re-derives it
  in `mls_rewelcome_device`; the genesis init is `keying_base_init(root)`.
* Nothing is ever deleted: `ShadowTree.commits` and `ShadowTree.my_welcomes` only grow, and
  `PersistShadow` writes both, plus `my_secret_root` (which no code reads back).
* `treekem::PersistTree` and its pruner exist but the engine does not use them.

## (a) What a checkpoint contains

A checkpoint is the device's complete keying state at one epoch `c` of the chain it is on. It
is the same thing a self-contained Welcome gives a joiner, minted locally, plus what a
self-contained Welcome cannot carry. `replay_walk` continues from it exactly as it continues
from a Welcome start.

| Field | Why |
|---|---|
| `epoch` | where the walk resumes |
| `tree` (public, serialized) | `apply_commit` / `build_commit` need the pre-commit tree |
| `my_private`: leaf index, leaf secret, path secrets | to open the next UpdatePath, or to commit |
| `init_secret` | salt of the next epoch's schedule; the one secret that links forward |
| `sender_root`, `joiner_secret` | only so the checkpoint is a usable live state if the walk ends on it (content keys; a committer's re-Welcome at that epoch) |
| `cth` (confirmed transcript hash) | input to the next transcript hash and confirmation MAC |
| `tip_hash` | the commit this state is the result of; children are found by `parent == tip_hash` |
| `genesis` | the epoch-1 commit it descends from, for the `on_winner` ranking if the parent links were ever unavailable |
| `removed_me`, `removed_devices` | removal is sticky; today that set is only correct when replayed from genesis, so it has to be carried |

Not in it: any `commit_secret`, any epoch `< c`, the genesis init, any Welcome.

`TREEKEM-DESIGN.md` §6.3-1 says `init_secret` must never be persisted. That sentence cannot
hold for the *current* init secret once replay-from-genesis goes away: it is the forward link,
and without it the device cannot continue. What must not be persisted is an init secret of an
epoch the device has moved its checkpoint past, and that is what this stage enforces.

The public commit set stays as it is (kept in full). It is public, and the genesis election
(`keying_winning_genesis`, `keying_chain_height`, `keying_genesis_of`) reads all of it.

## (b) When the checkpoint may advance, and what is deleted

**The problem.** Deleting the state of epoch `k` means the device can never again switch to a
branch that forks at `k`. Today's walk rule is hash-only, so a single late commit on an old tip
(for example a second device of the creator account that slept for a month and authors its
weekly Update before it syncs) wins its fork half the time, however long the other branch has
grown — and every device follows, because every device replays from genesis. With deletion,
devices that have checkpointed past the fork point cannot follow, and the fleet splits. No
retention period measured in epochs or days removes this: the stale author can be arbitrarily
stale. So deletion needs a rule that makes old fork points final.

**The rule (the one change to fork selection).** `F = KEEP_EPOCHS = 4`. In `replay_walk`, when a
tip has two or more children, a child whose chain (itself plus its longest line of descendants)
is at least `F` commits long is *final*. Final children beat non-final children; within the
same class the larger hash wins, as now. This is §5.1's chain rule, applied only at depth `F`.

* With no fork, or with every branch shorter than `F`, or with every branch at least `F`, the
  result is identical to today's. Forks at circle birth (the genesis races) are untouched.
* It is a pure function of the public commit set, so devices holding the same commits agree.
* It differs from today only when a branch of depth ≥ `F` competes with a shorter branch that
  has the larger hash. Those are exactly the forks a checkpointed device could not follow.

**The checkpoint.** After each replay, with best end at epoch `n` on a path that is at least `F`
states long from its start, the checkpoint becomes the state at epoch `n − F + 1` on that path
(never moving backwards on the same path). Every fork point below it then has the device's own
branch final (`n − k ≥ F`), so the walk rule would not leave it. If the best path is shorter
than `F` from its start (a new circle, a fresh Welcome), nothing is checkpointed and nothing is
deleted: the first `F − 1` epochs after any entry behave exactly as before. That is deliberate —
the genesis-election heal (`mls_rewelcome_device` on a divergent join ack) lives there.

**Deleted (wiped) when the checkpoint is at `c`:**
* the previous checkpoint;
* every held Welcome with `epoch < c`, and the Welcome whose tip is the checkpoint's tip
  (exception: a Welcome onto the *elected* genesis is kept while the checkpoint is on a
  different genesis — that is the door the existing fork heal uses);
* every own-commit build record (see (c)) with `epoch ≤ c`.

The same test is applied when a Welcome arrives (a re-delivered old Welcome must not put an old
`joiner_secret` back) and after `import_state` (an old blob must not resurrect one — §6.3-5).

`KEEP_FORKS` does not enter: the engine has no fork cache (losing-branch content keys simply
stay in `my/peer_epoch_keys` under their epoch until `prune_epoch_keys` drops them).

**What this does not cover** — see §"Not verified" at the end.

## (c) Reproducing own commits

`apply_commit` cannot apply a device's own commit (the path secrets are wrapped to everyone
else), so a walk that passes through an own commit still has to rebuild it. With random
secrets the inputs are stored instead of derived: per own commit, keyed by commit hash,
`(parent tip, epoch, new leaf secret, encapsulation entropy)`. The rebuild is now checked
against the stored commit (tree hash and confirmation MAC) before its result is used.

Records are deleted once the checkpoint reaches their epoch. A record with no checkpoint yet
past it is what lets the device re-walk through its own commit after a fork flip.

An authoring guard is needed that determinism used to provide for free: the builders returned
"already authored" when a rebuild produced the same hash. With random material a replay that
failed to advance past an own commit would mint a new sibling on every bundle. So a builder
refuses to author on a tip for which an own build record already names that tip as parent.

The save-before-send contract (`key_state_unsaved`) already covers this: authoring adds a
commit, the digest changes, the app exports before sending.

## (d) Existing circles

* **Commits already authored under seed derivation.** If an own commit has no build record, the
  walk falls back to `keying_update_material(H(seed, group), epoch)` — and now verifies the
  result. The fallback is only reachable for commits above the checkpoint; once the checkpoint
  passes them the seed is no longer consulted.
* **A device that holds only a kept Welcome.** It loads as before, replays as before, and at its
  first refresh with a chain ≥ `F` long from that Welcome it checkpoints and wipes the Welcome.
  A device whose chain is shorter keeps its Welcome until it is.
* **Persisted `my_secret_root`.** Read and discarded; written as absent from then on.
* **Sleepers (`mls_rewelcome_device`).** The Welcome wire still carries the device's leaf
  secret, so the committer must still be able to produce it. It looks in its stored assignments
  first (new Adds, new circles), then falls back to `keying_leaf_secret(H(seed, group), device)`
  for leaves assigned before this change. Stored assignments are wrapped under a pad derived
  from the committer's device seed (`keying_wrap_assigned_leaf`), so the stored map alone does
  not hold them. The existing "delivered secret matches the tree leaf"
  check already rejects a wrong one.
* **Mixed fleets.** Commits and Welcomes are byte-compatible in both directions. Older builds
  loading a newer blob ignore the new fields; a downgrade after a checkpoint has wiped the
  Welcomes leaves that device unable to replay (it parks to the KeyCommit path). Not supported.

## (e) What stops being persisted or derivable, and what does not

Stops:

| Secret | Before | After |
|---|---|---|
| keying root | persisted in every committer blob | not persisted |
| update leaf secret + entropy of a new commit | `H(root, epoch)` | random; stored until checkpointed, then wiped |
| genesis init, leaf secrets, of a circle created from now on | `H(root)`, `H(root, device)` | random |
| a member's entry Welcome (`joiner_secret`, leaf secret) | kept for ever | wiped once the checkpoint passes it |
| `init_secret` / `joiner_secret` / `sender_root` of epochs below the checkpoint | recomputable from the blob at any time | not in the blob, not derivable from it |
| tree-derived content keys older than the last 4 epochs | never pruned on the tree path (only the KeyCommit path called `prune_epoch_keys`) | pruned on every keying refresh |

Still persisted or derivable until later stages:

* **Every member's leaf secret is still recoverable by the committer.** For leaves it assigns
  from now on it takes the committer's seed *and* its stored state (the stored copy is wrapped
  under a seed-derived pad); for leaves assigned before, the seed alone (`H(root, device)`). A
  commit's path secret is wrapped to those leaf keys, so whoever has them opens every later
  commit. Stages 3–4 (own leaf keys) remove this.
* **In a circle whose genesis predates this change, nothing improves against the committer's
  seed** until a re-genesis: `init_0` and the old leaf secrets are functions of the seed, so the
  whole chain, including commits authored after the upgrade, can be recomputed from the seed and
  the public commits. Stage 5.
* **Welcomes are wrapped to long-term device KEM keys**, and the committer keeps the sealed
  Welcomes in `emit_cache`. A recorded Welcome plus the member's seed yields that epoch's
  `joiner_secret`. Stages 3–4.
* **Ordinary members never update their leaf**, so a member's stolen state keeps opening new
  commits. Stage 4.
* **The retention window itself**: the checkpoint state, the build records and the content keys
  of the last `F` epochs are in the blob by design.

## What stage 1 does not fix (summary)

No healing after a member's state is stolen (T4): members never update. No forward secrecy
against a member's seed (T6): the Welcome is wrapped to a long-term key. For circles created
before the change, no forward secrecy or healing against the committer's seed either (T5, T7):
their leaves and genesis init are still functions of it. And nothing here helps against an
attacker holding a committer's seed and stored state together.

What it does give: the committer's Update heals a theft of its stored state (T3); no secret of
a checkpointed epoch survives in a device's stored state (T8, and T9 for the committer); and for
circles created afterwards the committer's seed alone reveals nothing (T5, T7). The model
results are in `PROTOCOL-SPEC.md` §13.

## Not verified

* **Two branches that are both ≥ `F` deep.** Two committer devices that each author four or
  more commits without seeing the other's. Final-versus-final is decided by hash; a device
  checkpointed on the losing side cannot follow and stays there until a committer on the other
  branch re-Welcomes it (and the device drops a re-Welcome whose epoch is below its checkpoint).
  Before this change every device would have converged by replaying from genesis.
* **Mixed fleets during rollout.** On a fork where a ≥ `F`-deep branch has the smaller hash,
  older builds take the short branch and newer builds the long one, until the older build
  upgrades. Not exercised by any test here; needs the e2e fleet.
* **A committer restored from an older state blob.** It no longer holds the inputs of its own
  later commits and cannot rebuild them from the seed (that was the flaw). It stays at the
  restored epoch until another committer device re-Welcomes it; a single-device creator has no
  such device. Seed derivation made this case recover by accident.
* **A genesis election that flips after a checkpoint.** It needs the other genesis' chain to
  outgrow one that is already ≥ `F` deep; same shape as the first item.
* Fork resolution has no formal model (`PROTOCOL-SPEC.md` §10-3). The finality rule is tested
  in core only.
