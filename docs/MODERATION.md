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

Reporting or blocking appends one **content-free** entry to a permanent ledger on the push Worker
(`POST /flag`, KV prefix `ledger:`):

```
actor (node hex) × subject (node hex) × action (report|block) × reason (category)
```

Node ids are opaque public keys — no names, no text, no media, no PII. The developer cannot read
any content (E2E), but the ledger makes **patterns** visible: many distinct reporters against one
identity is signal enough for the only enforcement the developer has (e.g. refusing push-relay
service), and it is the paper trail App Review 1.2 asks for. The free-text comment never reaches
the ledger. Entries are permanent by design — the action lives on.

List entries: `wrangler kv key list --binding TOKENS --prefix ledger:` (values are the JSON rows).

## Platform status

- **Apple (iOS + native macOS)** — shipped (report sheet, banner, ledger pings).
- **Android / desktop** — core event is platform-neutral; UI pending (see
  [ANDROID-PARITY.md](ANDROID-PARITY.md)). Android's existing `HiddenStore`/block still apply;
  unknown `Report` events are dropped harmlessly until the UI lands.
