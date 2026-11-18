# Stage 4 of the TreeKEM keying fix — every device re-keys its own leaf

Status: design note for the implementation on this branch (stage 4 and its follow-up 4b). Scope is
`PROTOCOL-SPEC.md` §12 F-d, §14 item 4, §15 and §16.4, plus defects fixed in the same files. It builds on [`STAGE1-STORED-STATE.md`](STAGE1-STORED-STATE.md) (the
checkpoint, the build records, the finality rule) and [`STAGE3-V2-TREE.md`](STAGE3-V2-TREE.md) (the
v2 tree). Code: `core/haven-ffi/src/keying_v2.rs`, hooks in `core/haven-ffi/src/lib.rs`, one
constant in `core/haven-p2p/src/treekem.rs`. Tests: `core/haven-ffi/src/net_tests/keying_v2_tests.rs`.

Not for publication before release: it describes weaknesses that remain (§12).

Everything here applies to the **v2 tree only**. The v1 tree's rules, wires, cadence and fork rule
(a branch four commits deep is final, then the larger hash) are untouched.

## 1. What is accepted as a member update (§16.4)

`check_commit` — the public check every v2 commit passes before it is stored — starts with this
case. A chained commit with **no proposals** is a member update and is valid from **any current
leaf**, admin or not, when `keypackage::verify_member_update` passes against the public tree the
commit extends, and the roster rule holds:

1. it carries an UpdatePath and no proposals;
2. the new leaf names the same device **and** account as the leaf at `sender_leaf`;
3. the leaf key differs from the one it replaces;
4. the credential chains to the pinned account key, the leaf binding is signed by that device for
   this circle, and the commit signature verifies under that device;
5. the device is **listed** in its account's verified roster — authorized or revoked. (Roster not
   known yet → retried later.)

It must then apply to the parent tree with the tree hash it claims (`step_public`).

Rule 5 was "authorized now" in the first version of this stage. That made a commit's validity
depend on when a receiver learned of a revocation: a device that learned it before it processed a
since-revoked device's adopted Update refused that commit, could store nothing built on it, and was
left behind for good. A revoked device is cut out by the `Remove` that follows — an authority
commit, which no number of Updates outweighs (§5) — not by refusing what it authored while seated.
Commits that change membership still require their author to be authorized now.

## 2. When a device authors one

`member_update`, from `emit_bundle` on the **full bundle** only (the bundle that re-seals the
author's history — the one place an epoch may move). It runs for every device.

A device re-keys its own leaf when all of these hold:

* the tree keys content on this device, and the device's own roster authorizes it;
* its own tip is the agreed tip (§6);
* its **own** window has elapsed (below);
* its tip has no child from its own leaf (`keying_already_authored_on`);
* its tip does not end a run of three chained commits of its own (`MAX_OWN_RUN`): a device that is
  the only one committing stops after three until another device's commit lands.

**The window is per device and is counted from the key at my leaf on my tip.** The v2 state keeps
`leaf_at` (when the leaf key of my current seat entered the tree) and `own_keys` (my last eight
commits, each with the id of the leaf key it installed for me and when I authored it; every commit
re-keys its author's leaf).

| The key at my leaf on my tip | Due |
|---|---|
| one of my own commits installed it | `7 d + offset` after I authored that commit |
| it is the key I entered with | `7 d + offset` after `leaf_at` |

`offset = BLAKE3("haven-mls-update-jitter-v1" ‖ device id ‖ circle id) mod 24 h`.

**Re-issue (FK4/FK5)** falls out of the table: an Update that lost a fork leaves the old key on the
tip I adopted, and that key is over age, so I am due at once (at my next full bundle). A commit of
mine that lost for another reason — a membership or re-entry race — does not make me due: the key
on my tip is as old as it is.

## 3. The old leaf secret (§15)

The stage-1 checkpoint owns every copy; one copy was outliving it and is now dropped with it:

| Where the superseded leaf / path secrets sit | Dies |
|---|---|
| the checkpoint's private state | when the checkpoint moves to the Update's epoch or past it |
| the entry Welcome, the key package it came from | when the checkpoint passes the entry |
| own build records of earlier (or losing) commits | when the checkpoint reaches their epoch |
| the replay memo (states of the last walk) | cleared when the checkpoint moves |

The checkpoint is three commits behind the tip, so the old leaf secret dies when the third commit
after the Update lands; until then a branch that forks below the Update is still followable.

## 4. Retention, and why there is no age-based checkpoint (§15)

In commits: an entry Welcome and its one-time seed are wiped when **3** commits have landed after
the entry; a superseded leaf secret when **3** have landed after the Update; an epoch's own secrets
when **4** have landed after it.

In time, for a tree that keys content, counting devices that run full bundles (each authors at
least once per `7 d + offset < 8 d`):

| Devices committing | 3 commits | 4 commits |
|---|---|---|
| N ≥ 4 | < 8 d | < 8 d |
| N = 3 | < 8 d | < 16 d |
| N = 2 | < 16 d | < 16 d |
| 1 (everyone else silent) | < 24 d | never while it stays alone |

Still unbounded: a tree that does not key content, a device that is not running, and the last
line. An age-based checkpoint was not added: a device that checkpoints its own tip can no longer
follow a commit authored on an older tip — which is what a silent device authors when it wakes —
and would have to re-enter instead.

## 5. The fork rule (v2)

Haven has no delivery service, so several commits can extend one tip. The rule the first version
of this stage inherited — a branch four commits deep is final, and final against final is decided
by hash — is not monotone: a longer branch could lose to a shorter final one, and with every device
authoring, two groups of devices could each build four commits unseen by the other in the time a
lagging delivery takes (§11). The devices on the losing side were then stuck.

The v2 tree now follows the **heaviest chain**. The weight of a chain is

    (authority, length)   compared in that order

* `length` — the number of commits on it;
* `authority` — the number of commits on it that `Remove` a leaf which is not the author's own,
  whose device the same commit does not Add back, and that the author could only remove with
  authority: a leaf of **another account**, or any leaf when the author is of the account that
  built the genesis (the creator revoking one of its own devices).

At a tip with several children that are not void, the walk takes the child with the heaviest chain
anywhere under it, and on equal weight the larger commit hash (`keying_v2::best_child`). Weights
come from one bottom-up pass over the commit set, memoized until the commit set or the void set
grows (`chain_index`). The same function serves the secret-bearing walk (`replay_walk`) and the
public view (`canonical`); when a device holds several entry points, the walk that ends on the
agreed tip is the one it uses. The genesis election is unchanged.

Why this shape:

* The agreed tip's weight only rises as commits arrive, and whoever authored the agreed tip is on
  it — so some device always holds its state and can seat the others.
* Only an admin can author an authority commit (`check_commit` refuses anything else when it is
  stored). A member that is being removed can author Updates, leaves of its own devices and
  re-entries — none of which count — so it cannot outweigh the branch that contains its Remove,
  from any fork point at or below it, with any number of commits or devices.

There is no depth at which a branch becomes final. The checkpoint keeps its timing (three commits
behind the walk's tip); it no longer means "final", it means "below here I cannot switch any more;
if the agreed chain leaves from below it, I re-enter".

`is_authority` is narrower than "a Remove of a leaf other than the author's own" in one respect: a
Remove of a leaf of the author's **own** account counts only for the creator account. A non-admin
may remove its own account's leaves (a leave); with two devices it could otherwise have one Remove
the other on its own branch and gain an authority point.

## 6. Authoring discipline, and asking to re-enter

**A device authors nothing on a tip that is not the agreed one** — no Update, no Add, no re-entry
(`author_commit`). A device that can see the agreed chain is elsewhere must not lengthen its own
branch. One exception: an admin's plain `Remove` (a revocation, `mls_remove_member`) is authored
from wherever the admin stands, because that commit is what returns the agreed chain to the branch
that excludes the removed device (§12 risk 1 is why). A device that does not hold the chain down to
the genesis has no agreed tip to compare with and is not restricted.

**A seated device asks to re-enter** (`wants_entry`: it offers a fresh key package) when it cannot
derive the agreed tip, no Welcome for one of its own packages is pending, and its own chain hangs
off the same genesis as the agreed one — so the fork rule had both to choose from and chose the
other, on weight or on the hash at equal weight. It no longer has to be *behind*: an equal-weight
branch that lost on hash re-enters too. A chain that does not connect to the genesis in what the
device holds is compared by epoch only, as before.

There is no pass in which the walk legitimately lags the public view: both are functions of the
same stored commits, a commit is stored only if its parent is, and a walk stops only at a commit it
cannot open. The one case found — a void commit on the agreed chain that the walk has not reached
yet — is settled before the comparison (`settle_void`, at the start of every bundle). So the
condition is not debounced over two bundles.

## 7. Re-entry by any member

A device re-enters by `Remove(old leaf) + Add(its fresh package)`. Until now only an admin could
author that, so a circle whose committer devices were on the losing side had nobody to do it.

**Accepted** (`check_commit`) from any current leaf, admin or not: proposals that are exactly k ≥ 1
pairs `Remove(L) + Add(leaf)` where each added leaf names the same device and account as the leaf
at `L` in the parent tree, no `L` is the author's own, and each added leaf passes the checks every
Add passes (signed by its device for this circle, roster-authorized now, a package not used on
this chain before). Membership does not change; it is not an authority commit.

A commit from a non-admin is judged against the parent tree. A device entering through such a
commit **without** the chain below (it would be checking the commit against the tree its Welcome
delivers) therefore does not accept it yet — the Welcome waits for the parent. Otherwise any member
could seat a device that has lost its history on a branch of the member's own making. An admin's
commit is still accepted standalone, as before.

**Authored** (`member_reentry`, every bundle, non-committers; the committer does it at once in
`sync_roster`) by a device that derives the agreed tip, knows the chain's whole history, and holds
a fresh valid package from a device the agreed tree seats under another key:

* the asking device is a committer device (the creator account's) → the healthy device with the
  smallest `BLAKE3("haven-mls-reentry-v1" ‖ device ‖ kp_id)` acts at once;
* otherwise, and for every other healthy device → once the package has waited
  `1 h + (that hash for my device mod 6 h)` since I first saw it this session.

"Healthy" is every seated device I hold no such package from, myself included — simpler than
join-ack evidence, and computable by every device from what it already holds.

Three defects surfaced under this load and are fixed:

* **A device that entered by a Welcome could not open a third device's Update.** The commit that
  seats a device re-keys its author's path; the secrets of the nodes that path shares with the new
  leaf's reach the new device only inside that commit, and no node lists it as unmerged
  afterwards. While only the committer updated, every later path came from the same leaf and
  delivered them again. `entry_path_secrets` now opens them from the public entry commit with the
  device's own leaf secret when a walk starts at a Welcome. (This affected any device Added to a
  v2 tree, not only a re-entry, as soon as a third device updated.)
* **The public view of a chain was cached for good even when it started at an entry point.** A
  device that entered before the chain below reached it went on treating every key package older
  than its entry as unused, and re-entered devices that had not asked, in commits nobody else
  accepted. Such an answer is now reused only while the commit set is unchanged, and no re-entry is
  authored without the chain's whole history.
* **A committer forgot a package when it used it.** If that commit lost its fork the device went on
  offering the same bytes, which a mailbox serves once. A package now stays held until the chain
  the committer stands on has used it.

## 8. A commit whose confirmation MAC is wrong is void

`apply_commit` verifies, level by level, that the path secret a receiver decrypted derives the
public keys in the UpdatePath. When it then reports a MAC mismatch (`treekem::ERR_CONFIRMATION_MAC`)
the verdict is the same for every device that holds the parent epoch and is not removed by that
commit. `replay_walk` treats such a commit as void and carries on with the next-best child; the
hash goes into a persisted set, and the chain weights, the walk and the public view all skip it.
Only that one error is treated this way.

## 9. Roster version tie (finding F5, §17)

`store_verified_roster`, contact rosters only. A verified roster with the stored version and
different contents widens the stored roster: every device revoked in it is revoked, the account
leaf is retired if it says so; nothing is authorized by a tie. If that changed what is authorized
the usual steps for a new revocation run; the same roster again changes nothing. The rosters as
signed are kept (`NetState::roster_ties`, blob field `roster_ties`, re-verified on load, not written
while empty); a strictly newer roster replaces the lot. No wire format or signed bytes change.

## 10. Logging and persisted state

* `mls_shadow_status` no longer logs the epoch secret; no other log statement in the keying code
  formats secret material.
* v2 tree state (`keying_v2::encode_state`) is **version 3**: the member-update tail carries a list
  of own commits where version 2 carried at most one. Versions 1 and 2 still decode. A version-1
  device starts its window at the first check.
* A state with no v2 tree and no roster tie serializes byte-for-byte as before. `mls_keying` off:
  no code path added here runs.

## 11. Fork load: numbers

Harness: four devices of three accounts; each round two or three of them come due at once and
author on whatever tip each holds, one device posts, a random half of the fleet sends two more
bundles; every envelope is delayed a random number of steps, delivered in random order, one in
five twice, and (like a mailbox) the same bytes reach a device once. A round is three steps and
stands for one update period. A run passes when every device ends deriving the same tip with the
same epoch secret, the v2 tree keys the circle on every device, a post made at the end opens on
every device, and nothing more is authored. Re-entries are allowed and counted (distinct key
packages offered after the fleet was live). Posts made on the way that do not open at the end are
counted; the ignored soak fails on any.

Under the first version's rule (depth-capped finality; five devices): at a lag of two steps and of
one round every run converged with no re-entry (losing branches up to 3 deep); at a lag of two
rounds 4 of 7 runs did not converge.

Under the rule above, final code:

| Max delay | Epochs | Schedules | Converged | Re-entries per schedule |
|---|---|---|---|---|
| 2 steps | ≥ 10 | 10 | 10 | 0 2 0 0 0 0 0 0 0 0 |
| 3 steps (one round) | ≥ 10 | 10 | 10 | 1 0 2 0 2 0 0 0 0 0 |
| 6 steps (two rounds) | ≥ 10 | 10 | 10 | 1 3 1 0 2 3 2 2 2 0 |
| 9 steps (three rounds) | ≥ 20 | 16 | 16 | 4 5 0 3 2 2 2 2 3 3 4 3 6 3 1 2 |

On the way there, runs at 6 and 9 steps failed (1 or 2 schedules in 10 to 28), each time for one
of the three defects listed in §7. With the first two fixed, 28 of 28 schedules at 6 steps
converged; the table is with all three.

**A post made on the way was lost once.** In a further 56 schedules at 3 steps (run to chase an
intermittent failure of the ten-schedule test, whose own output was not captured and may have been
the same thing) every one converged, and in one of them a post a device made in round 5 did not
open on one other device at the end, although both ended on the same tip with the same epoch
secret and the author re-seals its history in every full bundle. Not diagnosed. The runs in the
table had none. (The first version's runs checked the same thing and had none in 13.) It is counted
by the default tests and fails the soak.

Commit hashes are random, so a seed fixes the schedule but not which branch wins; the same seed
does not reproduce the same run.

## 12. Not covered, not verified, risks

**Not done / not verified**

* No model re-run; no `.spthy` was touched. Tests are core Rust only; no e2e or simulator fleet.
* The re-entry delay for non-committers is exercised with aged packages, not with a moved clock.
* "It removes the author's own leaf" in a re-entry is refused by the pair rule, but no test
  builds such a commit (`build_commit` will not).
* The roster tie is handled for contacts' rosters only (a seedless device's view of its own
  account's roster has the same tie), and tied rosters are not relayed to the account's other
  devices.

**Risks**

0. **A post can stay unreadable on one device after a fork** (§11): seen once in 56 schedules at a
   lag of one period, cause unknown. A lost post is user-visible; this needs finding before
   release. One thing to look at: the content epoch number is the tree epoch, which two branches
   share, and an event's seal is deterministic — so an envelope a device could not open while it
   held the other branch's key for that number is, byte for byte, the envelope it is offered again.
1. **A member can still force a fleet-wide re-entry.** Length is the second term of the weight and
   costs a member nothing: from any old fork point a modified client can author a chain longer
   than the honest one. Every honest device then sees an agreed chain it cannot derive and asks to
   re-enter — onto the member's chain, if the member seats them, or nowhere if it does not, and
   under §6 they author nothing meanwhile. What the rule gives is a way out: an admin `Remove` of
   the member, authored from the honest branch (the exception in §6), outweighs any such chain.
   The depth-capped rule had the same exposure at even odds; this one is certain but recoverable
   by the admin. Not closed, and the recovery is a user-visible action.
2. **Removing a member one device at a time** leaves it a device to author with until the last is
   gone. `mls_remove_member` removes all of an account's leaves in one commit.
3. **A stale unused package looks like a request.** A device seated under one key that once
   offered a package nobody used is re-entered by whoever still holds that package (once the
   wait has passed). One needless `Remove + Add` per stale package; if the device has dropped
   that package's secret it has to ask again.
4. **A device with a hole in its commit set** (a commit it once refused or lost, which a mailbox
   will not serve again) has no agreed tip, is not bound by §6, and can keep authoring commits
   nobody else accepts. Not seen after the fixes in §7; not excluded.
5. **Membership commits still depend on roster timing** (stage 3, open): an Add or a re-entry is
   refused by a device that already knows the added or the authoring device is revoked.
6. **A targeted bad path** (one device's path ciphertext does not open) still stops that device,
   which re-enters. It cannot be made void: the other devices cannot see it.
7. **Late entrants cannot check a void commit** below their entry.
8. **Growth and churn.** The commit set is never pruned; with N authors it grows N times faster,
   and the chain index is rebuilt over all of it whenever a commit arrives. N epochs a week mean N
   history re-seals a week per client.

## 13. Tests

All in `core/haven-ffi/src/net_tests/keying_v2_tests.rs`. "Teeth" = the named change to the code
was made, the test failed at the assertion it is about, and the change was reverted.

| Test | Shows | Teeth |
|---|---|---|
| `a_plain_member_rekeys_its_own_leaf_and_its_stolen_state_stops_working` | T4 | not mutated |
| `a_member_update_is_accepted_only_for_the_authors_own_fresh_leaf` | §1: refusals, each with an accepted control; a revoked seated device's Update is stored by a device that knows the revocation and the device is then Removed; an unlisted device's is not stored | yes: roster rule put back to "authorized now" → fails at "stores" |
| `every_device_updates_on_its_own_window_spread_by_a_per_device_offset` | §2 | yes (offset dropped; run against the first version) |
| `an_update_that_lost_a_fork_is_reissued_at_the_next_bundle` | FK4, re-issue, FK5 | yes against the first version; not re-run against the key-on-tip rule |
| `the_superseded_leaf_secret_dies_when_the_checkpoint_passes_the_update` | §3 | the scan finds the current secret; **no** for the memo clear (later replays had already evicted the entries) |
| `a_device_cut_off_from_the_circle_cannot_make_its_own_branch_final` | `MAX_OWN_RUN`; reconnect without re-entry | yes (limit raised; first version) |
| `fork_load_converges_at_a_lag_under_one_period`, `_of_one_period`, `_of_two_periods` | §11, ten schedules each | each of the three defects in §7 made the two-period run fail before its fix |
| `fork_load_soak` (ignored) | §11 last row | — |
| `a_removed_member_cannot_out_build_its_remove` | §5: six Updates by two devices in turn on the Remove's parent and on the parent's parent | yes: authority term dropped → fails |
| `the_longer_side_wins_and_a_plain_member_reenters_the_committers` | §5, §7: 5 against 6 commits, both sides checkpointed past the fork; the first re-entry is authored by a plain member (a creator device it seats may then seat its sibling) | yes: member re-entry authoring disabled → the creator's devices stay out |
| `an_equal_weight_fork_is_decided_by_hash_and_the_losing_side_reenters` | §5, §6: 4 against 4 | yes: the "same genesis, other tip" clause removed → the losing side never asks |
| `a_member_reentry_is_accepted_only_for_the_device_that_asked` | §7: refused for another device's leaf, an Add alone, a Remove alone, a package used on the chain, an unauthorized device; accepted otherwise; weight `(0, 1)` | accepted control |
| `a_device_that_entered_by_a_welcome_follows_a_third_devices_update` | §7, first defect | yes: `entry_path_secrets` disabled → the re-entered device does not follow |
| `a_commit_with_a_bad_confirmation_mac_is_void_and_strands_nobody` | §8 | yes for the rule (first version); **no** for persisting the set |
| `a_roster_version_tie_counts_every_revocation_in_either_delivery_order` | §9 | yes (first version) |
| `a_v2_state_from_before_member_updates_loads_and_starts_its_window` | §10: versions 1, 2, 3 | not mutated |

Not mutated in 4b: the length term of the weight, the authoring discipline, the public-view cache
fix and the package retention (the last two only show under the fork-load runs).

Existing tests changed:

* `update()` (helper): makes a device's Update due through its own window stamps, not the circle's
  `rotated_at`.
* `a_new_device_without_a_key_package_parks_the_circle_and_its_upgrade_resumes_it`: its five warm-up
  Updates are authored by the three devices in turn (`MAX_OWN_RUN`).
* `a_member_update_is_accepted_only_for_the_authors_own_fresh_leaf` (a stage-4 test): its assertion
  that a device knowing of a revocation **refuses** the revoked device's Update is now that it
  **stores** it and the device is then Removed — the roster rule changed (§1).
* The stage-4 tests `concurrent_member_updates_converge_under_delay_reorder_and_duplication` and the
  failing-by-design `fork_load_soak` are replaced by the three `fork_load_converges_*` tests and a
  passing soak; "no device re-entered" is no longer asserted there (re-entry is the recovery).
