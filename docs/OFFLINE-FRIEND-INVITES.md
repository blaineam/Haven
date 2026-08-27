# Offline friend invites — async first contact over the relay mailbox

Status: DESIGN (approved 2026-08-27, "build after the sync fix lands"). Companion to
`docs/LINK-SYSTEM.md` (which notes scoped/expiring invite tokens as designed-not-implemented).

## Problem

Adding a friend requires both parties online at the same time, twice:

1. B (acceptor) → A (inviter): the hello is a live iroh dial fanned to the link's `?d=` device
   hints. `putHello`'s store-and-forward leg is dead for first contact: it writes only to B's OWN
   relays (which A never polls), and writing to A's relay 403s at `blob_forbidden`'s `is_known`
   gate — B is in no circle A's relay serves. Retry is a liveness poll (each foreground sync
   tick), not durable delivery.
2. A → B: the approval reply hello has the same shape in reverse. B only learns A's relays from
   frame 19 — which is only sent AFTER a live handshake succeeded.

The approval hold in the middle (`ConnectionsStore.addPending`, the unclaimed `__hello__`
mailbox slot) is already async. The hole is transport on either side of it.

## Design

### 1. The invite becomes a ticket (FriendTicket)

Same shape as `EnrollTicket` (`core/haven-p2p/src/enroll.rs`), new domain separation:

    account_id (32) · verify_hash (16) · one-time secret (32, CSPRNG) · issued_at ·
    expires (default 30 days — device linking uses 10 min; friendships wait) ·
    bootstrap_relays (the field the friend link is missing today; `haven-link:` transfer codes
    and EnrollTicket both already carry it) · device hints

Encoded in the share link/QR alongside the legacy fields. A ticket-less legacy link keeps
working with the live-only flow. A persists every issued ticket (a `PendingFriendInvites`
store — issued, consumed, expiry; multi-ticket, unlike desktop's in-memory `initiated`).

### 2. A stranger-writable, self-authenticating relay lane

New key family, evaluated ABOVE the `is_known` gate in `blob_forbidden`, alongside the
devroster/discovery exemptions — the codebase's own words for that pattern: "deliberately
un-gated… this signature check is the ONLY thing standing between a stranger and a victim's
roster" (`verify_devroster_put`).

    haven/invite/<inviter-acct>/<token-id>          ← B's acceptance drop
    haven/invite/<inviter-acct>/<token-id>/grant    ← A's approval grant

- `token-id = H(secret ‖ "haven-invite-id")` — the path reveals nothing about who is accepting.
- PUT allowed for ANYONE whose body verifies: `HVI1` magic, inviter acct, token-id, absolute
  `expires`, and a MAC keyed by `HKDF(secret, "haven-invite-mac")` — possession of the invite
  link IS the write capability. Replace-by-key idempotency; size cap 8 KB; per-signer rate cap
  on the HTTP path (the signed request head already proves a stable signer).
- GET/HAS on exact keys allowed for anyone (B must fetch the grant before being `is_known`).
  LIST allowed ONLY for `haven/invite/<acct>/` when peer == acct or a device in acct's signed
  roster (mirrors the `haven/self/**` owner rule) — A polls a narrow prefix; strangers can't
  enumerate.
- GC: honor the body's `expires` (the discovery lane's model) with the 30-day idle TTL as the
  outer bound.

### 3. Sealing — symmetric, from the ticket secret

Payloads are sealed with AEAD keyed by `HKDF(secret, "haven-invite-seal")`. The relay learns
nothing (it never sees the secret); post-quantum safe (symmetric); no new asymmetric machinery.
Caveat, accepted and documented: anyone who captured the LINK itself can read the drop — the
link was already the whole capability (same trust the current flow places in it). The link's
16-byte verify hash still tamper-checks A's full bundle after connection.

### 4. The async flow

1. A mints ticket → shares link/QR. May go offline forever after.
2. B accepts (offline OK: local contact add as today). When online, B seals
   {B's contact bundle, B's relays, B's device roster} and PUTs the acceptance drop to the
   ticket's bootstrap relays. ALSO fires today's live hello lanes — if A is online, nothing
   gets slower.
3. A, next online: mailbox pass LISTs `haven/invite/<own-acct>/`, opens drops against
   still-pending tickets, and surfaces the EXISTING approval UX (`addPending`) tagged
   ticket-verified — MAC possession means B is not a stranger cold-call, so the nearby-drop
   and stranger gauntlet don't apply. Undecided prompts persist the way held `__hello__`
   slots do today: the drop stays unclaimed until approve/dismiss.
4. A approves (B may be offline): writes the sealed grant — A's full bundle + relay announces +
   the circle grant (what hello + frame 19 deliver today) — to the SAME relays, plus
   `enrollMembers` so B passes `is_known` from now on. Normal live lanes fire too.
5. B, next online: polls the grant key (B knows A's relays from the ticket) → ingests → done.
   Ticket burns: A marks consumed at approve; B stops polling on grant or expiry.

Result: zero simultaneous-online requirement; each leg is store-and-forward with the existing
mailbox pollers doing the waiting.

### 5. What it deliberately does NOT change

- Relays stay blind stores and never become trust brokers (security mandate): they verify MACs
  and sizes, never identities or friendships.
- The live handshake path is untouched and still preferred when both are online.
- Desktop's divergences to fix while here (parity wave): its `pending`/`initiated` are
  in-memory only and its mailbox router marks hello keys seen unconditionally (no held-slot
  retry) — port Apple's semantics.

## Test plan (e2e)

New scenario `invite_offline` in `Scripts/qa-e2e-full.mjs`: stub (account B… roles as fits the
fleet) is KILLED before the iOS leg accepts a fresh ticket-bearing invite; assert the
acceptance drop lands on the relay; restart the inviter leg, assert the approval prompt appears
with no acceptor running; approve with the acceptor still down; boot the acceptor and assert
the friendship converges — full matrix with each side taking the offline role. Budgets:
`BUDGET.text` per leg after the respective restart.

## Implementation order

1. core: FriendTicket (enroll.rs sibling) + FFI; `blob_forbidden` invite lane + body
   verification + owner-scoped LIST; relay GC honoring `expires`.
2. Apple: ticket in ConnectView links/QR + PendingFriendInvites store + acceptance-drop write +
   invite-prefix poll in the mailbox pass + ticket-verified approval path + grant write/poll.
3. Desktop + Android: same wave (platform parity rule), including desktop's held-slot and
   persisted-pending fixes.
4. QA scenario + docs/LINK-SYSTEM.md update.
