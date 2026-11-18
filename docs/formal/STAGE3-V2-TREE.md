# Version 2 of the tree — key packages, v2 Welcome, v2 genesis, the silent migration

Status: design note for the implementation on this branch. Scope is `PROTOCOL-SPEC.md` §12 F-b
and F-c, §14 items 3 and 5, §15 (the retention rules), §16.1–§16.3 and §16.5. It builds on
[`STAGE1-STORED-STATE.md`](STAGE1-STORED-STATE.md): the same checkpoint, the same build records,
the same finality rule. Code: `core/haven-ffi/src/keying_v2.rs` (everything v2-specific) and the
hooks in `core/haven-ffi/src/lib.rs`; primitives in `core/haven-p2p/src/keypackage.rs`.

Not for publication until the remaining stage ships: it describes weaknesses that remain.

NOT in this stage: member-authored leaf Updates (§16.4). Only an admin device commits, as on the
v1 tree; `keypackage::verify_member_update` is still unused.

## 0. What a v2 tree is

A v2 tree is the same `ShadowTree` the v1 tree uses, with `is_v2` set, kept in a second map
(`NetState::v2_trees`) and persisted in a second list (`PersistState::shadow_trees_v2`). It is
walked by the same `mls_replay`, checkpointed by the same `keying_checkpoint_pass`, and its own
commits are rebuilt from the same stored build records. Four things differ:

| | v1 tree | v2 tree |
|---|---|---|
| wire tags | `0x05`–`0x08` | `0x10` key package, `0x11` commit, `0x12` Welcome, `0x13` join ack |
| genesis constants | `haven-mls-shadow-genesis-{parent,cth}-v1` | `haven-mls-genesis-{parent,cth}-v2` |
| a leaf's secret | chosen by the committer, delivered in the Welcome | drawn by the device, never sent |
| a Welcome | sealed to the device's long-term bundle, kept by the committer's `assigned_leaves` to re-issue | sealed to a key package's one-time key, bound to its public commit, never re-issued |

Nothing in the v2 path reads the device seed except to sign: `mls_replay` is always called with
no seed for a v2 tree, the seed-derived rebuild fallback is disabled for it, `assigned_leaves`
stays empty, and the genesis init, every leaf secret and all path entropy are `OsRng`.

## 1. Key packages

* **Minted** by the device (`KeyPackage::generate`) when it wants a seat and holds no package the
  agreed chain has not used. Kept as `(kp_id, leaf_secret, init_seed, signed bytes)` in the v2
  state blob; the same bytes are re-emitted in every bundle while the device still wants a seat.
* **A device wants a seat** (`wants_entry`) when: no v2 genesis is held; or the agreed chain has
  no leaf for it and did not Remove it; or it has a leaf there, cannot derive the agreed tip, its
  own state is behind that tip (or gone), and the leaf is not one it is still waiting on a Welcome
  for. "The agreed chain" is `canonical`: from the elected genesis, the fork rule at every step,
  computed from public commits only.
* **Accepted** from another device only if it parses, names this circle, its credential chains to
  the pinned account key, the leaf binding and the package are signed by that device, the device
  is authorized in the account's verified roster, and its leaf key was not already used on the
  agreed chain. Roster or account not known yet → parked for retry, like a v1 tree wire.
* **Used once.** A committer picks, per device, the newest held package whose leaf key no Add on
  its chain has used. Every receiver enforces the same on a chained commit (`check_commit`): an
  Add whose leaf key appeared in an Add below it is refused. Two competing branches may use the
  same package (two creator devices racing at the genesis); one chain never does.
* **Deleted** (`prune_key_packages`): the `init_seed` and the spare copy of the leaf secret of the
  package a device entered through are dropped when the stage-1 checkpoint has passed that entry
  point, i.e. when every Welcome through it has been wiped. From then on no Welcome sealed to that
  package opens with anything the device holds. The leaf secret lives on only as the device's
  current leaf in its tree state.

## 2. Commits, checked against the public tree

Every v2 commit is verified WHEN IT IS STORED, against the public tree it extends
(`public_state`: the genesis' Adds, then each commit applied without secrets, memoised by tip):

* genesis: signed by the elected creator account (or an admin) — the v1 rule — plus: add-only, no
  device twice, every leaf verified with `verify_leaf` (credential → pinned account, binding signed
  by that device for this circle) for a device its roster authorizes; the tree hash matches;
* chained commit: carries an UpdatePath; the path's leaf names the device ALREADY at
  `sender_leaf`, is signed by it, and the commit signature verifies under it; that device is
  authorized; its account is an admin, or the commit only removes leaves of its own account; every
  Add passes the leaf check, is not for a device already seated (unless this commit Removes it
  first), and reuses no leaf key; no `Update` proposals; and the commit applies to the parent tree
  with the tree hash it claims.

The v1 tree checks the committer's credential, roster status, signature and authority only, and
does not look at the tree the commit extends. The stricter store-time check is what lets a v2
device use the public commit set as evidence: finality (`keying_chain_reaches`) on a v2 tree counts
commits that at least APPLY publicly (not that their confirmation MAC verifies — that needs the
epoch secret).

A commit whose parent has not arrived is held aside (`orphans`, session only) and retried.

## 3. Genesis, Add, Remove, re-entry

* **Genesis.** Built by a device of the elected creator account once it holds a usable package for
  EVERY authorized device of every member (its own included) and holds no v2 genesis yet. Add-only;
  each leaf is the package's leaf verbatim; `init_0` is random and wiped after the build. A Welcome
  goes to every other device; the creator stores its own entry point directly.
* **Roster reconciliation** (`sync_roster`, every bundle, committer only), in ONE commit:
  Remove every leaf whose device is no longer authorized; Add every authorized device that is not
  seated, was not deliberately removed, and has offered a package; and for every seated device that
  has offered a fresh package, `Remove(old leaf) + Add(package)` — its **re-entry**. The committer
  re-keys its own leaf with a random secret in the same commit.
* **Re-entry** is therefore driven by the device's own signed request and gives it nothing of its
  old leaf back. The device drops its checkpoint, entry points and build records when it accepts a
  Welcome for a newer package than the one its current place came from. In the replay a
  Remove followed by an Add of the same device is not a sticky removal.
* **Removal stays sticky**: a device Removed and not Added again is never auto-Added, whatever
  package it offers.
* There is no v2 re-Welcome and no v2 fork heal by join ack. `mls_rewelcome` is a no-op once the
  v2 tree has taken a circle over.

## 4. Welcome v2

Sealed with `keypackage::seal_welcome` to the package's one-time identity; payload
`keypackage::WelcomeV2`. The committer keeps only the sealed envelope (for byte-stable
re-emission): the plaintext buffer is zeroed, and neither its live state nor its checkpoint holds a
`joiner_secret` on a v2 tree (there is nothing to re-deliver).

A device accepts a Welcome only if all of these hold:

1. it opens with the one-time key of one of its own packages (never with a long-term key);
2. the commit it names is held — stored (so already checked against its parent) or, for a device
   entering mid-chain without the chain below, held aside as an orphan and then checked standalone
   (signer, authority, each Add's leaf);
3. the envelope was sealed by the device that authored that commit;
4. `enter_via_welcome_v2` passes: same circle and epoch, the delivered tree hashes to the commit's
   `tree_hash`, the leaf at `leaf_index` is the key the device published — and (added in this
   stage) the delivered `joiner_secret` and transcript hash key the commit's confirmation MAC;
5. the device's own roster still authorizes it.

Point 4's MAC check matters because anyone can seal to a published one-time key: without it a
Welcome naming a real commit could seat the joiner in an epoch whose secrets its sender chose.

The accepted Welcome is stored as a stage-1 entry point (with the device's OWN leaf secret) and
wiped by the checkpoint exactly as a v1 Welcome is.

## 5. The join gate

A v2 join ack is `entry commit ‖ device ‖ device signature` — "this device holds the secrets of the
leaf that commit gave it". The tree keys content only when (a) every leaf's device has acked the
commit that last Added it (so a re-entered device must ack its new seat), and (b) every authorized
device of every member IS a leaf, or is a device the chain deliberately Removed (a member cut by
an admin's commit stays in the other members' circle lists, as on the v1 tree). (b) is new: without it a device that never offers a package
would be left out of a circle that goes on keying from the tree.

## 6. Migration: two trees side by side

Running both trees per circle is what was built; nothing parks in between.

```
v2 gate   = keying switch on ∧ device identity ∧ the v1 gates (every member MLS-capable with a
            roster, owned circle) ∧ every member ACCOUNT advertises ml ≥ 2
```

1. `ml` is now 2 in the profile card. Shipped builds test `ml >= 1`; `mls2_capable` (`ml >= 2`)
   is learned beside `mls_capable`, with the same rules.
2. While the v2 gate holds a device offers its key package. The v1 tree is untouched: it keeps its
   genesis, its commits, its weekly Update, and keeps keying content.
3. The marker is account-level. The device-granular evidence is the package itself: no genesis
   until one is held for every authorized device. A device on an older build never offers one, so
   the circle stays on the v1 tree for good (test: mixed fleet).
4. Once it can derive the v2 tree's current epoch, a device files that epoch's content keys even
   though the v2 tree does not key the circle yet — so a post from a device that flipped first
   opens at once.
5. When the v2 tree is all-present and all-joined on a device, that device's content keying flips
   to it (`MLS2_EPOCH_BASE + epoch`, a third key lane), and in the same step it removes its v1 tree
   state (Welcomes, checkpoint, build records, assigned leaves — wiped), drops parked v1 wires, and
   marks the circle `retired_v1` (persisted). From then on it builds no v1 genesis, emits no v1
   tree wire, and drops any v1 tree wire that arrives.
6. Devices flip at slightly different moments. A device still on the v1 tree reads the flipped
   device's posts (step 4); the flipped device still holds the v1 content keys (they age out of
   the key window as usual).

Fallbacks, both on positive evidence only:

* **A device with no package joins a v2-keyed circle** (an older build under an upgraded account):
  gate (b) fails, the circle parks on the KeyCommit lane — which seals to every authorized device
  — and resumes when that device offers a package and is Added. The v1 tree is NOT brought back.
* **A member account that advertises `ml: 1` joins**: `retired_v1` is cleared; the v1 tree runs
  again from a new genesis, as it would in any mixed circle. The v2 tree state is kept, parked.

Persisted state: `shadow_trees_v2` and `PersistShadow::v2` are new, defaulted, and not written
when empty, so a state with no v2 tree serializes byte-for-byte as before. An older build ignores
both. A downgrade after the flip is not supported (the older build finds no v1 tree and, on a
creator device, builds a new v1 genesis the upgraded devices ignore; content falls to KeyCommit).

## 7. Key lanes (changes outside the tree)

The content maps hold three lanes of epoch keys: sender keys (small numbers), v1 tree
(`2^40 +`), v2 tree (`2^41 +`). Three things were wrong or missing once more than one lane
exists, and are fixed for the v1 tree too:

* **The key window is per lane** (`epochs_to_keep`). One numeric top-4 over all lanes meant four
  tree keys evicted every sender key, the current one included: a circle that parked after four
  tree epochs had no key to seal under (`author` panicked under the engine lock, the bundle was
  empty) and its peers pruned each sender key on arrival. Each lane now keeps its own four; a lane
  that is not keying the circle shrinks to its newest key once the active lane has a full window;
  my current sender epoch is never pruned.
* **Parked envelopes are not fossils across lanes** (`parked_is_fossil`): an envelope sealed on a
  lower lane than a key still held is dropped only while a tree keys the circle.
* **The park path cannot panic**: `ensure_lane_key` mints a fresh sender epoch if the current one
  has no key; the two `expect`s on the live key are gone (a live epoch whose key is missing falls
  back to the sender-keys lane).

## 8. What stops being held, and what does not

Stops (in a circle keyed by the v2 tree):

| Secret | v1 tree after stage 1 | v2 tree |
|---|---|---|
| another device's leaf secret | committer: stored (wrapped under a seed-derived pad), or `H(seed, device)` for old leaves | nobody but the device, ever |
| a Welcome on the wire | opens with the device's long-term key for as long as that key exists | opens with a one-time seed the device deletes at its checkpoint |
| `joiner_secret` of the live epoch | in every member's live state and checkpoint | not kept after the entry point is wiped |
| genesis init / leaf secrets of an existing circle | functions of the creator's seed until re-genesis | random (this is the re-genesis) |
| the whole v1 tree state | — | wiped at the flip |

Still held, or not addressed:

* **Members still never update their own leaf** (§16.4, next stage). A member's stolen tree state
  keeps opening new commits until the member re-enters or is removed (T4 stays falsified).
* **The retention window**: checkpoint state, build records and the last four content keys per
  lane are in the blob by design. Until a joiner's chain is four epochs past its entry (three
  commits — at the weekly cadence, three weeks in a quiet circle) its one-time seed and entry
  Welcome are still in its state. §15 asks for "or after a fixed age"; there is no age rule yet.
* **The checkpoint at the entry epoch holds that epoch's `init_secret` and `sender_root`** (not
  the `joiner_secret`) until it advances.
* **v1 content keys** stay in the key window after the flip until four v2 epochs have passed, then
  one remains (the newest) until the lane is pruned by a later flip — see "Open points".
* **A stolen device signing key** lets its holder offer a key package and be re-seated by the
  committer. That is impersonation with a long-term key (§12, §15); nothing here prevents it.

## 9. Not verified / open points

* **No model re-run.** The `.spthy` files were not touched; the tests are core Rust only. No
  e2e / simulator fleet was run.
* **A v2 wire that arrives before capability is re-learned** (capability is not persisted) is
  parked in the tree retry buffer and retried when the member's `ml: 2` is learned; the buffer is
  bounded (128) and its poll retry is bounded (8 per change), as for v1 wires.
* **A parked circle seals to every member each device still lists.** A member Removed on the tree
  is not waited for by the presence gate, but if the circle parks for another reason the KeyCommit
  lane seals to that member on any device that has not dropped it from the circle. Same as the
  v1 tree today.
* *(Closed in stage 4.)* A lost Welcome used not to be healed: the joiner, seated on the agreed
  chain under a key it holds, waited for good. It now waits one hour (`WELCOME_WAIT_SECS`, the
  wait is persisted) and then asks again with a package the chain has not used
  (`a_device_whose_welcome_was_lost_asks_again_and_is_seated`).
* **Stranded-device detection needs the genesis chain.** A device that entered mid-chain and does
  not hold the commits below its entry point cannot compute the agreed tip and never concludes it
  is stranded. And a device whose own branch is at least as long as the agreed one waits (the
  stage-1 "two branches both ≥ F deep" case) until the agreed branch outgrows it.
* **A malicious admin** can publish a commit that applies publicly but whose confirmation MAC is
  wrong: every walk stops there while the public view moves on, and every device then asks for
  re-entry. Admins are trusted for membership; this is a denial of service by one.
* **Sibling committers.** Every device of the creator account is a committer. Two of them can Add
  the same newcomer on competing branches (as on the v1 tree); the fork rule resolves it and the
  newcomer holds both Welcomes while its package's seed lives.
* **Roster-dependent checks use the roster as it is now.** A device catching up on an old chain
  re-checks old Adds against today's roster; a commit that Added a device since revoked fails that
  check, is not stored, and the chain above it is unusable to that device. It then enters through
  a Welcome's standalone check instead. Not exercised by a test.
* **Engine-lock cost.** A v2 Welcome is opened under the engine lock (the v1 one is opened ahead
  of it); the public-tree walk and the agreed-tip walk are memoised but run under the lock.
* **Idle-lane key.** After a flip one key of the previous lane stays until that lane is the active
  one again. It protects the park path; it also means one old content key outlives the window.
* **An older build loading a newer blob before any checkpoint** (stage-1 review, item 4d): it
  rebuilds a random-material own commit from seed-derived inputs, does not verify the result, and
  derives wrong keys silently. Nothing safe can be done from the new side: any field an old build
  would "trip on" makes its whole state load fail, which is worse. Downgrade stays unsupported.
* **Finality on the v1 tree** still counts descendants that parse and were authorized, not ones
  that apply (review item 4c). Fixed only for the v2 tree, where a commit is stored only if it
  applies publicly.

## 10. What the apps must do

Nothing new. The v2 wires ride the existing bundle (`sync_envelopes`, `export_my_envelopes`,
`sync_envelopes_page`) and `receive`; `key_state_unsaved` already covers a minted key package and
the flip; `set_mls_keying` is the same switch. `mls_keying_status` reports the v2 tree's epoch
(counted from 1 again) once it keys the circle, and `"parked"` when the v2 tree has taken over but
is not keying. `mls_shadow_status` reports on the v2 tree once the v1 tree is gone.
`mls_rewelcome` returns false for such a circle.

One existing app path to look at: Apple's `recoverSetAsideState` strips own-identity material
from a set-aside state file before importing it; it does not know `shadow_trees_v2`, which holds
key package secrets and a checkpoint of whichever identity wrote that file.
