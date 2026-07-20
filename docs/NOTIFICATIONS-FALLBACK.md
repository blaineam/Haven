# Notifications without a mandatory push relay

**Status:** endpoint configurability **implemented on Apple**. Android, desktop, and the UX honesty
work are **staged**. This document is the design and the honest statement of limits.

**Why this exists.** `docs/NOTIFICATIONS.md` describes the shipped design: a blind Cloudflare Worker
that forwards sealed payloads to APNs. It is a good design — the relay only ever moves ciphertext.
But it is a **single point of failure attached to one person's Cloudflare account**, and its URL is a
compile-time constant in three languages:

| File:line | Language |
|---|---|
| `apple/HavenApp/PushManager.swift:22` (before this branch) | Swift |
| `android/…/core/Moderation.kt:28` | Kotlin |
| `desktop/src-tauri/src/engine.rs:30` | Rust |

If that Worker stops — bill unpaid, account closed, the operator dies — every installed copy of
Haven keeps trying to POST to a dead host forever, and there is no way to redirect them without
shipping three app updates through three stores.

The requirement is therefore two things, in this order:

1. **Push must be optional.** Haven must remain a working messenger with no push relay at all.
2. **The endpoint must be re-pointable in the field**, without an app update.

---

## 1. What iOS actually grants (read this before promising anything)

This section exists because it is easy to design a fallback that iOS will not honour.

| Mechanism | Wakes a killed app? | Reliable? | Reality |
|---|---|---|---|
| APNs alert/VoIP push | **Yes** | Yes | The only mechanism that does. Requires a server holding the APNs key. |
| `BGAppRefreshTask` | Yes | **No** | iOS decides. Budgeted on usage, battery, Low Power Mode. For a rarely-opened app it may run **never**. Minimum `earliestBeginDate` is a request, not a schedule. |
| `BGProcessingTask` | Yes | **No** | Typically charging + idle. Good for maintenance, useless for messaging latency. |
| Silent `content-available` push | Yes | No | Still needs APNs, and is heavily throttled. Not a fallback — it is the same dependency. |
| Foreground / launch sync | N/A | **Yes** | Runs whenever the user opens the app. This is the assured path. |
| Notification Service Extension | — | — | Only runs when a push already arrived. Decrypts; cannot fetch. |

**The honest conclusion for iOS: with no push relay, notification delivery is "when the user next
opens the app", plus whatever `BGAppRefresh` opportunistically grants.** There is no way around it.
Anyone who claims otherwise is describing something Apple will not honour.

Messages themselves are **not lost** — they sit in the relay mailbox and sync on next foreground.
What is lost is *timeliness*, and only that. Saying this clearly is the difference between a
degraded mode and a broken one.

**Recorded trap:** a background *launch* never fires a `scenePhase` `onChange`
(`apple/HavenApp/AudioCoordinator.swift:392`). Polling must be driven from the BG task handler and
from launch directly, never gated on a scenePhase transition.

### Other platforms

| Platform | Without a push relay |
|---|---|
| **Android** | Genuinely good. A foreground service or `WorkManager` periodic job can poll the mailbox on a real schedule. Android does not require a Google/FCM round trip for this. |
| **macOS / Windows / Linux desktop** | Best case. The app is a long-running process holding a live iroh connection; it already gets messages in real time with no push involved. |
| **watchOS** | Mirrors the paired phone. No independent story. |

So the push relay is, strictly speaking, an **iOS-only** dependency. That reframing matters: losing
it degrades one platform, not the product.

---

## 2. Design

### 2.1 Three tiers, always all three

```
  tier 1  APNs push            fast, optional, needs a relay + the APNs key
  tier 2  scheduled polling    Android: reliable. iOS: best-effort BGAppRefresh.
  tier 3  foreground sync      always, on every platform. The assured floor.
```

Tier 3 already exists and works (`NotificationManager.handleRefresh` →
`BackgroundUploader.flush()` + `FeedStore.forceSync()`, `apple/HavenApp/NotificationManager.swift`).
Tier 2 exists on iOS as `BGAppRefreshTask` (registered at
`apple/HavenApp/NotificationManager.swift:67`). Tier 1 exists.

**Nothing new needs to be built for the mechanism.** What was missing is that tier 1 was
*mandatory* — unconfigurable and un-disableable — and that the UI implies push-speed delivery
unconditionally.

### 2.2 Configurable transport (implemented on Apple)

`PushManager.relay` is now an override with the current Worker as the default:

* `PushManager.setRelay("https://successor.example")` → point at a different relay.
* `PushManager.setRelay("")` → **push off**; polling only. `pushEnabled` is false and every POST is
  a no-op.
* `PushManager.setRelay(nil)` → restore the default.

Backed by `UserDefaults` key `HavenPushRelayURL`. Read with `object(forKey:)` rather than
`string(forKey:)` **on purpose**, so an explicit empty string ("disable") is distinguishable from
"never configured" — this is the same absence-vs-explicit-value discipline the discovery `RelayBook`
uses, for the same reason.

`ModerationLedger.report` (`apple/HavenApp/ReportUI.swift`) rides the same worker and now honours
the same switch.

### 2.3 How a successor re-points an installed app

In preference order — the first is the one that matters:

1. **Sealed circle state.** A relay announce already travels sealed inside circle state (frame 19).
   A push-relay URL should travel the same way, so an operator can redirect everyone who is still
   talking to anyone. **Staged.**
2. **Discovery / relay book.** Once `RelayBook` (see `docs/DECENTRALIZED-DISCOVERY.md`) syncs, the
   push endpoint is one more field on a relay entry, carried with the same presence + generation
   LWW semantics.
3. **Settings UI.** Manual paste. **Staged** — the plumbing exists, the screen does not.
4. **A well-known URL under a domain the project controls.** Rejected: it just moves the single
   point of failure from Cloudflare to DNS, and DNS is *harder* to inherit than a Worker.

### 2.4 UX honesty (staged, and the part most likely to be skipped)

When `pushEnabled` is false, the app must say so where the user will see it, in plain words:

> Push notifications are off. Haven will check for new messages when you open it, and occasionally
> in the background when iOS allows. Nothing is lost — messages wait for you.

Not a warning triangle, not "degraded mode". It is a legitimate configuration — arguably the more
private one, since no server learns when you are being messaged.

Conversely, when push **is** on, nothing changes. Today's behavior is today's default.

---

## 3. Successor runbook: standing up a new push relay

The Worker source is in `push/worker.js` and is ~300 lines with no dependencies. A successor needs:

1. A Cloudflare account (free tier is sufficient at circle scale) and `wrangler`.
2. **An APNs `.p8` auth key** — this is the piece that **cannot be inherited from source**. It comes
   from an Apple Developer account, and it must be the account that owns the app's bundle id. A
   successor shipping under their **own** developer account mints their **own** key; they do not
   need the original.
3. `wrangler secret put APNS_KEY` (+ `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`), then
   `wrangler deploy`. Config shape is in `push/wrangler.toml`.
4. Point clients at it (§2.3).

Note the important consequence: **because a successor must re-sign under their own developer account
anyway (see `docs/SUCCESSION.md`), they will necessarily have their own APNs key.** The push relay is
therefore *not* an inheritance problem — it is a redeployment problem, and it is a small one. The
inheritance problem is the ~300 lines of `worker.js` and the knowledge of what to set, which is why
this section exists.

---

## 4. What was implemented vs. staged

### Implemented

* `PushManager.relay` is a runtime override with `defaultRelay` as fallback
  (`apple/HavenApp/PushManager.swift`).
* `PushManager.pushEnabled` + `setRelay(_:)`.
* `post()` and `ModerationLedger.report` no-op when push is disabled.

### Staged

* Android (`Moderation.kt:28`) and desktop (`engine.rs:30`) equivalents.
* Carrying the push URL in sealed circle state / `RelayBook`.
* The settings screen and the honesty copy in §2.4.
* Android `WorkManager` periodic mailbox poll — the one platform where a genuinely reliable
  push-free path is available and is currently unbuilt.

### Unproven

* **The Apple change is parse-verified only**, not built into the app. A full `xcodebuild` requires
  the multi-arch Rust XCFramework, which this branch does not touch and did not rebuild.
* Nobody has run Haven with `relay = ""` end-to-end. The claim that everything degrades cleanly to
  polling is read off the code paths, not observed.
* No measurement of what `BGAppRefresh` actually delivers in practice for this app. The iOS table in
  §1 is Apple's documented behavior, not this app's measured behavior.
