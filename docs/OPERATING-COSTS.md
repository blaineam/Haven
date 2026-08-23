# Operating costs — $0 to the operator

**Design goal: nothing the operator runs is required, and the operator pays nothing
monthly.** The user's own storage and free/community infrastructure carry everything.
This supersedes the earlier quota'd-bucket model (see DECISIONS D15).

## Who pays for what

| Piece | How | Cost to operator |
|---|---|---|
| Discovery (find a peer by key) | mainline DHT (decentralized) | **$0** |
| NAT hole-punching (~80% of links) | public STUN | **$0** |
| Connection relay (~15–20% hard-NAT + calls) | iroh/n0 free relays + community-run relays | **$0** (best-effort, see trade-off) |
| Storage / offline delivery / large files | **a Haven relay mailbox** (user/community-run relay's own disk) or the user's **own S3-compatible bucket** (S3/R2/B2/MinIO) | **$0** (funded by the user's own storage) |
| Invite-landing page + AASA + marketing page | **GitHub Pages** (`blaineam.github.io`) | **$0** |
| "You got media" notifications | APNs / Web Push | **$0** |

**Result: the app is free — no subscription, no in-app purchases, no ads — with no
monthly operator cost, ever.** Development is funded directly by the people who want it
to exist ([GitHub Sponsors](https://github.com/sponsors/blaineam), [Ko-fi](https://ko-fi.com/wemiller),
[wemiller.com/support](https://wemiller.com/support/)); nothing in the architecture bills
the maker per user, so nothing needs to bill the user. _(Haven was a one-time $9.99 purchase
until August 2026.)_

## Why storage is free to the operator

- Sealed blobs park on a **Haven relay's local disk** — the in-app relay any official
  client can host, or the standalone `haven-relay` daemon — run by the user or a
  community volunteer, not the operator.
- Power users can **BYO** any **S3-compatible bucket** (AWS S3, Cloudflare R2,
  Backblaze B2, MinIO) — billed to **the user's** own account, never the operator's.
- Either way the storage is the *user's own* — there is no operator-funded bucket.

## The honest trade-off (dependency, not dollars)

1. **Connection relay leans on iroh/n0's free public relays** — production-grade but
   goodwill, not an SLA. If it degrades, hard-NAT connections and live calls suffer
   until community relays fill in. *Mitigation:* the optional `haven-relay` deploy tool
   lets anyone (incl. the operator, later) run a relay for reliability — **never
   required, never a mandatory monthly bill**.
2. **Offline delivery needs a reachable mailbox.** If neither peer is online, delivery
   falls back to a **Haven relay mailbox** or the sender's **own S3-compatible bucket**;
   with both peers online it goes direct (or via connection-relay). Cross-platform works
   the same way — any client can read a relay mailbox or a BYO bucket.

## What this model deletes

Removing any operator-funded storage removes all the machinery that existed only to
meter it: the 512MB quota, blind-signed tokens, App Attest gating, the storage
subscription, and the funded default bucket. Simpler product, cleaner story.

## Optional: paid reliability, if ever wanted

If the operator ever wants guaranteed relay reliability, a single ~$5/mo VPS running
`haven-relay` (or a Cloudflare R2 storage relay) is available — but it is strictly
optional and the app is fully functional without it.
