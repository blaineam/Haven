# TreeKEM: MLS-style group ratcheting on Haven's own PQ primitives (D16 Phase 5)

> **Status — design spike, not built.** This is the implementation plan for the "MLS hardening"
> line in `ROADMAP.md` (Later/Nice-to-have) and the honest closure of `docs/SECURITY.md:47`
> ("does **not** have per-message forward secrecy or post-compromise security; that needs MLS").
> It is **design only**; no product code accompanies it.
>
> **Locked decisions (do not relitigate):**
> - **Path B.** An MLS-*style* TreeKEM built on Haven's **own** hybrid post-quantum primitives —
>   X25519+ML-KEM-768 KEM → AES-256-GCM (`core/haven-p2p/src/crypto.rs`), Ed25519+ML-DSA-65
>   signatures (`core/haven-p2p/src/identity.rs:216`) — **not** wire-interoperable RFC 9420. Every
>   ratified MLS ciphersuite is classical; Haven doesn't federate; interop would regress the PQ
>   posture that is the product's headline guarantee. We take the *mechanisms*: ratchet tree,
>   O(log n) path updates, propose/commit/welcome, and an epoch key schedule with forward secrecy
>   and post-compromise security.
> - **Backwards compat exactly like seed-drop.** A versioned `mls` capability marker rides the
>   signed profile/roster; a circle runs TreeKEM **only** when every member device affirmatively
>   advertises it (all-present-positive; absence is never information); otherwise it stays on
>   today's sender-keys+epochs. Per-circle automatic migration, reversible if a legacy device joins.
> - **Leaves = devices.** Seed-drop (D16 Phase 2, S2–S5 core landed) gives every device its own
>   keypair plus an account-signed `DeviceCredential` (`core/haven-p2p/src/device.rs:43`). A TreeKEM
>   leaf is a **device** keypair; the leaf credential is the existing device→account chain. MLS
>   Remove+Commit is the evolution of seed-drop's roster-bump-and-rotate.

---

## 0. TL;DR

Today a circle's confidentiality rests on **sender-keys epochs**: each member mints a random
32-byte epoch key (`groupkey.rs:30`), fans it to every recipient device with one hybrid-KEM wrap
each (`seal_key_commit`, `groupkey.rs:68`), rotates it on membership/roster change and weekly
(`lib.rs:1129`, `:1145`), and seals events under HKDF-derived per-event keys (`groupkey.rs:167`).
With seed-drop, revocation is cryptographic. What is still missing — and what this design adds —
is:

1. **Post-compromise security (PCS).** Today, an attacker who silently extracts a device's epoch
   keys keeps reading forever unless a membership change *happens* to rotate; and if they also hold
   the device key they receive every future rotation. TreeKEM path updates heal this: a device that
   refreshes its leaf re-keys its path with material the attacker doesn't have, and the epoch
   schedule mixes it in one-way — the attacker's stale state goes dark.
2. **Forward secrecy with a real deletion discipline.** Today FS is "bounded" by
   `prune_epoch_keys` (KEEP_EPOCHS=4, `lib.rs:1165`) — about four weeks of exposure per key
   compromise. TreeKEM makes the epoch schedule one-way (an epoch secret cannot be run backwards)
   and gives every secret a named lifetime and deletion point.
3. **O(log n) rekeying** instead of the O(n·devices) KEM fan-out per commit — real but *modest* at
   Haven's circle sizes (§1.3); it is the third reason, not the first.

The structural insight that makes this tractable: **the tree replaces only the key-agreement
layer.** The entire content path — `EpochEnvelope`, deterministic re-seal and mailbox dedup
(`groupkey.rs:186`), `pending_epoch` buffering (`lib.rs:1413`), the author/sender device
resolution (`lib.rs:1391`), feed reduction — is keyed by "a 32-byte epoch key per (account,
epoch)" and **does not care where that key came from**. In an MLS circle, that key is *derived*
from the shared TreeKEM epoch secret instead of being individually minted and KEM-fanned. The
sender-keys substrate is the compatibility layer *and* the integration surface.

The make-or-break problem is **concurrency without a delivery service** (§5): RFC 9420 assumes a
DS that serializes commits; Haven has store-and-forward mailboxes, days-offline devices, and no
ordering. We resolve forks with a deterministic tie-break (largest commit hash wins — the same
shape as the shipped converge-on-larger-key rule, `lib.rs:1345`), a bounded losing-fork key cache,
and the existing daily full re-seal as the convergence backstop. Nothing is lost; §5 proves why.

---

## 1. Why: the honest delta over sender-keys + epochs + seed-drop

### 1.1 What already holds without TreeKEM

Be precise about what MLS does *not* need to add, because the shipped system already provides it:

- **Cryptographic revocation of members** — a removed member is absent from the next commit's
  recipient set and never learns the new epoch key (`groupkey.rs:338` test
  `key_commit_revokes_removed_member`; `purge_member_from_circle` rotates on removal,
  `lib.rs:1267`).
- **Cryptographic revocation of devices** — seed-drop: a revoked device's bundle is dropped from
  recipients (`device.rs:336` `authorized_bundles`), the account-key fallback is gated off for
  fully-capable circles (`recipients_with_devices_gated`, `device.rs:553`), and a seedless device
  cannot forge a roster (`device.rs:1038` test `s5_revoked_seedless_device_cannot_reenter_or_decrypt`).
- **Bounded forward secrecy** — weekly rotation (`ROTATE_INTERVAL_SECS`, `lib.rs:1069`) plus
  pruning to the last 4 epochs (`lib.rs:1165`).
- **PQ end-to-end** — every wrap is hybrid X25519+ML-KEM-768 (`crypto.rs:49`), every signature
  hybrid Ed25519+ML-DSA-65 (`identity.rs:216`).

### 1.2 What TreeKEM actually adds

| Property | Today (sender-keys + seed-drop) | With TreeKEM |
|---|---|---|
| **PCS** | None. A silently-exfiltrated epoch-key store stays readable until an *unrelated* membership change; an exfiltrated device key receives every future commit until the theft is *noticed* and the device revoked. | A leaf update (weekly, piggybacked on the existing rotation chokepoint) injects fresh entropy the attacker lacks; one epoch later their state is useless. Healing requires no human noticing anything. |
| **FS shape** | Epoch keys are independent random values; compromise of the *state blob* leaks all 4 retained epochs of *every member's* keys at once. | One-way epoch chain: `epoch_secret_n` cannot yield `epoch_secret_{n-1}`; per-epoch derived keys are deleted on schedule; a state compromise leaks the same 4-epoch window but *cannot* be run backwards past a deleted secret. |
| **Rekey cost** | O(members × devices) hybrid wraps per commit, per member (each member runs their own epoch sequence — N commits circulating). | One shared epoch sequence; a commit carries O(log n) hybrid wraps. One commit circulating, not N. |
| **Group agreement** | None — each member's epoch is their own; there is no shared "the group is at epoch E" fact. | Confirmed transcript hash: all members provably agree on membership + history of the tree. Detects a relay showing different members different rosters. |

### 1.3 Quantifying O(log n) honestly

Haven circles are families and friend groups: realistically ≤ 30 accounts × 1–3 devices ≈ ≤ 90
leaves, typically ~10–25. Per-recipient hybrid wrap cost (one `RecipientKey`, `social.rs:127`):
32 (eph X25519) + 1088 (ML-KEM-768 ct) + 60 (AEAD-wrapped 32-byte key) ≈ **1 180 bytes**.

- **16-member circle, 2 devices each = 32 leaves.** Today: each member's KeyCommit fans to 32+
  recipients ≈ **38 KB** per commit, ×16 members circulating ≈ 600 KB of commit material per
  full rotation cycle. TreeKEM: depth ⌈log₂32⌉ = 5; an UpdatePath carries 5 node public keys
  (32+1184 = 1 216 B each) + ideally 5 copath wraps (1 180 B each) + one hybrid signature
  (64+3309 = 3 373 B) ≈ **16 KB**, once, for everyone.
- **A 5-member family, 8 leaves:** today ≈ 9.4 KB/member-commit; tree path ≈ 3 levels ≈ 11 KB.
  **No meaningful win at family scale.** Blank-node resolutions after removals degrade the tree
  toward O(n) until updates repopulate it.

Conclusion: bandwidth is a *supporting* argument (one shared commit instead of N sender commits is
the real structural win); **PCS and the deletion discipline are the reasons to build this.** The
doc says so wherever it matters, and the staged plan gates shipping on the PCS proof, not on
bandwidth benchmarks.

---

## 2. What already exists to build on (inventory)

Every claim traced to the tree. This is the substrate the tree layers onto — none of it is
replaced.

**Crypto primitives (reused unchanged — this is a hard rule, §10):**

| Piece | Site | Reuse in TreeKEM |
|---|---|---|
| Hybrid KEM encap/decap (X25519+ML-KEM-768, transcript-bound HKDF) | `crypto.rs:49` (`encapsulate_to`), `:79` (`decapsulate`), `:106` (`combine`), `:123` (`kem_transcript`) | Path-secret encryption to copath resolutions; Welcome wraps |
| AES-256-GCM seal/open (+ reproducible variant) | `crypto.rs:134`, `:157`, `:173` | All node/epoch payloads; content path untouched |
| Hybrid signature + verify | `identity.rs:216`, `:83` | Commit/Proposal/Welcome/GroupInfo signing |
| Deterministic keypair from a 32-byte seed (HKDF → ed25519/x25519 + ChaCha20Rng → ML-KEM) | `identity.rs:161-178` | **Node keypairs derived from node secrets** — the exact pattern TreeKEM needs (path secret → node keypair) already exists and is shipped |
| `HavenId` full hybrid bundle, wire codec | `identity.rs:45`, `:107` | Leaf/node public key material; a tree node's public state is a (kem_x, kem_pq) pair — a strict subset of `HavenId` |

**Epoch substrate (kept as the content layer + legacy path):**

| Piece | Site | Role under TreeKEM |
|---|---|---|
| Per-event key derivation from epoch key | `groupkey.rs:120` (`derive_event_key`) | Unchanged |
| Deterministic event sealing (mailbox dedup, GC) | `groupkey.rs:167-207`, `crypto.rs:157` | Unchanged — the re-seal/dedup/GC economy survives intact |
| Event open + device-authored bind | `groupkey.rs:211`, `:246` (`open_event_in_epoch_authored`) | Unchanged |
| KeyCommit seal/open (per-recipient hybrid fan-out) | `groupkey.rs:68`, `:88` | Legacy circles only; MLS circles stop emitting it (§4.5) |
| Opaque mailbox prefixes from circle secret | `groupkey.rs:108` (`mailbox_prefix`) | Unchanged; circle-secret carriage moves (§4.6) |
| Epoch state + rotation + pruning | `lib.rs:1025` (`Circle`), `:1110` (`ensure_epoch`), `:1129` (`rotate_epoch`), `:1145` (`rotate_if_stale`), `:1165` (`prune_epoch_keys`) | `rotate_if_stale` becomes the **PCS chokepoint** (§6.4); pruning bounds carry over |
| Commit ingestion + own-device convergence (converge-on-larger-key) | `lib.rs:1300` (`receive_key_commit`), `:1345-1350` | The precedent + shape for fork resolution (§5.2) |
| Early-event buffering (cap 512, deduped, persisted) | `lib.rs:1379` (`receive_epoch_event`), `:1413`, `:2780` | Reused verbatim for early commits/welcomes |
| The one safe rotation chokepoint: full bundle = new commit + full history re-seal | `lib.rs:2238` (`epoch_sync_bundle_inner`), `:2242-2253` | Same chokepoint drives tree commits + path updates |
| Commit caching against mailbox growth | `lib.rs:2287-2315` | Same pattern for cached tree commits |
| State persistence + additive merge | `lib.rs:2658` (`export_state`), `:2697` (`import_state`), `:2730` (`merge_circle`) | Tree state rides the same blob (§5.4) |

**Identity/roster machinery (the leaf-credential layer, shipped):**

| Piece | Site | Role |
|---|---|---|
| `DeviceCredential` (account-signed device bundle) | `device.rs:43`, issue `:73`, verify `:84` | **The leaf credential.** Nothing new to invent |
| `DeviceList` versioned signed roster, union merge, revocation stickiness | `device.rs:134`, `:203`, `:225` | The authorization oracle for Add/Remove proposals |
| Sender-device → account resolution | `device.rs:399` (`author_and_bundle_for_device`), `lib.rs:2938` | Verifies commit signers |
| Capability marker pattern (signed, monotonic, absence-safe) | `device.rs:430` (`SeedDropCapability`), profile `sd` field `lib.rs:1757`, `:1817-1843` | The `mls` marker copies this exactly (§7.1) |
| All-present-positive circle gate | `device.rs:534` (`circle_fully_seed_drop_capable`), consulted `lib.rs:2279` | The MLS gate composes with it (§7.2) |
| Self-sync key grant (KEM-wrap a 32-byte secret to a device bundle) | `device.rs:505` (`seal_self_sync_key`) | The Welcome's secret-delivery rail is this exact pattern |
| Roster-change → rotation | `lib.rs:2823` (`verify_and_store_roster`), `:2191` (`register_device`) | Becomes roster-change → Add/Remove proposal+commit |

**Transport model (constraints, not code to change):** content-addressed mailboxes with TOUCH
liveness + 30-day TTL + 48 h grace (`docs/RELAY-AND-DEPLOY.md:78-115`); full-history re-seal
backfill roughly daily; `export_epoch_head` (`lib.rs:2351`) pushes the current commit alongside
every post so relay-only readers aren't stranded between backfills. Devices offline for days;
no ordering guarantees anywhere.

The inventory's punchline: **propose/commit/welcome/pending/converge/persist all have shipped
analogues.** What does *not* exist is the ratchet tree itself — tree math, path secrets, the
one-way epoch schedule, and fork resolution across it. That is the new code, and it is where the
crypto-review burden concentrates (§10).

---

## 3. The tree: leaves, credentials, node key material, wire formats

### 3.1 Shape

A standard MLS-style **left-balanced binary tree** over an array of node slots (leaf i at array
index 2i; parent/sibling by index arithmetic — pure functions, no allocation games). Leaves are
**devices**; interior nodes are key-agreement-only. The *account* is not a tree node — it is the
credential root that vouches for leaves, exactly as seed-drop left it. Two sibling devices of one
account are two independent leaves (see §5.3 for why this is required, not just convenient).

A leaf slot holds:

- the device's **leaf keypair** — a fresh hybrid KEM keypair generated for the tree, *not* the
  device's long-term `HavenId` KEM keys (so leaf updates don't rotate the device identity and a
  leaf-secret compromise doesn't expose the device's DM/self-sync decapsulation key);
- the **leaf credential** = the existing `DeviceCredential` (`device.rs:43`) binding the device to
  its account, plus a device-signed binding of the leaf public key to the device id (so a stolen
  credential can't be replayed onto an attacker-chosen leaf key).

An interior node holds either **blank** (after a Remove, until a path repopulates it) or a hybrid
KEM public key pair `(node_x: 32, node_pq_ek: 1184)` plus the standard unmerged-leaves list.

### 3.2 Node key material on the hybrid KEM

All node secrets are 32 bytes. A node keypair is **derived deterministically** from its node
secret using the exact pattern `Identity::from_seed` ships (`identity.rs:161-178`): HKDF-expand
the secret into an X25519 static secret and a ChaCha20Rng seed for `MlKem768::generate`. Labels
(HKDF-SHA256 throughout, matching the house style of `identity.rs:162` / `groupkey.rs:121`):

```
path_secret[0]        = leaf_secret (fresh 32 random bytes from OsRng)
path_secret[i+1]      = HKDF(salt="haven-treekem-v1", ikm=path_secret[i], info="path")
node_secret[i]        = HKDF(salt="haven-treekem-v1", ikm=path_secret[i], info="node")
node keypair          = derive(node_secret):  x25519 sk = HKDF(info="x25519")
                                              ml-kem    = MlKem768::generate(ChaCha20Rng(HKDF(info="ml-kem-768")))
commit_secret         = HKDF(salt="haven-treekem-v1", ikm=path_secret[root], info="commit")
```

Encrypting a path secret to a copath resolution node uses `encapsulate_to`-style hybrid KEM
against that node's `(node_x, node_pq_ek)` — the same transcript-bound `combine` as `crypto.rs:106`
with a tree-specific info label (`"haven-treekem-ct-v1" ‖ group_id ‖ epoch ‖ node_index`) so a
tree ciphertext can never be confused with a content wrap.

### 3.3 Epoch key schedule

One shared sequence per MLS circle (contrast: today every member runs their own —
`lib.rs:1019-1024`). All labels versioned and domain-separated:

```
epoch_context_n   = blake3("haven-mls-ctx-v1" ‖ group_id ‖ n ‖ tree_hash_n ‖ confirmed_transcript_hash_n)
joiner_secret_n   = HKDF(salt=init_secret_{n-1}, ikm=commit_secret_n, info="joiner" ‖ epoch_context_n)
epoch_secret_n    = HKDF(salt="haven-mls-epoch-v1", ikm=joiner_secret_n, info=epoch_context_n)
init_secret_n     = HKDF-expand(epoch_secret_n, "init")        # feeds n+1; the ONE-WAY link
sender_root_n     = HKDF-expand(epoch_secret_n, "senders")
confirm_key_n     = HKDF-expand(epoch_secret_n, "confirm")     # keys the commit's confirmation MAC
welcome_key_n     = HKDF-expand(joiner_secret_n, "welcome")    # what a Welcome delivers is joiner_secret
sender_key_n[leaf]= HKDF(salt=leaf_id(32), ikm=sender_root_n, info="haven-mls-sender-v1" ‖ group_id ‖ n)
```

`sender_key_n[leaf]` is a **32-byte epoch key in exactly today's sense**: it is what gets written
into `my_epoch_keys[n]` (own leaf) and `peer_epoch_keys[(account_hex, n)]` (each member's leaves
resolve to their account — the same account-keyed slot `receive_key_commit` fills today,
`lib.rs:1360-1364`). Everything downstream — `derive_event_key` (`groupkey.rs:120`), deterministic
salts, mailbox dedup, `pending_epoch`, `key_for` (`lib.rs:1191`) — runs **byte-for-byte unchanged**.
That containment is the whole integration strategy: the tree changes how the 32 bytes are agreed,
never how content is sealed.

Sibling devices of one account get *distinct* sender keys (leaf-scoped). The read path already
keys by account; for accounts with multiple leaves the ingest stores the key under
`(account_hex, epoch, leaf_hint)` — a one-field widening of the `peer_epoch_keys` map key, with
the envelope's existing `sender` field (`groupkey.rs:139`) as the hint. This removes the very
collision that forced converge-on-larger-key (§5.3).

### 3.4 Wire formats (length-prefixed, `device.rs` house style)

All integers LE; `lp(x)` = u32 length ‖ bytes; the minimal `Reader` at `device.rs:580` parses all
of these. Domain-separation tags follow `CRED_DOMAIN`/`LIST_DOMAIN` (`device.rs:28-30`).

```
LeafNode        = leaf_kem_x(32) ‖ leaf_kem_pq(1184) ‖ lp(device_credential) ‖ lp(leaf_binding_sig)
                  # leaf_binding_sig: DEVICE-signed over "haven-mls-leaf-v1" ‖ group_id ‖ leaf keys
ParentNode      = flags(1: blank?) ‖ node_kem_x(32) ‖ node_kem_pq(1184) ‖ u32 n_unmerged ‖ leaf_index*4×n
RatchetTree     = u32 n_slots ‖ (leaf: 0x01 ‖ LeafNode | parent: 0x02 ‖ ParentNode | blank: 0x00)*
                  # ~1.2 KB per non-blank node; a 32-leaf tree ≈ 40–75 KB. Travels as a
                  # content-addressed blob (like media refs), NOT inline in every commit.
Proposal        = ptype(1: add=1/remove=2/update=3) ‖ group_id lp ‖ epoch(8)
                  ‖ [add: lp(LeafNode)] [remove: leaf_index(4)] [update: lp(LeafNode)]
                  ‖ sender_leaf(4) ‖ lp(hybrid_sig over "haven-mls-prop-v1" ‖ body)
UpdatePath      = lp(LeafNode) ‖ u32 n_nodes ‖ ( node_kem_x(32) ‖ node_kem_pq(1184)
                  ‖ u32 n_cts ‖ ( resolution_index(4) ‖ eph_x(32) ‖ lp(pq_ct) ‖ lp(wrapped_path_secret) )*n_cts )*n_nodes
Commit          = group_id lp ‖ epoch(8) ‖ parent_commit_hash(32) ‖ u32 n_props ‖ lp(Proposal)*n
                  ‖ has_path(1) ‖ [lp(UpdatePath)] ‖ tree_hash(32) ‖ lp(confirmation_mac)
                  ‖ sender_leaf(4) ‖ lp(hybrid_sig over "haven-mls-commit-v1" ‖ all preceding bytes)
GroupInfo       = group_id lp ‖ epoch(8) ‖ tree_blob_ref lp ‖ confirmed_transcript_hash(32)
                  ‖ tree_hash(32) ‖ signer_leaf(4) ‖ lp(hybrid_sig "haven-mls-ginfo-v1")
Welcome         = lp(GroupInfo) ‖ u32 n_joiners ‖ ( joiner_device_id(32)
                  ‖ eph_x(32) ‖ lp(pq_ct) ‖ lp(wrapped: joiner_secret(32) ‖ path_secret_opt) )*n
                  # per-joiner wrap = hybrid KEM to the joiner's DEVICE BUNDLE — the
                  # seal_self_sync_key rail (device.rs:505), verbatim.
```

**New wire TAGs** in the `receive` router (`lib.rs:2359-2387`), continuing `0x02/0x03/0x04`:

```
TAG_MLS_COMMIT   = 0x05    TAG_MLS_WELCOME = 0x06    TAG_MLS_PROPOSAL = 0x07
```

A pre-MLS client that fetches one of these hits the `_ => receive_legacy` arm, fails the JSON
parse, and returns a per-envelope error — harmless and already how any corrupt envelope behaves,
but §7.3 explains why a legacy client essentially never fetches one (MLS wires are only emitted
in fully-capable circles). Commit/Welcome mailbox entries are TOUCH-refreshed by their committer
like any other envelope; the current commit additionally rides `export_epoch_head`
(`lib.rs:2351`) so it reaches relay-only readers promptly.

Sizes for the record: hybrid signature 3 373 B (64 Ed25519 + 3 309 ML-DSA-65); ML-KEM-768 ct
1 088 B, ek 1 184 B; `HavenId` bundle 3 200 B; one hybrid path wrap ≈ 1 180 B.

---

## 4. Operations mapped onto the existing flow

### 4.1 Create (circle flips to MLS — §7.2)

The flipping device builds a 1-leaf tree from its own device, then immediately issues Add
proposals + one Commit for every authorized device of every member (from the verified
`device_lists`, `lib.rs:1213`) and Welcomes for each. Deterministic **creator election** so two
devices don't both create: the member with the lexicographically-smallest account id among those
that have observed full capability creates; anyone else who created concurrently loses the §5
tie-break and rejoins via the winner's Welcome. (Same "conflicts resolve by lowest-committer-id"
convention `GROUP-KEYING.md` already documents for concurrent epoch bumps.)

### 4.2 Add (new device enrolled / new member joins)

Trigger: `register_device` (`lib.rs:2191`) or a roster arriving with a new authorized device
(`verify_and_store_roster`, `lib.rs:2823`) — the exact sites that today call `rotate_epoch`.
Any current member's device may commit the Add (no DS, no designated committer). The commit
carries the Add proposal + an UpdatePath (committer re-keys its path, standard MLS hygiene); the
committer also emits a Welcome wrapped to the new device's bundle. Authorization rule enforced by
every verifier: **an Add's LeafNode credential must chain to an account that is a circle member
(or the committer's own account), via the verified roster** — the same oracle as
`authorized_device_and_account` (`lib.rs:2938`).

### 4.3 Remove (revocation & member removal — the seed-drop evolution)

Trigger: a roster revocation (device) or `purge_member_from_circle` (member, `lib.rs:1261`).
The removing device commits Remove(leaf...) with an UpdatePath; removed leaves' path nodes are
blanked; the removed device can decrypt **no** path secret in the commit (its subtree is excluded
by construction) and therefore cannot derive `epoch_secret_{n+1}` — the same guarantee as
`key_commit_revokes_removed_member` (`groupkey.rs:338`), now with a one-way schedule behind it.

> **Semantic change, called out honestly.** Today "remove" is *per-viewer*: `purge` rotates **my**
> epoch so **my** future posts exclude them, while another member who keeps them keeps sealing to
> them (each member runs their own epoch). A shared tree cannot express per-viewer cryptographic
> exclusion: everyone in the tree derives every sender key. Under MLS, a Remove is **circle-wide**:
> any member's removal cuts the target off from *everyone's* new content in that circle. This is
> arguably what users expect of "remove from circle," and it matches the no-owner moderation
> philosophy (any member can also re-Add, just as any member can remove — `social.rs:66-70`'s
> "every member holds their own removal power"). Per-viewer *hide* remains the local,
> non-cryptographic filter it is today. **This is a product-behavior decision and is a named gate
> at M2 (§9) — if per-viewer cryptographic exclusion must be preserved, that circle cannot flip to
> MLS and stays on sender-keys; the capability gate makes that a per-circle choice, not a fork of
> the protocol.**

### 4.4 Update (the PCS operation)

A device draws a fresh leaf secret and commits an UpdatePath — no membership change. Cadence in
§6.4. Cost: §1.3's ~16 KB at 32 leaves.

### 4.5 What replaces KeyCommit

In an MLS circle the `TAG_KEY_COMMIT` fan-out (`lib.rs:2306-2315`) stops: the commit *is* the key
distribution. `epoch_sync_bundle_inner` emits, in order: roster wire (unchanged) ‖ cached current
`TAG_MLS_COMMIT` (cache pattern identical to `cached_commit`, `lib.rs:1048`) ‖ the full-history
re-seal under `sender_key_n[my leaf]` — same shape, same chokepoint, same idempotence.

### 4.6 Circle-secret carriage

Today the stable per-member `circle_secret` (mailbox-prefix derivation, `groupkey.rs:108`) rides
the KeyCommit payload (`groupkey.rs:46`). With KeyCommit gone, an MLS circle carries it in a small
**epoch-sealed control frame** (a `TAG_EPOCH_EVENT` whose event kind is internal, never rendered),
emitted whenever a member's secret is missing from a peer's ack set and in every Welcome's
GroupInfo extension for joiners. No change to `mailbox_prefix` or GC.

---

## 5. Concurrency and convergence without a delivery service (the make-or-break)

RFC 9420 assumes a Delivery Service that serializes commits: exactly one commit succeeds per
epoch, everyone applies the same one. Haven has *nothing* that can play that role — mailboxes are
blind content-addressed stores, two members can commit within the same hour and their commits
reach different subsets of devices days apart, and the design mandate forbids adding a serializer
(zero-recurring-cost, no coordinating server). So forks are not an error path; they are the
weather. The design makes them **deterministic, bounded, and lossless**.

### 5.1 The total order

Every commit names its parent: `parent_commit_hash` = blake3 of the commit it extends (epoch n's
confirmed commit), forming a hash chain. Two commits with the same parent are a **fork at epoch
n+1**. Resolution rule, applied identically and locally by every device with no communication:

> **The commit with the lexicographically larger blake3 hash of its full signed bytes wins.**
> Ties are impossible (distinct bytes ⇒ distinct hashes). The comparison is total, deterministic,
> and verifiable by anyone holding both commits.

This is the shipped converge-on-larger-key rule (`lib.rs:1345-1350`: "deterministically converge
on the numerically-larger key — both devices pick the SAME winner independently") promoted from
"two siblings minted different random keys" to "two members minted different commits." Same
proof shape: any two devices that have seen the same set of candidate commits compute the same
winner; seeing more candidates can only switch the winner in the same direction for everyone;
convergence is monotone in information received. Hash order (not committer-id order) is used so an
adversarial member cannot *systematically* win forks by grinding a low id — grinding a hash means
grinding their own signature bytes, which costs one signature per attempt for a coin-flip; and
winning a fork grants nothing (the losing proposals get rebased, §5.2.3).

**Why not epoch-max, like today?** Today's rule converges *values* for the same slot; commits are
*state transitions* — picking the larger of two divergent trees isn't meaningful. The hash order
picks a transition; the chain rule below makes the pick stick.

**Chain extension beats hash.** If fork branch A already has a child commit when a device learns
of branch B (e.g. the device was offline for two epochs), longest-valid-chain wins first and hash
order only breaks equal-length forks at the tip. Reorg depth is bounded in practice by the commit
cadence (weekly + membership changes) times the offline window; a device offline past
`MAILBOX_TTL` (30 d) re-enters via Welcome anyway (§5.5), which caps how much chain any device
ever needs to re-evaluate. State kept: the last `KEEP_EPOCHS`-deep chain of confirmed commits —
the same bound as today's key retention (`lib.rs:1166`).

### 5.2 What happens on a fork, mechanically

Device D is at epoch n. Two commits C_a, C_b arrive (any order, possibly days apart), both with
parent = commit_n.

1. **First candidate applies immediately.** D processes C_a: verifies signer (leaf → account via
   roster, `lib.rs:2938`), verifies proposals are roster-authorized, decrypts its path secret,
   derives `epoch_secret_{n+1}^a`, derives all sender keys, stores them under epoch n+1, marks
   C_a the provisional tip. Content flows; nobody waits.
2. **Second candidate triggers the tie-break.** C_b arrives; same parent. D compares hashes. Say
   C_b wins. D derives `epoch_secret_{n+1}^b`, **replaces** the tip, and *keeps* the losing
   branch's derived sender keys in the **fork cache**: `fork_keys[(epoch, commit_hash_prefix)] →
   sender keys`, bounded to KEEP_FORKS = 2 per epoch within the existing KEEP_EPOCHS = 4 window
   (mirroring `prune_epoch_keys`, `lib.rs:1165`). If C_b loses, nothing changes except C_b's keys
   enter the fork cache.
3. **Losing proposals are rebased, not lost.** The committer of the losing branch (and only it —
   it can recognize its own lost commit) re-issues its proposals with parent = the winning commit
   at its next bundle (`epoch_sync_bundle_inner` is reached daily by every client,
   `lib.rs:2242-2253`). Adds/Removes are idempotent to re-apply; an Update just re-keys again.
   Crucially the *security-relevant* effect of a lost Remove is not delayed in the dangerous
   direction: the removed leaf was excluded from the loser's path encryption, and the rebase
   re-excludes it one epoch later; in the interim the winning epoch may still include the target —
   identical exposure to today's window between "I revoked on my phone" and "my Mac learns the
   roster," which the roster's higher-version-wins already bounds.

### 5.3 Events sealed under the losing fork — why nothing is lost

An author who committed C_a (lost) sealed posts under `sender_key^a[leaf]` before learning it
lost. Three independent recovery layers, two of which ship today:

1. **Fork cache (new, the fast path).** Receivers who processed C_a hold its sender keys in the
   fork cache and open those events immediately — the envelope's epoch + sender fields locate the
   right cache entry exactly as `key_for` does today (`lib.rs:1191`).
2. **`pending_epoch` (shipped).** A receiver who never saw C_a buffers the event (cap 512,
   deduped, persisted across restarts — `lib.rs:1413`, `:2780`), exactly as an event today
   buffers when its KeyCommit hasn't arrived.
3. **Daily re-seal (shipped, the backstop).** The author's next full bundle re-seals its **entire
   history** under the current (winning) epoch's sender key (`lib.rs:2319-2334`). Every event ever
   sealed under a losing fork is re-published under the winning chain within one backfill cycle,
   deterministically (`groupkey.rs:186` keeps the mailbox deduped). This is the property that
   makes fork resolution *safe to get conservatively wrong*: even if both fork caches and the
   pending buffer miss, content converges because history itself re-converges daily.

**Own-device (sibling) convergence** becomes a *special case of the general rule* rather than the
bespoke converge-on-larger-key patch: two siblings that concurrently commit produce a fork; both
resolve it by hash; both end at the same tip; their tree states are bit-identical thereafter
(tree state is a pure function of the applied commit chain). The `merge_circle` import-union
(`lib.rs:2751-2760`) gains the commit chain + fork cache as unioned maps with the same
or-insert discipline.

### 5.4 Tree-state persistence

New `PersistTree` alongside `PersistCircle` in the state blob (`export_state`, `lib.rs:2658`):
group_id, chain of the last KEEP_EPOCHS confirmed commits (hashes + bytes), the current public
tree (or its blob ref + bytes), my leaf index + leaf secret + path secrets, fork cache, and the
derived-epoch cache. All secrets already live inside the platform-encrypted state blob exactly
like `my_epoch_keys` does today; deletion discipline in §6.3 governs what may *not* be persisted
(consumed message-window keys, pre-image path secrets after merge).

### 5.5 The device that slept through everything

Offline < TTL: it fetches the commit chain from any member's mailbox (commits are TOUCH-kept by
their committers), replays it, and re-derives. Offline past the point where the chain was pruned
(> ~4 epochs) — it cannot replay; **it re-enters via Welcome**: any current device that sees its
(still-authorized) leaf request catch-up re-Welcomes it at the current epoch, and history arrives
via the ordinary re-seal backfill. "Rejoin instead of replay" is the same recovery contract the
epoch system already has ("a peer gone for weeks is handed the CURRENT commit plus my whole
history re-sealed under it — it never needs a key it slept through," `lib.rs:1059-1061`).

---

## 6. Key schedule, forward secrecy, PCS — and the re-seal reconciliation

### 6.1 The honest FS question first

Today the engine **deliberately defeats FS for old content**: every full bundle re-seals the
author's entire history under the *current* epoch key (`lib.rs:2319-2334`), so a late joiner or a
device offline for a month can always catch up. Consequence: an attacker holding the **current**
epoch key + mailbox access reads the whole history the next time the author backfills. That is a
considered availability trade (`GROUP-KEYING.md` documents it; the 30-day mailbox TTL and
KEEP_EPOCHS bound it), and **this design keeps it**. Removing it would break the offline-first
recovery contract that the entire product sits on, and no tree changes that arithmetic.

So what does per-epoch FS actually protect in Haven's model? Precisely this: **ciphertext an
attacker captured and retained beyond the system's own retention.** A relay operator or network
observer who hoarded epoch-n envelopes (or a backup of an old mailbox) and *later* compromises a
device gets nothing for epochs whose secrets were deleted — the device no longer holds them and,
under TreeKEM, cannot re-derive them (one-way `init_secret` link, §3.3). Today that same attacker
finds up to 4 retained *independent random* epoch keys per member; after this design they find the
same 4-epoch window but with a schedule that provably cannot be run backwards past a deletion, and
with the *live-lane* additions below shrinking what any single stolen secret opens.

**The honest security claim, stated once and repeated in §11:** Haven's forward secrecy is
**epoch-granular** (weekly + on membership change), not per-message, and history re-sealed for
availability is always readable under the *current* epoch. TreeKEM does not change that sentence;
it makes the epoch boundary cryptographically one-way, adds PCS, and puts every secret on a
deletion schedule. A per-message sender ratchet is specified (§6.5) as an *optional later stage*
for DMs and live traffic, with its real-world value in this delivery model assessed honestly
there.

### 6.2 Schedule recap and where each secret dies

Full derivation in §3.3. Lifetimes:

| Secret | Created | Deleted | Deleting code path |
|---|---|---|---|
| `leaf_secret` / path secrets | own Update/Add commit | on next own path update (replaced), and always on Remove of self | commit application |
| `commit_secret` | commit application | immediately after `joiner_secret` derived (never persisted) | commit application |
| `joiner_secret_n` | commit application | after `epoch_secret_n` derived — **except** the committer retains it while any issued Welcome is un-acked, ≤ TTL | Welcome ack / TTL sweep analog |
| `init_secret_n` | epoch n | when epoch n+1 confirms (consumed as salt) | commit application |
| `epoch_secret_n` | epoch n | when epoch n leaves the KEEP_EPOCHS=4 window | `prune_epoch_keys` extension (`lib.rs:1165`) |
| `sender_key_n[leaf]` (the 32-byte "epoch keys") | on demand from `sender_root_n` | same 4-epoch window — **identical bound to today** | `prune_epoch_keys`, unchanged |
| fork-cache keys | fork resolution | KEEP_FORKS=2 within the 4-epoch window | same pruner |

### 6.3 Where FS bugs would live — named proof obligations

These are the places a "we have FS" claim silently dies; each is a test named in §9:

1. **`export_state` persisting a consumed secret.** `commit_secret`/`init_secret` must never
   appear in `PersistState`; a state-blob backup would otherwise fossilize the backward link.
   *Proof: serialize state after a commit; assert byte-scan absence of both secrets.*
2. **The fork cache as an FS leak.** Losing-fork keys are keys; they must age out on the same
   pruner. *Proof: pruning test over a forked history.*
3. **Welcome retention.** The committer holds `joiner_secret` for un-acked Welcomes; a joiner that
   never appears must not pin it forever. Bound = mailbox TTL (30 d), after which the joiner
   re-enters via a fresh Welcome anyway. *Proof: TTL-expiry test.*
4. **The re-seal lane masquerading as FS.** Documentation + test must assert that history
   re-sealed at epoch m is readable with `sender_key_m` regardless of when it was authored — i.e.
   the claim in §6.1 is enforced *as stated*, and no one later "optimizes" re-seal into a hidden
   long-lived archive key that widens exposure beyond the current epoch.
5. **`merge_circle` resurrecting pruned keys.** Import unions epoch keys (`lib.rs:2753`); an old
   exported blob must not re-inject keys the pruner deleted. Today this is benign redundancy;
   under a one-way-schedule claim it is a regression. *Proof: import-after-prune test asserting
   the window stays 4.*

### 6.4 PCS: cadence, cost, and what "healed" means

**Cadence — reuse the one safe chokepoint.** `rotate_if_stale` (`lib.rs:1145`) already fires
weekly inside the full bundle, the only place a rotation is safe because the re-seal rides the
same batch (`lib.rs:2242-2253`). In an MLS circle that same trigger emits a **leaf Update commit**
instead of minting a random key. Result: every active device refreshes its leaf at least weekly;
membership/roster changes commit immediately (as today, `lib.rs:2863`, `:2886-2890`). No new
timers, no platform work — the cadence is inherited.

**Cost at the design point (16 members × 2 devices = 32 leaves, depth 5):**
UpdatePath = leaf node (~1.2 KB + credential ~3.4 KB + binding sig 3.4 KB) + 5 × node key
(1 216 B) + ~5 × hybrid wrap (1 180 B) + commit framing + hybrid signature (3.4 KB) ≈ **~23 KB**
per device per week worst case, and the commit is *shared* (one per circle-week in the common
case, since any device's Update refreshes the epoch for everyone; devices whose path is stale
longer than a bound of ~4 weeks force their own). Compare: today the same fleet circulates 16
independent KeyCommits ≈ 600 KB/rotation-cycle. Even with per-device Updates staggered weekly,
32 × 23 KB ≈ 740 KB/week upper bound — same order as today, with PCS bought for it. (Numbers are
dominated by ML-DSA signatures and ML-KEM material either way; the PQ tax is a constant of the
house, not of this design.)

**What healing actually means.** Attacker exfiltrates device D's full tree state at epoch n
(leaf secret, path secrets, epoch secrets) but D remains in the user's hands. At D's next weekly
Update, D samples a fresh `leaf_secret` from OsRng — entropy the attacker does not have — and the
resulting `commit_secret` mixes into `epoch_secret_{n+1}` via material the attacker can decrypt
only with keys that are themselves replaced by this very commit. From n+1 the attacker's state
opens nothing new: **compromise windows close automatically within one week**, without the user
ever knowing there was a compromise. (Contrast today: the identical exfiltration reads every
future epoch forever, because each new random epoch key is KEM-wrapped to the *long-term device
bundle* the attacker exported — nothing ever heals.) Two honest caveats stated plainly:
a *persistent* compromise (attacker still resident on the device) is healed by nothing — PCS is
for past exfiltration, not rootkits; and the healing epoch must itself reach peers, so a healed
device that never syncs heals no one — bounded by the same weekly chokepoint.

### 6.5 The optional per-message lane (deferred, with reasons)

A classic MLS secret tree / sender ratchet (`chain_0[leaf] = HKDF(sender_root, leaf)`,
`key_i, chain_{i+1} = HKDF(chain_i)`, delete-on-use, bounded skipped-key cache) is specified as
stage M6 for **DMs and live traffic only**, because in Haven's mailbox model its marginal value is
small: envelopes must remain decryptable by devices that come online days later, so *receivers*
cannot delete message keys aggressively without breaking the mailbox contract; and the daily
re-seal lane re-publishes content under the plain epoch key regardless. Per-message keys would
shrink the blast radius of a *single stolen sender key* from an epoch-week of one sender's traffic
to one message — real, but the smallest win on the board and the largest multiplier on the
skipped-key state-management risk (the exact class of bug the pending/dedup machinery took months
to harden). It stays out of the core proposal; the key schedule reserves the label space
(`"senders"` root) so adding it later is additive.

---

## 7. Capability gating and migration (the seed-drop pattern, verbatim)

### 7.1 The `mls` marker

Copy `SeedDropCapability` (`device.rs:430`) exactly, one field wider:

- **Profile card:** an `"ml": <version>` key in the account-signed JSON payload next to `"sd"`
  (`lib.rs:1757`). Older clients ignore unknown JSON keys (proven by `sd` shipping the same way);
  verification and the monotonic `insert` mirror `profile_seed_drop_version`
  (`lib.rs:1817-1843`) into a new `mls_capable` set beside `seed_drop_capable` (`lib.rs:1220`).
- **Roster wire:** ⚠️ **the existing trailer is not appendable.** `SeedDropCapability::from_bytes`
  consumes *all* bytes after offset 36 as the signature (`device.rs:476-484`), so appending an
  `mls` record behind it would make every 1.0.6/1.0.7 peer fail the seed-drop marker's verify and
  regress those accounts to "legacy" in the eyes of the exact fleet mid-seed-drop-migration.
  Therefore the roster trailer stays untouched; the `mls` marker travels in the **profile only**,
  plus (belt-and-braces) a signed marker inside every `TAG_MLS_*` message a capable device emits.
  Version the trailer properly (length-prefixed record list) at the next unavoidable trailer
  break, not for this.
- Marker semantics: signed by the account, monotonic, learned-never-inferred; a missing marker is
  always "legacy," never "downgraded" — the invariant the codebase has paid for repeatedly
  (`device.rs:424-428` states it; `reference_selfsync_absence_tombstone` et al. are the scars).

`mls` v1 **requires** seed-drop v1: a device only advertises `ml:1` when it runs under a device
identity with a live credential (`use_device_identity`, `lib.rs:1625`, plus roster presence),
because leaves *are* device keys. This nests the gates: **MLS-capable ⊂ seed-drop-capable**, so
`retire_account_key` (`lib.rs:1233`) is already ON-or-flippable for any circle that can flip to
MLS — the tree never needs a "seal to the bare account key" notion at all, and the Welcome's
device-bundle wrap is the only KEM fan-out that remains.

### 7.2 The per-circle flip

`circle_fully_mls_capable(members, device_lists, mls_capable)` — the same all-present-positive
computation as `circle_fully_seed_drop_capable` (`device.rs:534`): every member affirmatively
verified `ml ≥ 1` **and** has a known roster **and** every authorized device in that roster is
individually capable (device-granular, carried per-device in the roster credential's wake — a
member with one un-upgraded iPad keeps the circle on sender-keys). Consulted at the same site
that computes `author_under_device` today (`lib.rs:2278-2279`). When it first becomes true *and*
the master switch (`set_mls_enable`, mirroring `set_seed_drop_retire`, `lib.rs:1615-1618`) is on,
the elected creator (§4.1) builds the tree and Welcomes the fleet. Until every member has
**joined** (acked its Welcome by emitting anything under the new epoch), the circle runs
**dual-stack**: sender-keys commits + epochs continue exactly as today, and MLS commits build up
alongside; content keys stay sender-keys-derived. The flip of *content* keying (§4.5) happens only
on all-joined — a second all-present-positive gate, so a member who never fetches their Welcome
never strands the circle.

### 7.3 Reversibility: a legacy device joins mid-flight

New member added whose account lacks `ml`, or a member links a legacy device (roster gains a
device that never advertises capability): `circle_fully_mls_capable` goes false **on positive
evidence of the new membership** (a verified roster/member-add — never on a missing marker), and
the circle **falls back to sender-keys for content** at the next bundle: `ensure_epoch` resumes
minting random keys (`lib.rs:1110`), KeyCommits resume fanning to `recipients_with_devices_gated`
recipients, and the re-seal lane republishes history under the sender-keys epoch so the newcomer
reads everything. The tree is **parked, not deleted** — commits stop, state persists — and if the
straggler upgrades, the circle re-flips by *resuming* the parked tree with Add commits for the new
devices (cheaper and less churn than re-creating). Park/resume is idempotent and crash-safe
because both directions are driven by recomputing the gate from verified state, never by an edge
trigger. A legacy member never sees MLS wires *going forward*; stale `TAG_MLS_*` mailbox entries
they fetch fail parse harmlessly (§3.4) and age out via the 30-day TTL.

### 7.4 Interaction matrix (mid-migration truth table)

| Circle state | Content keyed by | Commits emitted | A revoked device is cut off by |
|---|---|---|---|
| Any member not seed-drop-capable | sender-keys epochs, dual-seal incl. account key | KeyCommit | epoch exclusion (advisory vs. seed-holder) |
| All seed-drop, not all mls | sender-keys epochs, device-bundles only (`retire_account_key`) | KeyCommit | epoch exclusion, cryptographic |
| All mls, not all joined | sender-keys epochs (device-bundles) | KeyCommit **and** MLS commits (dual-stack) | epoch exclusion, cryptographic |
| All joined | **tree-derived sender keys** | MLS commits only | Remove commit + one-way schedule + PCS |
| Legacy device joins | reverts to row 2 within one bundle | KeyCommit resumes; tree parked | epoch exclusion, cryptographic |

---

## 8. OpenMLS vs home-grown: the call

**Call: home-grown TreeKEM layered on the existing epoch substrate.** Not close, once the
codebase evidence is on the table — but the costs are stated in §10, because "home-grown group
messaging crypto" should never read as the comfortable option.

**Why OpenMLS (or mls-rs, which D3 originally named — `DECISIONS.md:35-42`) loses here:**

1. **Ciphersuites.** Every ratified RFC 9420 ciphersuite is classical (X25519/P-256 HPKE,
   Ed25519/ECDSA). Haven's mandate is hybrid X25519+ML-KEM-768 and Ed25519+ML-DSA-65 *everywhere*
   (`crypto.rs:1-20`). Using OpenMLS means either accepting a classical group layer under a PQ
   product (regressing the headline guarantee — rejected by the locked decision) or implementing a
   custom hybrid ciphersuite + credential type inside someone else's HPKE/TLS-presentation
   framework — at which point we maintain a fork of the security-critical core of a large library
   *and* still don't get interop (nobody else runs that suite). `GROUP-KEYING.md:20-24` already
   recorded this exact verdict when it retired D3.
2. **The delivery-service assumption.** OpenMLS's state machine assumes commits arrive in order
   and exactly one wins per epoch; its answer to a fork is "the DS must prevent this." §5 *is* the
   hard part of this design, and it must be woven through commit application, state persistence,
   and the pending buffers — the deepest layer of any MLS library. Retrofitting hash-tie-break +
   fork caches + rebase into OpenMLS is open-heart surgery on foreign code; building it into our
   own ~small tree module is the design's center of gravity either way.
3. **The substrate mapping favors owning the seams.** Measured against what §2 inventories:
   propose/commit ≈ `seal_key_commit`/`receive_key_commit` + roster-authorization
   (`lib.rs:1300`, `:2823`); welcome ≈ `seal_self_sync_key` (`device.rs:505`); out-of-order
   tolerance ≈ `pending_epoch` (`lib.rs:1413`); convergence ≈ converge-on-larger-key
   (`lib.rs:1345`); persistence ≈ `export_state`/`merge_circle` (`lib.rs:2658`, `:2730`);
   rotation cadence ≈ `rotate_if_stale` (`lib.rs:1145`); credentials ≈ `DeviceCredential`
   (`device.rs:43`). Roughly **the entire MLS protocol layer except the tree math already exists
   in shipped, soaked, tested form** — OpenMLS would replace all of it with parallel machinery
   (its own storage provider, credential model, framing, pending state) that then has to be
   *reconciled* with the shipped machinery for the dual-stack migration to work at all.
4. **Portability.** The core must build for iOS/macOS (UniFFI), Android (JNI via
   `android/build-rust.sh`), musl relays, WASM (`device.rs:21` notes WASM-deterministic design),
   Windows/Linux desktop linking `core/` directly. Every added dependency multiplies that matrix;
   the tree module needs zero new dependencies (hkdf, blake3, ml-kem, x25519-dalek, ml-dsa are all
   in-tree today).

**What we deliberately give up:** OpenMLS's years of interop testing, its formal-analysis lineage
(the TreeKEM design we copy *is* the analyzed one — we inherit the design's proofs, not the
implementation's), and RFC-ecosystem review of the exact bytes. Mitigations in §9/§10: the tree
module is pure and deterministic (no clock, no RNG below the leaf-secret entry point — the
`device.rs:19-21` discipline), ships with cross-checked test vectors, property tests
(random partition schedules → all replicas converge), and is the named target of the external
crypto review at M7. We are not inventing cryptography — primitives are the shipped, audited
`crypto.rs`; the tree and schedule follow RFC 9420's structure with renamed labels — we are
implementing a known design against a delivery model the reference implementations refuse.

---

## 9. Staged plan (M0…M7)

Sizing honesty up front: **this is materially bigger than seed-drop.** Seed-drop re-pointed
signers and gated a recipient list over existing rails; this adds a new cryptographic subsystem
(~the size of `groupkey.rs` + `device.rs` combined for the tree module alone), a concurrency
protocol, and a two-gate migration — realistically **6–9 months of releases with soaks**, not a
two-release arc. Stages are ordered so every release is additive and shippable, mirroring
`SEED-DROP-DESIGN.md` §8; nothing before M4 changes what any circle seals content under.

| Stage | Scope | Proof obligation | Realistic release |
|---|---|---|---|
| **M0. Capability marker + tree state types** | `ml` marker in the signed profile (`"ml":1` beside `"sd"`, `lib.rs:1757`) + `mls_capable` set + `circle_fully_mls_capable` gate, all OFF; wire-format types (§3.4) + `PersistTree` skeleton, serialization only. Strictly additive. | Marker round-trips, forged/tampered/absent all safe (mirror `device.rs:835` test); 1.0.x peer parses a profile carrying `ml` (the `sd` precedent re-proven); types wire-round-trip byte-stably. | **1.0.8** (safe, additive; rides whatever else ships) |
| **M1. The tree module, pure** | `core/haven-p2p/src/treekem.rs`: array tree math, node keygen from secrets (§3.2), UpdatePath build/apply, blank/unmerged handling, epoch schedule (§3.3), fork tie-break + chain rule as pure functions. No engine wiring. Deterministic (caller-supplied entropy/time), WASM-clean. | Test vectors (fixed seeds → exact bytes) committed; property test: N replicas, random op + delivery-order schedules incl. partitions → identical tree hash + epoch secret at quiescence; removed-leaf-cannot-decrypt-path test; one-way test (epoch n secrets ⊬ epoch n−1). | **1.0.8–1.0.9** (additive, unwired — the `groupkey.rs` increment-1 pattern, `groupkey.rs:13-15`) |
| **M2. Propose/commit/welcome over mailboxes, shadow mode** | New TAGs in the `receive` router; commit chain + fork cache + Welcome flow wired into `NetState` for capable circles — but content keys stay sender-keys; the tree runs in parallel and is compared, never consumed. Creator election. **Named product gate: sign off the circle-wide-Remove semantic (§4.3) or scope MLS to circles that accept it.** | Two-sibling and 3-account×2-device sims: concurrent commits fork and converge identically on every replica; shadow epoch secrets agree across the fleet after arbitrary redelivery; a legacy client fed a `TAG_MLS_*` blob errors harmlessly. | **1.0.9** (beta-soaked shadow telemetry: fork rate, convergence lag) |
| **M3. Keying flip for fully-joined circles** | §4.5: `my_epoch_keys`/`peer_epoch_keys` filled from `sender_key_n[leaf]`; KeyCommit emission stops for those circles; circle-secret control frame (§4.6); dual-stack + all-joined gate (§7.2); park/resume fallback (§7.3). | **The headline test:** in a fully-MLS circle, a Removed device cannot derive `epoch_secret_{n+1}` nor open any post-Remove content, *and* cannot rejoin without a roster-authorized Add (evolves `s5_revoked_seedless_device_cannot_reenter_or_decrypt`, `device.rs:1038`). Interop: legacy-join mid-flight reverts within one bundle and the newcomer reads full history; deterministic re-seal dedup still byte-stable (mirror `groupkey.rs:301`). | **1.0.10** (the release headline; master switch OFF→staged ON like `set_seed_drop_retire`) |
| **M4. Welcome for offline joiners + roster integration** | `register_device`/revocation → Add/Remove proposals+commits (§4.2/4.3); Welcome-over-mailbox with TOUCH liveness + ack; sleeper re-entry (§5.5); tree blob as content-addressed ref. | A device offline 45 days (past TTL) re-enters via Welcome and reads full history via backfill; joiner-secret retention bounds (§6.3-3) hold; Welcome to a revoked-in-the-meantime device fails closed. | **1.0.10–1.0.11** |
| **M5. PCS cadence + deletion discipline** | Leaf Update on the `rotate_if_stale` chokepoint (§6.4); the full §6.2 deletion table enforced; pruner extended to fork cache + chain; §6.3's five FS-bug tests. | **The PCS test:** exfiltrate a device's full state at epoch n, let it Update, assert the stolen state opens nothing at n+1 (and the converse: without the Update it still would — proving the test has teeth). State-blob byte-scan for dead secrets. | **1.0.11** |
| **M6. (Optional) per-message sender ratchet for DMs/live lane** | §6.5, only if the M3–M5 soak says the state-management budget exists. | Skipped-key cache bounded under adversarial gap patterns; mailbox contract (days-late open) provably intact. | **1.1.x, explicitly cuttable** |
| **M7. External review + hardening** | Third-party crypto review of `treekem.rs` + schedule + fork protocol (the Kith security mandate applies: audit every feature); fuzz wire parsers; publish the design + vectors in `docs/`. | Review findings closed; fuzz corpus green in CI. | **before flipping the master switch to default-ON** |

Release-mapping honesty (the §8.1 discipline): M0–M2 are safe to ride ordinary releases because
they change no sealing behavior — the same property that let seed-drop S0/S1 ship in 1.0.6. M3 is
the re-rooting-shaped stage and gets the seed-drop-S5 treatment: its own release, its own beta
soak, master switch flipped per staged cohort, and the headline test green first. If the fork-rate
telemetry from M2's shadow soak is ugly (forks common, convergence slow on real fleets), M3 **does
not ship** until the §5 parameters are retuned — that gate is the design's honesty mechanism.

---

## 10. What makes this hard (the honest picture)

- **Fork resolution is the crux, and it is novel surface.** RFC MLS's security analyses assume the
  DS; our §5 protocol (hash tie-break + chain rule + fork cache + rebase) is the part with no
  reference implementation and no imported proof. It is deliberately shaped like the shipped
  convergence machinery, is pure and property-testable, and M2 runs it in shadow for a full soak
  before anything depends on it — but a subtle divergence bug here is the "two halves of a family
  silently stop reading each other" class, the worst failure mode this product has. This is where
  the engineering caution concentrates.
- **The crypto-review burden concentrates in ~three files.** `treekem.rs` (tree + schedule), the
  commit/welcome application path in `lib.rs`, and the §6.2 deletion table. Everything else reuses
  audited primitives unchanged (`crypto.rs`, `identity.rs` are *not* modified — a hard rule; any
  change there voids the reuse argument). M7's external review is scoped to exactly this surface.
- **State growth and pruning discipline.** Tree state, commit chains, fork caches, welcome
  retention — each is bounded on paper (§6.2); each is also exactly the kind of "bounded" that
  becomes a 98 GB leak when a loop condition is wrong (`reference_iroh_self_connect_leak` is the
  house cautionary tale). Every cache in this design has a named cap and a pruner test.
- **The dual-stack window doubles the machinery.** Between M3's flip and a circle's all-joined
  gate, both keying systems run. That is the price of no-flag-day, the same price seed-drop's
  dual-seal paid — but here the second stack is stateful (a tree), so park/resume (§7.3) must be
  idempotent under crashes mid-transition. Absence-is-never-information is again the discipline:
  both gate directions recompute from verified state; no edge triggers.
- **The per-viewer-removal semantic (§4.3).** A real product-behavior change hiding inside a
  crypto upgrade. It is surfaced as a named M2 gate precisely so it gets decided by the maker, not
  discovered by a user.
- **PCS can be oversold.** It heals *past* exfiltration on a weekly cadence; it does nothing
  against resident malware, nothing for a device that stops syncing, and nothing about the re-seal
  availability trade (§6.1). §11 words the claims so the marketing can't outrun them.
- **This is 6–9 months of releases, and the payoff is invisible.** No user-visible feature ships;
  the deliverable is two adjectives in the security documentation becoming true. The staged plan
  keeps every intermediate release independently valuable (M0–M2 cost nothing; M3+ each close a
  named gap) so the work survives being interleaved with feature waves.

---

## 11. Security claims summary

"Before" = today's shipped sender-keys + epochs + seed-drop (fully-capable circle,
`retire_account_key` ON). "After" = a fully-joined MLS circle, M5 complete. In both worlds:
content older than the mailbox TTL exists only on members' devices; history re-sealed for
availability is readable under the *current* epoch (§6.1 — unchanged, deliberate); and the hybrid
PQ envelope means a harvest-now-decrypt-later adversary gains nothing in either world.

**(a) Attacker with a stolen device key** (long-term device keypair + credential, no live access):

| | Before | After |
|---|---|---|
| Past content captured off the wire/relay | Epochs whose keys the device still held (≤ 4 retained) | Same window; older epochs unreachable **provably** (one-way schedule + deletion, not just "we deleted the values") |
| Future content | **Everything, forever, silently** — every future epoch key is KEM-wrapped to the stolen bundle; only a *noticed* theft + revocation stops it | Only until the device's next leaf Update (≤ 1 week): the Update's fresh entropy is wrapped to path keys the attacker's snapshot can't decrypt going forward. Noticed theft: Remove commit cuts instantly, as before |
| Re-enter after revocation | Cannot (roster forgery fails, `device.rs:1094-1099`) | Cannot (same roster authority gates every Add) |

**(b) Attacker with an old epoch secret** (epoch n, current is m > n+4):

| | Before | After |
|---|---|---|
| Epoch-n wire captures | Readable | Readable (an epoch secret is an epoch secret) |
| Later epochs | Unreadable, because each key is independent random — but *every member's* retained-key store is a flat exposure: one state blob leaks 4 epochs × all members | Unreadable **by construction**: `init_secret` chain is one-way; and the same state blob leaks the same 4-epoch window but nothing before a deletion point |
| Current mailbox (incl. re-sealed history) | Unreadable (re-seals are under epoch m) | Unreadable, same reason |

**(c) Attacker with the current epoch secret** (epoch m, exfiltrated without the device key):

| | Before | After |
|---|---|---|
| Current-epoch traffic + the re-sealed history in mailboxes | **Readable** — the availability trade, stated plainly | **Readable** — unchanged and stated plainly (§6.1) |
| Future epochs | Readable until a membership/roster change or weekly rotation mints a new key — but the new key is delivered wrapped to device bundles, so *without* a device key the attacker is cut off at the very next rotation (≤ 1 week) | Cut off at the next commit (≤ 1 week), same bound — plus the commit *proves* it: deriving m+1 requires decrypting a path secret with node keys the attacker lacks |
| Silent persistence | If the attacker also took the device key: forever (see (a)) | If the attacker also took the device key: one Update (see (a)) — **this composition is the whole reason to build TreeKEM** |

One sentence for the security page, honest on every word: *Haven circles get post-compromise
security (a compromised-then-recovered device heals within a week, automatically) and one-way
epoch-bounded forward secrecy (weekly, deletion-enforced), on the same post-quantum hybrid
primitives as everything else; per-message forward secrecy is not claimed, and history kept
available for your own offline devices remains readable under the current epoch by design.*

---

*Cross-references: `docs/SEED-DROP-DESIGN.md` (the pattern this plan copies), `docs/GROUP-KEYING.md`
(the epoch substrate and the original why-not-classical-MLS verdict), `docs/MULTI-DEVICE.md`
(device model), `docs/RELAY-AND-DEPLOY.md:78` (mailbox GC contract the Welcome flow rides),
`docs/DECISIONS.md` D3/D16 (superseded and honored, respectively), `docs/THREAT-MODEL.md` +
`docs/SECURITY-AUDIT-2026-07.md` (the FS/PCS findings this closes).*
