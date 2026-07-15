# Moderation — decentralized reporting, blocking, and the ledger

Haven has no server, no owner accounts, and the developer holds no keys — so there is no central
moderator and can't be one (see [THREAT-MODEL.md](THREAT-MODEL.md)). Moderation power lives where
it always actually was: with the members of a circle. This document describes the mechanisms and
what the developer can and cannot see. Context: Apple App Review guideline 1.2 (user-generated
content) requires a filter, a flag mechanism, a block mechanism, and developer notification.

## The model

Circles have **no owner** — every member holds sovereign moderation power over their own view:

| Action | Scope | Mechanism |
|---|---|---|
| **Hide** | just me | `HiddenStore` — local, reversible, per-device |
| **Report** | whole circle | sealed `EventKind::Report` broadcast — see below |
| **Remove from circle** | my view of one circle | engine purge + epoch rotation + re-add tombstone |
| **Block** | everything, instantly | inbound gate drops posts/messages/calls/handshakes |
| **Sensitive filter** | whole circle | on-device SCA + federated `SensitiveFlag` blur |

## Reports

A report is a normal sealed circle event (`EventKind::Report { target, author, reason, comment }`):

- `target` — the reported event id; `author` — that event's author as **full node hex**, embedded
  by the reporter's core so members who never received the target can still act on its author.
- `reason` — one of five fixed categories; `comment` — free text, **sealed to the circle only**.
- The **reporter's** client hides the post instantly and offers block-in-the-same-motion.
- **Every other member** sees a banner on the post ("Reported by …" + category) with their own
  actions: hide for me, remove the author from the circle, block. Nobody moderates *for* you;
  the report is the circle's shared signal.
- Old clients fail to parse the unknown event kind and drop the single event — safe rollout.

## The ledger (developer notification)

**Blocking never leaves the device.** A block is a private, defensive act — you decide you don't
want to see someone — and it is a purely local inbound gate. Only an explicit **report** notifies
the developer, appending one **content-free** entry to a ledger on the push Worker (`POST /flag`,
KV prefix `ledger:`):

```
subject (node hex) × action (report) × reason (category)     — keyed by timestamp, TTL 90d
```

Node ids are opaque public keys — no names, no text, no media, no PII. The free-text comment never
reaches the ledger. This is the paper trail App Review 1.2 asks for, and it supports the only
enforcement the developer has: refusing the services he actually operates (e.g. push relay) to a
heavily-reported identity.

Three properties are deliberate, and the reasoning matters more than the row shape (audit F1):

- **Signed.** The reporter's core signs `subject|action|category|ts` with the identity key and the
  Worker verifies it against `actor` (a node id *is* an Ed25519 public key), with a 5-minute
  freshness window; the key is derived from the signed timestamp and the signature, so a replayed
  flag rewrites the same row instead of inflating a count. Unauthenticated writes are refused
  (`401`). Without this, anyone with `curl` could plant reports in your name.
- **No actor is stored — not even hashed.** The signature is checked and discarded. Node ids are
  enumerable (the Worker's own KV is full of them), so *any* deterministic function of the actor
  the Worker can compute is one the operator can invert; hashing would be theatre. Not storing it
  is the only way the developer genuinely does not hold a "who acted against whom" graph, which is
  what the standing mandate forbids.
- **Not permanent.** Entries expire after 90 days.

The honest limit: because identities are free to mint, a determined attacker can still sign N
reports from N throwaway keys. So a row means *"a holder of a valid Haven identity reported this
identity for this category"* — **not** "N distinct people". The ledger is a coarse signal, and the
developer does not claim otherwise. Signing raises the floor from "anyone can forge a record about
a named person" to "each row costs a real key", which is the property the Terms depend on.

List entries: `wrangler kv key list --binding TOKENS --prefix ledger:` (values are the JSON rows).

## Platform status

- **Apple (iOS + native macOS)** — shipped (report sheet, banner, signed ledger ping on report) —
  `apple/HavenApp/ReportUI.swift`.
- **Android** — shipped (`ui/ReportUI.kt` + `core/Moderation.kt`): report sheet with the same five
  categories, "Reported by …" banner with hide/remove/block, instant local hide via `HiddenStore`,
  and a signed ledger ping on report.
- **Desktop (Tauri)** — shipped (`report`/`reports` commands + `reportDialog`/`reportedBanner` in
  `ui/app.js`). **Its ledger ping (`Engine::moderation_flag`) is not yet signed, so the Worker
  refuses it (401); its block ping is refused as a bad action.** Desktop moderation itself — the
  sealed circle-wide report, the banner, hide/remove/block — is unaffected, since none of it goes
  through the Worker. Signing it is the outstanding half of audit F1.

The category wording is identical on every platform so ledger entries aggregate cleanly.
