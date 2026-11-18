# Stage 4 of the TreeKEM keying fix — every device re-keys its own leaf

Status: design note for the implementation on this branch. Scope is `PROTOCOL-SPEC.md` §12 F-d,
§14 item 4, §15 (the three rules for the implementation) and §16.4, plus three defects fixed in the
same files (§7–§9 below). It builds on [`STAGE1-STORED-STATE.md`](STAGE1-STORED-STATE.md) (the
checkpoint, the build records, the finality rule) and [`STAGE3-V2-TREE.md`](STAGE3-V2-TREE.md) (the
v2 tree). Code: `core/haven-ffi/src/keying_v2.rs`, hooks in `core/haven-ffi/src/lib.rs`, one
constant in `core/haven-p2p/src/treekem.rs`. Tests: `core/haven-ffi/src/net_tests/keying_v2_tests.rs`.

Not for publication before release: it describes weaknesses that remain (§10).

Everything here applies to the **v2 tree only**. The v1 tree's rules, wires and cadence are
untouched: only its elected committer updates, on the circle's `rotated_at` stamp.

## 1. What is accepted (§16.4)

`check_commit` — the public check every v2 commit passes before it is stored — now starts with one
more case. A chained commit with **no proposals** is a member update and is valid from **any current
leaf**, admin or not, when `keypackage::verify_member_update` passes against the public tree the
commit extends, and the roster rule holds:

1. it carries an UpdatePath and no proposals;
2. the new leaf names the same device **and** account as the leaf at `sender_leaf`;
3. the leaf key differs from the one it replaces;
4. the credential chains to the pinned account key, the leaf binding is signed by that device for
   this circle, and the commit signature verifies under that device;
5. the device is authorized in its account's verified roster (not known yet → retried later, as
   for every other roster-dependent check).

It must then apply to the parent tree with the tree hash it claims (`step_public`, unchanged).

A commit that carries proposals goes through the rules it always did: admin, or a leave that
removes only the author's own account's leaves. Rule 3 now also applies to an admin's path-only
commit (it always held: the new leaf secret is random).

A path-only commit cannot be an entry point: a device entering mid-chain checks the one commit its
Welcome names without the chain below, and that check still refuses a path-only commit from a
non-admin.

## 2. When a device authors one

`member_update`, called from `emit_bundle` on the **full bundle** only — the bundle that re-seals
the author's history, the one place an epoch may move, where the committer's weekly Update already
fired. It runs for every device, after the committer's roster reconciliation.

A device re-keys its own leaf when all of these hold:

* the tree keys content on this device (all present, all joined — the gate the committer's Update
  already had), and the device's own roster authorizes it;
* its **own** window has elapsed (below);
* its tip has no child from its own leaf (`keying_already_authored_on`, unchanged);
* its tip does not end a run of three commits of its own (§5).

**The window is per device.** The v2 state gains `leaf_at` (when the leaf key of my current seat
entered the tree — at my genesis or at the Welcome I accepted) and `last_update` (the last commit I
authored, with the id of the leaf key it installed for me; every commit re-keys its author's leaf,
so a committer's Add/Remove commit counts). The circle-wide `rotated_at` is no longer read on a v2
tree.

| My last commit | Due |
|---|---|
| none from this seat | `7 d + offset` after `leaf_at` |
| its leaf key **is** the key at my leaf on my tip | `7 d + offset` after I authored it |
| its leaf key is **not** the key at my leaf on my tip | now |

`offset = BLAKE3("haven-mls-update-jitter-v1" ‖ device id ‖ circle id) mod 24 h` — fixed per device
and circle. Devices that entered together (a genesis, the migration) come due spread over a day, and
since each device's period differs they do not re-align.

**"On the adopted chain" is decided by the leaf key, not by a parent walk.** Only my own commits
install a key at my leaf (§1 rule 2; a re-entry replaces the leaf with a key-package key and clears
`last_update`), and each installs a fresh random one. So "the key at my leaf on my tip is the key my
last commit installed" is exactly "my last commit is my tip or an ancestor of it". It needs no
commits below an entry point and costs one comparison.

**Re-issue (FK4/FK5).** The third row: my Update lost a fork — the chain I adopted does not carry
it — so my leaf is not healed there. I author a new one at my next full bundle, on the tip I have
adopted. The first guard keeps this from minting a sibling of my own commit. In a k-way collision
one Update wins per round and the k−1 losers re-issue: k rounds, then quiet.

`rotated_at` is still stamped by the commits that stamped it before (an admin's, a leave); a plain
member's Update does not touch it.

## 3. The old leaf secret (§15)

Nothing new had to be deleted — the stage-1 checkpoint already owns every copy — but one copy was
outliving it:

| Where the superseded leaf / path secrets sit | Dies |
|---|---|
| the checkpoint's private state | when the checkpoint moves to the Update's epoch or past it |
| the entry Welcome, the key package it came from | when the checkpoint passes the entry (earlier) |
| own build records of earlier (or losing) commits | when the checkpoint reaches their epoch |
| **the replay memo** (states of the last walk) | **now cleared when the checkpoint moves** |

The memo is a cache of the last two replays; its entries held the states of the walk that led up to
the checkpoint move, including the one below the Update, until two later replays pushed them out. `keying_checkpoint_pass` now clears it when
the checkpoint changes (for both trees — it is only a cache). Between the Update and the checkpoint
the old leaf secret is still held, in the checkpoint: a competing branch that forks below the Update
is still followable.

The checkpoint is three commits behind the tip, so the old leaf secret dies when the third commit
after the Update lands.

## 4. Retention, and why there is no age-based checkpoint (§15)

In commits (unchanged from stage 1/3): an entry Welcome and its one-time seed are wiped when **3**
commits have landed after the entry; a superseded leaf secret when **3** commits have landed after
the Update; an epoch's own secrets (`init_secret`, `sender_root`) when **4** have landed after it.

In time, for a tree that keys content, counting only devices that run full bundles (each authors at
least once per `7 d + offset < 8 d`; a lost Update is re-issued at the next full bundle, so add one
bundle interval per collision):

| Devices committing | 3 commits | 4 commits |
|---|---|---|
| N ≥ 4 | < 8 d | < 8 d |
| N = 3 | < 8 d | < 16 d |
| N = 2 | < 16 d | < 16 d |
| 1 (everyone else silent) | < 24 d | never while it stays alone (§5) |

Before this stage: 3–4 weeks if a committer device was active, unbounded if not.

Still unbounded: a tree that does not key content (no Updates are authored on it — it keys nothing,
so what it retains opens no content), a device that is not running, and the last line of the table.

An age-based checkpoint was **not** added. For the last line it would be unsafe: a device that
checkpoints its own tip can no longer follow a commit authored on an older tip, and that is exactly
what a silent device does when it wakes — it comes due and authors on the tip it last saw. While the
lone device's run is at most three commits its checkpoint is still at the fork point and it follows
whichever branch the fork rule picks.

## 5. Fork load, and the limit on a device's own run

More authors means more forks. Two things were looked at.

**Collisions under delay.** The test harness: five devices of three accounts; each round two or
three of them come due at once and author on whatever tip each holds, one device posts, and a
random half of the fleet sends two more bundles; every envelope is delayed a random number of
steps, delivered in random order, one in five twice. A round is three steps and stands for one
update period.

| Max delay | Schedules | Converged with no re-entry | Deepest losing branch |
|---|---|---|---|
| 2 steps (the default test, 10 epochs) | 2 per run | all | — |
| 3 steps = one round (10–14 epochs) | 11 | 11 | 3 commits |
| 6 steps = two rounds (16+ epochs) | 7 | 3 | ≥ 4 |

So: while delivery lags by less than one update period, losing branches stay below finality depth
(though only just: 3 of 4) and the fleet converges with no device re-entering. **With a lag of two
periods the stage-1 finality rule strands devices.** One failing run, as the harness printed it:

> device 1 offered a key package: own tip at epoch 14, agreed tip at epoch 15, they fork at epoch
> 5, checkpoint at 11; own side authored by devices 1, 2, 3, 4 (9 commits), agreed side by devices
> 0 and 4 (10 commits).

Two groups each built four or more commits on the same tip before seeing the other's. Both
branches were final, so the fork was decided by hash; the devices on the losing side had already
checkpointed past the fork point and could not switch. They then asked to re-enter (the agreed
chain was longer) and the fleet did not settle: in the other failing runs a device ended an epoch
behind, the circle fell off the v2 tree, or the public view and a device's own tip still disagreed
after 96 rounds. The rule that does it is not new (`STAGE1-STORED-STATE.md`, "Two branches that
are both ≥ F deep"); what is new is that it no longer takes two committer devices and four weeks —
any two groups of devices do it in the time each needs for four commits, and a re-issue adds a
commit to a side without waiting for a window. Reproduce:
`cargo test -p haven_ffi --lib fork_load_soak -- --ignored --nocapture` (fails at its default
delay; commit hashes are random, so a seed fixes the schedule, not the winner). Nothing here
repairs it.

**A device that authors alone.** The stage-1 rule makes a branch four commits deep final, and a
device checkpoints past a fork point once its own chain is four past it. Before this stage only a
committer authored, so a device that kept committing while cut off simply delivered its commits
late. Now the rest of the fleet commits too: a device cut off for four of its own windows would hold
a final branch of its own, checkpointed, while the fleet holds another — final against final is
decided by hash, neither side can switch, and (stage 3) a device whose own branch is not shorter
than the agreed one does not even ask to re-enter. For a committer device that is permanent.

So a device **does not author an Update on a tip that ends three commits of its own**
(`MAX_OWN_RUN = KEYING_FINAL_DEPTH − 1`; a genesis is not counted). A branch only one device wrote
never reaches finality depth, that device's checkpoint never passes the fork point, and when it
reconnects it adopts the fleet's branch from the state it still holds and re-issues its Update
there. Test: `a_device_cut_off_from_the_circle_cannot_make_its_own_branch_final`.

The cost: a device that is the only one committing stops after three Updates until any other
device's commit lands. This also applies to a committer on a v2 tree, which before this stage
updated weekly without limit. Membership commits (Add/Remove/re-entry) are not limited.

What this does not cover is in §10.

## 6. A commit whose confirmation MAC is wrong is void

Stage 3 left this open for a malicious admin. With member updates any member could do it: publish
an Update that passes every public check and has a wrong confirmation MAC. Every walk stopped
behind it while the public view moved on, and every device asked to re-enter.

`apply_commit` verifies, level by level, that the path secret a receiver decrypted derives the
public keys in the UpdatePath. So when it then reports a MAC mismatch (`treekem::ERR_CONFIRMATION_MAC`),
the commit secret is the one the path's public keys fix and the init secret is the parent epoch's:
the verdict is the same for **every** device that holds the parent epoch and is not removed by that
commit. On a v2 tree `replay_walk` therefore treats such a commit as void and carries on with the
next-best child; the hash goes into a persisted set (`V2State::void`) at the next checkpoint pass,
and from then on the fork rule (`keying_best_child`), the finality count (`keying_chain_reaches`)
and the public view (`keying_v2::canonical`, hence `wants_entry` and `mls_shadow_status`) all skip
it. Persisted because the verdict cannot be re-derived once the checkpoint has passed the parent.

Only that one error is treated this way. A path ciphertext that does not open, or a path whose keys
do not match the decrypted secret, can be aimed at one device and still stops that device's walk.

## 7. Roster version tie (finding F5, §17)

`store_verified_roster`, contact rosters only. An incoming verified roster with the **same version**
as the stored one and different contents no longer returns `AlreadyCurrent` unseen:

* every device revoked in the incoming roster is added to the stored roster's `revoked` set, and the
  account leaf is retired if the incoming one says so. Nothing is ever authorized by a tie: a device
  listed only in the later-arrived roster stays unknown, as before;
* the widening is applied to the one stored `DeviceList` every reader already goes through
  (`device_lists[account].list`), so no call site can miss it;
* if that changed what is authorized, the same steps run as for any newly learned revocation
  (`roster_changed`: rotate the sender-key epoch of the circles the account is in, reconcile the v1
  tree; the v2 tree reconciles on the next bundle) and the result is `Stored`. Otherwise
  `AlreadyCurrent`. The same roster again — either one — changes nothing;
* the widened list no longer matches a signature, so the rosters **as signed** are kept beside it
  (`NetState::roster_ties`): the first-stored one is what the state blob saves as the roster and what
  is relayed to the account's other devices; the others are saved in a new blob field
  (`roster_ties`, not written while empty), re-verified and re-applied on load, without rotating;
* a strictly newer roster replaces the stored one and drops the tie.

No wire format and no signed bytes change.

## 8. Logging

`mls_shadow_status` logged the epoch secret in hex at `info`. Removed, with the derivation that only
existed to feed the log line. No other log statement in the keying code (`mls_*`, `keying_*`,
`shadow_*`, `keying_v2.rs`, `treekem.rs`, `keypackage.rs`) formats secret material; the remaining
ones print the circle id, the epoch number, the public tree hash and the fork count. No test
depended on the removed field, so no fingerprint was added.

## 9. Persisted state

* v2 tree state (`keying_v2::encode_state`) is version 2: version 1 plus a tail — `leaf_at`, the last
  own commit, the void set. Version 1 still decodes; its device starts its window at the first
  check (it does not come due at once). A build before this stage does not read version 2 (it
  ignores the v2 tree state and offers a key package); downgrade stays unsupported.
* `PersistState::roster_ties`: defaulted, not written while empty.
* A state with no v2 tree and no roster tie serializes byte-for-byte as before. `mls_keying` off:
  no code path added here runs (`gate`).
* `key_state_digest` covers the new v2 fields, so an authored Update and a void verdict reach disk
  before the envelopes built on them leave.

## 10. Not covered, not verified, risks

**Not done / not verified**

* No model re-run; no `.spthy` was touched. Tests are core Rust only; no e2e or simulator fleet.
* Re-issue happens at the next **full** bundle, not at any bundle: a head-only bundle must not move
  the epoch (the reason the weekly rotation lives on the full bundle).
* The roster tie is handled for contacts' rosters. A **seedless** device's view of its *own*
  account's roster adopts by strictly-higher version too and has the same tie; not changed.
* The tied rosters are not relayed to the account's other devices (only the first-stored signed
  roster is, as before); each device applies a tie when it receives both itself.

**Risks that member updates create or widen**

1. **A member can out-build a commit it does not like.** Any member can now author commits, alone
   and as fast as it likes. A modified client that sees an admin's `Remove` of itself can author
   four Updates on the Remove's parent: its branch is final, the Remove's is not, every device
   follows the member's branch, and the admin has to Remove again on the new tip — indefinitely.
   The same lets a member fork the fleet below devices' checkpoints (final against final, by hash),
   after which the losing side has to re-enter. Before this stage a non-admin could author only a
   leave. The own-run limit (§5) is an honest device's rule; it is not a validity rule, because a
   member with two devices can alternate them. This needs a fork rule that does not let commit
   count alone confer finality; it is not attempted here.
2. **Two groups of devices that each author four commits without seeing the other** end with two
   final branches (the stage-1 "both ≥ F deep" case). Before this stage that took two committer
   devices and four weeks; now any two groups with two devices each get there in two weeks, and a
   re-issue cascade after a flip can add up to three commits to a side in a few bundles. It needs
   delivery between the groups to lag that long. **Reproduced** by the soak at a lag of two update
   periods (§5): 4 of 7 schedules did not converge without re-entry, and some did not converge at
   all. Recovery is by re-entry, which needs a committer on the winning side; a circle whose only
   committer device is on the losing side has none.
3. **Roster-dependent validity** (stage 3, open). Rule 5 is evaluated against the roster as the
   receiver holds it *now*. Schedule: device X's Update U is adopted; X is then revoked; device D,
   offline since before U, learns the revocation before it processes U. D refuses U, cannot store
   anything built on it, stays at the epoch below U, and — its public view being stuck there too —
   never asks to re-enter. Before this stage this needed X to be a committer device (or an Add of
   X); now every device authors weekly. Relaxing rule 5 to "listed in the roster, revoked or not"
   would make validity independent of roster timing and leave revocation to the Remove commit, at
   the price of letting a revoked, still-seated device author until that Remove lands (and try
   risk 1). That is a protocol decision; rule 5 is implemented as specified.
4. **A targeted bad path.** A member can send one device a path ciphertext that does not open while
   the commit is valid for everyone else. That device's walk stops; it re-enters once the agreed
   chain is ahead of it. Costs a `Remove + Add` per victim per commit; it cannot be made void
   because the other devices cannot see it.
5. **A device that cannot check a void commit.** A device that entered above a void commit's parent
   cannot derive the verdict. Its public view may then follow a branch built on the void commit if
   its author extends that branch to finality depth (risk 1 again).
6. **Growth.** The public commit set is never pruned (stage 1 kept it for the genesis election) and
   `keying_chain_height` re-parses it per level. One commit a week became N a week plus collisions:
   state size and replay cost under the engine lock grow N times faster. Needs pruning below the
   checkpoint before a large circle runs this for years.
7. **Epoch churn.** N epochs a week instead of one: each moves the content epoch and has every
   client re-seal its history at its next full bundle.
8. **Void set.** One 32-byte hash per void commit, kept for good; a member can add to it at will
   (each costs it a signed commit that everyone stores anyway — see 6).

## 11. Tests

All in `core/haven-ffi/src/net_tests/keying_v2_tests.rs`. "Teeth" = the named change to the code
was made, the test was run and failed at the assertion it is about, and the change was reverted.

| Test | Shows | Teeth |
|---|---|---|
| `a_plain_member_rekeys_its_own_leaf_and_its_stolen_state_stops_working` | a non-admin, non-committer device's Update is authored, stored and followed by every device; a copy of its whole state from before cannot get past it (T4) | not mutated (the build before this stage neither authors nor accepts it) |
| `a_member_update_is_accepted_only_for_the_authors_own_fresh_leaf` | refused: unchanged leaf key, another device's leaf, a plain member's Remove, a revoked device's Update on a device that knows the revocation; accepted: the honest one, and the revoked device's on a device that does not know | yes for the roster rule (removed → fails); the other refusals have an accepted control built by the same code |
| `every_device_updates_on_its_own_window_spread_by_a_per_device_offset` | offsets < 24 h, per device and circle; nobody due after a week; exactly the devices whose offset passed are due mid-way; each device once after 8 days | yes (offset dropped from the window → fails) |
| `an_update_that_lost_a_fork_is_reissued_at_the_next_bundle` | FK4 (the old state follows the winning sibling), re-issue on the adopted tip at the next bundle, FK5 (the old state stops at the re-issue), no further commits | yes (lost Update not due → fails) |
| `the_superseded_leaf_secret_dies_when_the_checkpoint_passes_the_update` | old leaf and path secrets present in blob and memory until the checkpoint is at the Update's epoch, absent from then on | the scan finds the current leaf secret; **no** for the memo clear (with it removed the test still passes: later replays had already evicted the entries) |
| `a_device_cut_off_from_the_circle_cannot_make_its_own_branch_final` | three own Updates at most, checkpoint not past the fork, reconnect converges on the fleet's branch with no re-entry | yes (limit raised → fails) |
| `concurrent_member_updates_converge_under_delay_reorder_and_duplication` | §5, delay up to 2 steps, 2 schedules, ≥ 10 epochs | not mutated |
| `fork_load_soak` (ignored) | §5 at longer delays; **fails at its default** | — |
| `a_commit_with_a_bad_confirmation_mac_is_void_and_strands_nobody` | §6 | yes for the void rule (removed → devices stop behind the bad commit); **no** for persisting the set (a relaunched device re-derives the verdict while it still holds the parent epoch) |
| `a_roster_version_tie_counts_every_revocation_in_either_delivery_order` | §7: both orders, tree Remove, no new content for the revoked device, idempotent, restart, newer roster re-authorizes | yes (tie ignored → fails in the order where the revoking roster arrives second; tie not restored → fails after the restart) |
| `a_v2_state_from_before_member_updates_loads_and_starts_its_window` | §9 | not mutated |

"A strictly newer roster restores it" is asserted on authorization. On the v2 tree a Removed device
is not re-Added on its own (stage 3: removal is sticky), so its content access does not return by
that roster alone.

Existing tests changed (no assertion changed):

* `update()` (test helper): makes a device's Update due through its own window stamps instead of the
  circle's `rotated_at`, which a v2 tree no longer reads.
* `a_new_device_without_a_key_package_parks_the_circle_and_its_upgrade_resumes_it`: its five warm-up
  Updates are authored by the three devices in turn instead of all by the committer, which now
  stops after three in a row.
