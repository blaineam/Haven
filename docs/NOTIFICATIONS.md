# Notifications: reliable, safe, and as decentralized as iOS allows

## Why background fetch doesn't work (and never really will)

`BGAppRefreshTask` is **best-effort and iOS-controlled** — the system decides if/when to run
it based on usage, battery, and Low Power Mode, and for many users it runs rarely or never.
There is no way to make it reliable. The **only** mechanism that reliably wakes a killed iOS
app is **APNs push**. So reliable notifications require *some* server that can send a push.

## The design: a "blind" push relay (zero-knowledge content)

We can keep it safe and minimal even though a server is involved — the same model Signal/
WhatsApp use:

1. Each device registers its **APNs device token** ↔ its **Haven node id** (pseudonymous)
   with a tiny relay. No name, email, or content — just `token ↔ nodeId`.
2. When a message/post is authored for an offline recipient, the **sender (or the mailbox)**
   asks the relay: *"wake node Z with this sealed blob."*
3. The relay sends an APNs push with `mutable-content: 1` and the **encrypted** blob.
4. The recipient's **Notification Service Extension (NSE)** decrypts it on-device and writes
   the real notification text. The relay only ever moves **ciphertext**.

The relay sees: device tokens, timing, and recipient node ids (metadata) — **never content**.
That's the honest limit: iOS push *cannot* be fully decentralized (Apple is the gatekeeper;
only the holder of the app's APNs key can send). But content stays E2E, and **we** run the
relay, not a third-party SDK like OneSignal.

## Hosting: cheapest + scales instantly → **Cloudflare Workers**

APNs itself is **free** (Apple doesn't charge per push). The only cost is the thing that
*sends* the push. Ranked for "cheap + scales easily and quickly":

| Option | Cost | Scale | Notes |
|---|---|---|---|
| **Cloudflare Workers** ✅ | **Free** to 100k req/day; **$5/mo** = 10M req | Instant, global edge, zero servers | Mint the APNs **ES256 JWT** with WebCrypto from the `.p8` key; `fetch()` to `api.push.apple.com` over HTTP/2. Store `token↔nodeId` in **Workers KV** (free tier) or **D1**. |
| Fly.io / Render / Railway | ~$0–5/mo tiny container | Manual-ish | A small Node/Rust service; simplest mental model, but you manage a process. |
| AWS Lambda + API GW + DynamoDB | pay-per-call, ~free at low vol | Auto | More moving parts + cold starts. |
| A $5 VPS | $5/mo | You scale it | Simplest to write, doesn't auto-scale. |

**Recommendation: Cloudflare Workers.** A circle-scale app fits the **free tier**; if it ever
grows, **$5/mo handles 10M pushes**. No server to babysit, global, scales automatically. Use
**token auth** (one `.p8` AuthKey works for all your apps; JWT valid ~1h, cache it in the
Worker).

### Worker shape (sketch)
- `POST /register { nodeId, token, env }` → KV `put(nodeId, {token,env})`
- `POST /notify  { nodeId, ciphertext }` → look up token → sign JWT (ES256, `.p8`) → `fetch`
  `https://api.push.apple.com/3/device/<token>` with `apns-push-type: alert`,
  `apns-topic: com.blaineam.kith`, body `{ aps:{ "mutable-content":1, alert:{...stub...} }, e:<ciphertext> }`
- Rotate/cache the JWT; nothing is logged.

## App side (the work in Haven)
1. ✅ **Notification Service Extension** (`HavenNotificationService`) — decrypts the relay's `e`
   field on-device and rewrites the banner. It needs nothing but our master seed: a new
   seed-only FFI `open_sealed_with_seed(seed, sealed)` opens the blob with no engine/circle
   state or disk access, so it works in the extension's own process even on the lock screen.
   The seed reaches the extension through a **shared Keychain access group**
   (`…kith.shared`): `AccountStore` keeps the authoritative item exactly where it always was
   (no migration / identity-loss risk) and *additionally* mirrors a read-only copy into the
   shared group (`SharedSeed`). Accessibility is `AfterFirstUnlockThisDeviceOnly`.
2. ✅ **Register for remote notifications**, send `deviceToken ↔ myNodeId` to the Worker
   `/register` (`PushManager`).
3. ✅ **On send to an offline peer**, the sender seals a tiny `{t,b}` banner *per recipient*
   (`HavenSocial.seal_media`) and calls `/notify` with its base64 — the relay forwards
   ciphertext only (`FeedView.broadcastEvent`).
4. ✅ Worker now sends an **alert** push with `mutable-content: 1` (was a throttled silent
   `content-available` wake). No `content-available`, so the app isn't also woken to post a
   duplicate local banner. A generic `alert` stub is the fallback when the NSE can't decrypt.
5. Local notifications + the (crash-fixed) background refresh remain as a fallback.

### Background refresh is a net, not a lane (1.4.7)

Because APNs is the delivery path, `BGAppRefreshTask` is scheduled **only when there is work we
already know is unfinished** — authored envelopes still queued for a mailbox, media still owed to a
relay, or a mailbox backlog mid-drain — and the next wake is chained after a pass completes, based
on what is still owed, rather than booked up front. With nothing outstanding, exactly one wake is
scheduled for a **6-hourly safety-net sweep** (in case a push was ever dropped: APNs is best-effort
and the Worker drops oversized bodies).

A wake with no backlog and no sweep due flushes what it owes and ends **without listing any
mailbox**; push *hints* are still fetched on every wake, since those are targeted single-key GETs.
Before this, a refresh was chained unconditionally from every background entry and from the end of
every refresh, so each granted window ran a full LIST across every circle and then booked the next
one — a self-sustaining wake treadmill on an idle phone, and the bulk of Haven's "Background
Activity" time. See `NotificationManager.scheduleRefresh`.

### Sealed banner wire format
The relay's `e` = base64 of the signed notification envelope (see `seal_signed_notification`).
Plaintext is JSON built by `PushBanner` on the **sender** (the NSE has the seed alone and
cannot open circle events, so every bit of richness has to ride here):

```json
{ "t": "<sender display name>",
  "b": "<human body line>",
  "c": "<circleId>",
  "k": "post|story|dm|react|comment|edit|unsend|…",
  "e": "<emoji>" }
```

Examples of `b` / `bp`:
- DM text: `b` = `"on my way"` (clipped); `bp` = `"Sent you a message"`
- Reaction: `b` = `"Reacted ❤️ to your post"`; `bp` = `"Reacted to your post"` (no emoji)
- Story: `b` = `"Shared a story in Family"`; `bp` = `"Shared a story"`
- Comment: `b` quotes text; `bp` = `"Left a comment"`
- Secret DM: `b` = `"🔒 Secret message"` (never the plaintext)

Older clients that only read `t`/`b`/`c` keep working; unknown keys are ignored. The NSE
sets `threadIdentifier` from `c` so a burst of DMs stacks as one conversation.

### Lock-screen privacy (recipient chooses)

The **sender always seals both** `b` and `bp`. The **recipient's NSE** picks which to show:

1. **iOS Show Previews** (Settings → Notifications → Show Previews)
   - `Never` → minimal (`Haven` / `New activity`)
   - `When Unlocked` → private body (name + kind, no message text) — NSE cannot reliably
     detect lock state, so we never paint quoted content under this system setting
   - `Always` → full body, unless Haven preference is stricter
2. **Haven → Settings → Lock screen → Notification previews**
   - Full previews / Name and type only / Minimal
   - Stored in the App Group so the NSE reads it without launching the app
   - Can only **tighten** past the system setting, never loosen it

Biometric-locked circles still force full redaction regardless.

### Still device/pipeline-only
APNs and the NSE don't run in the iOS Simulator, so live decryption is verified on a physical
device. The new `com.blaineam.kith.NotificationService` App ID needs its own provisioning
profile in the signing pipeline (the keychain-sharing group is same-team-prefix, so no extra
ASC capability). Both targets carry `keychain-access-groups` with `…kith.shared`.

## Decision status
**#51 — shipped (app side).** Self-run Cloudflare Worker + NSE, encrypted payloads. Cost ≈ $0
to start, $5/mo at real scale. Not fully decentralized (impossible on iOS), but zero-knowledge
on content and operated by us, not a vendor.
