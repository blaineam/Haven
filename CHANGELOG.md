# Changelog

All notable changes to Haven are recorded here. Haven is in **alpha**; entries are grouped
by dated waves (a batch of work committed together and rolled into the next build). See
[`PROGRESS.md`](PROGRESS.md) for the live build/shipping status and
[`docs/ROADMAP.md`](docs/ROADMAP.md) for milestones.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## 1.8.2 — 2026-09-01

### Fixed — the foreground freeze finally has names (and so does the 2 AM watchdog kill)

Field report: Haven locked up for a few seconds right after launch or foregrounding, then ran
silky. A DEBUG-only main-thread stall detector (ported from Ari; it probes the main queue and
appends a symbolicated main-thread stack to `Library/Caches/HavenStalls.log` whenever a probe
misses by 0.4 s, pullable with `devicectl device copy`) made every freeze name itself. Five parks,
all inside the sync burst a foreground kicks off, each caught on a real account:

- **The mailbox drain is sliced.** One monolithic EngineGate pass re-acquired the barging engine
  mutex back-to-back for the whole backlog, so any main-thread `social.*` touch parked for the entire
  drain. Now 6 envelopes per hold with 3 ms of air between slices — a parked main thread wins the
  lock within a slice.
- **The upload queue is off cfprefsd.** `BackgroundUploader` persisted its queue (full sealed
  envelopes) into UserDefaults on the main actor per enqueue/flush — a synchronous cfprefsd XPC
  round-trip caught blocking main 0.65 s on launch's first enqueue. The queue now lives in an
  Application Support file written by a serialized background actor (debounced 100 ms), with a
  one-time migration off the legacy prefs blob.
- **SelfSync roster ingest runs off-main.** `applyLocal`'s roster loop drained pending epoch events
  on the main actor, and every drained event re-verified device credentials — cloning ML-DSA-65
  verifying keys per contact device: 1.4–1.9 s blocked per foreground sync. The loop now hops to a
  utility task inside EngineGate like every other engine mutation.
- **The relay LIST-delta parse runs off-main.** Tens of thousands of newline-split keys were split
  on the main actor (0.5 s caught). Detached utility parse, zero isolation ripple.
- **Contact device hints decode once.** The last capture — repeated 0.40–0.50 s blocks on every
  iroh send: `FeedStore.contactDeviceHints` re-read the invite-hint dictionary out of UserDefaults
  and conditionally bridged the whole thing to `[String: [String]]` on the main actor per
  `sendIroh`. It, and the per-DM "cleared before" watermark that sat on the chat-body paint path,
  now decode once into a typed mirror the single writer keeps in step: each lookup is a native O(1)
  dictionary read.

The same parks were the 2 AM background scene-create watchdog kill (0x8BADF00D): the system created
the scene to drain an overnight push, the main thread parked behind that same drain, and it crossed
the 30 s watchdog. One root cause, two symptoms.

## 1.8.1 — 2026-08-29

### Fixed — a smooth feed that no longer cooks the phone

The feed had gone choppy and the phone ran hot browsing media *already* on the device — worst
since the Instagram import landed. Two independent causes, both about feed-sized bytes:

- **iOS feed thumbnails now persist to disk.** `MediaStore.thumbnailAsync` re-decoded the
  multi-MB source on every scroll-back once the 48 MB in-memory cache churned. The decode is
  off-main, but the sustained CPU saturated and thermal-throttled the phone into dropped frames —
  the choppiness *and* the heat-on-open with nothing to sync. Each ref now decodes to a feed
  thumbnail once and persists it as a small JPEG in Caches; re-scrolls reload the tiny file.
  Content-addressed refs never need invalidation, and Caches stays evictable under pressure.
- **The Instagram import's raw fallback no longer seals full-res originals.** When the webview is
  closed or refuses a file, the importer sealed the archive original untouched — a multi-megapixel
  still that then synced to every phone. It now re-encodes in Rust to the composer's own feed
  target (1600px / JPEG q62, mirroring `ui/app.js` `STILL_LONG_EDGE`) and mints the matching
  ≤32 KB `thumb:` companion. Undecodable bytes (e.g. HEIC) seal the original as before.
- **A scroll no longer re-renders every visible card.** Each `PostCard` observed the audio
  coordinator solely to compute "am I the centred post?" — a signal that changes as each post
  crosses centre while you swipe (~once every couple of seconds). That re-evaluated every visible
  card's ~1,500-line body, dropping the frame (the swipe felt like it "stuck") and adding heat. The
  check moved down to `PostMediaView`, the media leaf that already observes that signal to start and
  stop its player, so a scroll now re-renders only the two cards whose centred-state actually flips.
- **Presence updates no longer re-diff the feed on every packet.** `FeedStore` republished on every
  received packet — each one refreshed a peer's "last heard" timestamp — and the feed observes the
  whole store, so ordinary traffic periodically re-diffed the list mid-scroll (the occasional
  remaining stick). The timestamp now refreshes at most once every 2s per peer, well inside the 120s
  window both recency consumers use, which collapses that publish churn.

### Fixed — network path churn no longer spins up a rebind storm

The 1.8.0 delivery-recovery work rebinds the transport when the network path changes; on some
devices the path signature flapped, firing rebinds in a tight loop that itself heated the phone.
The path signature now keys off the primary interface class only (wifi/wired/cell/other), and
rebinds are rate-limited to once per 60s.

### Changed — offline invite links are yours to control

Offline friend-invite links gained a configurable lifetime — 7 days, 30, 90, a year, or never —
and a one-tap regenerate that retires the live ticket and mints a fresh link. Persisted per
device; "never" links stay live until you roll them.

## 1.8.0 — 2026-08-28

### Added — add friends without being online together

Offline friend invites (`docs/OFFLINE-FRIEND-INVITES.md`): invite links now carry a one-time
ticket (secret + the inviter's relays + dial hints), and both halves of the first-contact
handshake become sealed blobs parked under unguessable token-derived keys on the inviter's
relays. Accept while the inviter's app is closed; they get the normal approval prompt next
launch; approve while the acceptor is offline; the acceptor completes from the parked grant
alone. The relay lane sits above the membership gate (the token path IS the write capability),
bodies are structurally verified on both transports, everything is sealed + MAC'd from the
ticket secret — relays stay blind. Live handshakes still run first and win when both are online.
All four platforms; e2e `invite_offline` kills the inviter mid-handshake and proves the async
path (drop lands 2.5s with the inviter dead; completion in ~6s per side after relaunch).

### Fixed — authored content no longer waits for an app relaunch to reach anyone

Field report: posts and reactions/comments authored on a device sometimes reached nobody until
the AUTHOR closed and relaunched Haven. Root cause was structural: every authored event got
exactly one best-effort attempt on each delivery lane and no per-event retry — all recovery was
bulk re-asserts that a relaunch (and little else) re-arms. Five fixes, all platforms where they
apply:

- **Apple mailbox outbox actually retries.** `BackgroundUploader` had two wedges: an event
  enqueued while a flush was in flight was kept but NOTHING was scheduled to send it (every
  reaction burst hit this), and a failed upload had no retry timer at all — both waited for the
  next launch/scene-phase/BGRefresh. Every pass now re-arms itself: immediately for work that
  arrived mid-pass, capped exponential backoff (3s→2min) for failures.
- **Network path changes now recover the transport instead of wedging it.** Wi-Fi↔cellular, VPN
  toggles, sleep/wake and router reboots kill every socket under the iroh endpoint while leaving
  the DERP set — the only thing that used to trigger a rebind — unchanged; relay/blob backoffs
  (up to 30 min) had all grown against the dead path. A real path transition now resets the
  backoff state and forces the same transport rebind + re-announce + re-sync an app relaunch
  performs. (Apple; desktop/Android port next wave.)
- **Asymmetric black-hole detection in core (all platforms).** On a path where inbound
  keep-alives arrive but outbound vanishes, QUIC's idle timeout never fires and `send()`
  "succeeded" into local buffers forever. `send` now watches `stopped()` — the transport-level
  delivery ack — and evicts the cached connection after 20s without one, so the next send
  re-dials. The blob/mailbox client likewise drops its cached connection after a failed put/get
  instead of feeding every retry to the same doomed connection.
- **Desktop authored-event uploads retry until they land.** `upload_event` now reports whether
  the envelope reached ANY durable mailbox, and the author path retries with backoff (~10 min
  worst case) instead of stranding the event until the next launch's daily backfill.
- **Desktop interaction commands no longer vanish on an empty circle id.** `comment`/`react`/
  `unreact` now get the same DEFAULT_CIRCLE normalization as `post` (an empty id made the core
  return an error the engine silently swallowed). Apple comments with media also gain the same
  preview/thumb markers + relay blob backup as posts (a photo reply's bytes were never queued).

QA: the e2e `react`/`comment` steps now author from EVERY leg (iOS/Android were never reaction
authors — a broken send path there was invisible) and converge in parallel.

### Changed
- **Haven is free.** The $9.99 one-time price is gone on the App Store (set via
  `rocket price Haven`), and the website, README, App Store promotional text (en-US + 8
  locales) and docs now say so: no ads, no tracking, no subscription, no in-app purchases.
  Development is funded directly — the site's pricing card became a **Support future
  development** block linking GitHub Sponsors (`github.com/sponsors/blaineam`), Ko-fi
  (`ko-fi.com/wemiller`) and `wemiller.com/support`. Google Play and the Microsoft Store
  prices were switched to Free in their consoles on 2026-08-23 (Play's is one-way); see
  `docs/STORE-AUTOPUBLISH.md`.
- **Store policy is data.** `appstore-metadata.md` gained `## availability` (`exclude: france,
  china`) and `## price` (`free`) sections that `rocket territories` / `rocket price` /
  `rocket compliance` audit and apply. France (ANSSI crypto filing) and China (ICP filing)
  stay excluded; the EU stays **on** — a free app with no IAP needs no DSA trader
  declaration. `docs/EXPORT-COMPLIANCE.md` rewritten to match the exempt
  `ITSAppUsesNonExemptEncryption = NO` answer the binary has carried since 1.0.

### Added
- **Settings → "Support Future Development"** (MillerKit 1.2.0): a heart row in the
  *Enjoying Haven?* block that opens wemiller.com/support — the page listing GitHub
  Sponsors, Ko-fi and a one-time tip. Only the free, donation-funded apps carry it.
- **App Store submission from CI** (`.github/workflows/apple-store.yml` +
  `Scripts/asc-autosubmit.mjs`). A plain `vX.Y.Z` tag now submits iOS + macOS for review from
  the **Xcode Cloud build of that exact commit** — it finds the XCC run by source commit
  (starting one on the tag if auto-cancel ate it), waits for both uploads to go VALID,
  creates the App Store version, sets What's New on every localization from
  `appstore-metadata*.md`, attaches the build, answers export compliance if asked, and opens +
  submits the review submission. Gated on `ASC_API_KEY_ID` / `ASC_API_ISSUER_ID` /
  `ASC_API_KEY_P8` (skips with a notice until set); `APPLE_STORE_SUBMIT=false` stages without
  pressing submit. The notes gate refuses to ship a `whats_new` that doesn't start with the
  version, and a locale still on an older version gets the English notes with a warning.
  `-rc.N` tags do nothing on Apple, as before.
- **Google Play release notes ship in every locale.** `android.yml` used to copy only
  `en-US/changelogs/default.txt`; it now builds `whatsnew-<locale>` for all nine locale dirs
  (which had drifted — de-DE sat at 1.3.1, zh-CN at 1.4.0) and counts the 500-character cap in
  Python instead of `wc -m`, which counts bytes under a non-UTF-8 locale. All nine files carry
  the 1.6.1 note (free + stability wave), each under 500 characters.
- **Microsoft Store publish is back**, opt-in: with the repo variable `MSSTORE_PUBLISH=true`
  (set 2026-08-23, after the Partner Center price went Free) `release.yml` runs `msstore
  publish` on a `vX.Y.Z` tag — free products are the case Microsoft supports over Actions. Not
  `continue-on-error`: a Store failure goes red instead of the old false-green.

## 2026-08-23 — 1.7.0 (the calls-you-can-trust wave)

Gate: the full matrixed suite green — six caller×answerer call pairs across every
platform direction, content authored from every platform, real-click UI assertions,
unanswered-death scenarios, and the satellite tier — in one run.

### The call protocol, settled
- **Transport events never answer calls.** Media connecting is recorded (truthful
  "Connecting media…"/Connected states) but `in-call` moves ONLY on an explicit accept —
  on every platform. This ends the whole family at once: callees that silently
  self-answered under their own ring screen (accept then no-op'd forever), callers that
  showed Connected before anyone answered, and callers stuck on "Calling…" over live audio.
- **Accepts can no longer get lost.** The ACCEPT frame was sent once, link-cold; a missed
  one deadlocked the call. Answerers now re-send it whenever the caller's own invite
  retransmit arrives — the retry loop already in the protocol becomes the delivery
  guarantee, and it stops the moment one lands.
- **Stale accepts can no longer connect the wrong call**: session ids are validated on
  every platform (Apple checked the sender but never the session — a relay-replayed
  accept from a finished call connected a fresh unanswered one, killed the caller's
  retransmits, and rang the victim forever).
- **Unanswered calls die** — 60s dial bound on callers everywhere (desktop had none),
  ring bounds on callees, and both proven by suite scenario.

### QA (the reason the above is trusted)
- **Caller × answerer matrix**: {iOS, Android, desktop} → stub and stub → each, asserting
  ring, early-media survival, accept-clears, caller-live-on-accept, sibling stand-down,
  and ended-everywhere per pair. Android could previously neither place nor answer a call
  under test.
- **Content author matrix**: Android and desktop author posts (text + photo, blob-checked)
  and DMs; every other leg must receive and every sibling must echo.
- Desktop real-click assertions (computed visibility) for minimize / Call-tab / hangup.

## Superseded pre-release notes (1.6.2) — desktop calls actually usable

Found by hand-testing desktop↔stub calls minutes after 1.6.1 shipped; every fix is now
locked in by a new suite lane that places the call FROM desktop and clicks the real buttons.

### Fixed
- **Every call-screen button looked dead** (minimize, the Call tab, hang up). One selector:
  the "no call → clear" branch matched the old `.call-overlay` class, not the rebuilt
  `.call-screen` — when call state dropped, the screen stayed as a ZOMBIE whose buttons
  correctly mutated state and then re-rendered into a clear branch that found nothing to clear.
- **Callers stuck on "Calling…" while audio already flowed — then killed at 60s.** The
  answerer's ACCEPT (frame 11) is sent exactly once, link-cold, and can vanish (frame-level
  logging proved it never arrives from an Apple answerer to a desktop caller); the caller UI
  waited for it forever and the new dial bound then hung up a LIVE call. A caller now
  promotes to in-call the moment a peer connection actually connects — media IS the call.
  (Apple-side 11 retry: backlog.)
- **The mesh no longer waits on the mic prompt.** getUserMedia can block indefinitely;
  signalling now proceeds after 6s with audio+video transceivers (same m-line shape), and
  tracks replace in live when acquisition completes. Hang-up is local-FIRST: teardown runs
  before the network invoke, so no rejected call can seal the user inside a dead screen.
- **Faces, finally**: a caller's own devices resolve to your profile (emoji/photo), and a
  one-shot boot backfill hellos every appearance-less contact so the card desktop dropped
  for its whole life finally lands — initials only remain for peers not seen since.

### QA
- New suite lane: desktop PLACES the call, stub answers, caller must go LIVE, then REAL DOM
  clicks (minimize → Call tab → restore → hang up) asserted on computed visibility. The
  engine logs every call frame (the single-slot last-event diagnostic was overwritten by the
  ICE flood in seconds, which is why the missing ACCEPT was undiagnosable).

## 2026-08-22 — 1.6.1 (stability wave: the fork is dead)

Two full QA gauntlets green back-to-back (91/91 twice, zero forks) — the first releases
where the recurring MLS "welcome-election fork" cannot recur by construction.

### Fixed
- **iOS launch crash (watchdog 0x8BADF00D, TestFlight build 536).** Scene-create ran a
  synchronous keychain write (`SecItemAdd` → securityd XPC) inside a `@StateObject` init;
  on a cold unlock that blocked past the watchdog budget and the OS killed the app at
  launch. Steady-state startup now performs **zero** keychain writes; the one legacy-seed
  migration that needed one waits for `protectedDataDidBecomeAvailable` on a utility queue.
- **The welcome-election fork (root cause).** Every device of a circle-creator account
  validly authors a competing genesis (multi-master), and the keying election picked by
  (adds, hash) without asking which genesis the commit CHAIN had actually grown on. When
  the grown branch lost, every member's replay found no child of the winner and froze one
  epoch behind, while any device holding a direct Welcome onto the grown branch sailed
  past — one device sealing at epoch N+1, the rest at N, unreadable in both directions.
  The election now prefers **chain height, then adds, then hash** — deterministic from
  the shared commit set, and self-reinforcing: the first extension makes its branch the
  winner everywhere. Committers also read the genesis hash JOIN acks always carried and
  automatically re-Welcome any device that announced a losing branch.
- **Force-reseal-everything is gone.** The remaining roster-event sites (three on
  Android, one on desktop) re-sealed EVERY circle's history on any roster change — the
  ~100s stall class. All now drain the engine's per-circle `epoch_moved` flags (scoped,
  consuming, throttled). Measured: Android own-device echo **104s → 2.6s**; iOS→Android
  full-photo completion **18.8s → 6.7s**.
- **Desktop dropped every peer's profile card.** The hello handshake has always carried
  the signed card; desktop never read it, so every peer rendered as initials forever.
  Cards now ingest on all established hello paths (emoji, avatar, bio, link) — Apple
  `ContactsStore.setCard` parity.
- **Desktop calls rendered only after `getUserMedia` resolved** — a caller stared at an
  idle app through the OS mic prompt while the far side was already ringing. Both the
  dial and answer paths render the call screen first.
- **Google Play 16 KB page-size compliance.** Play flagged the production release: every
  packaged native library must carry 16 KB-aligned ELF segments on Android 15+. Two
  offenders: our own Rust core (NDK r27 does not align by default — r28+ does; the build
  now passes `-Wl,-z,max-page-size=16384` per Android target and readelf-verifies every
  produced .so, failing the build on any 4 KB segment) and the avif-coder codec stack
  (2.1.0 shipped 4 KB libs; 2.1.4 is fully aligned on the same API line — newer 2.2.x is
  built with Kotlin 2.3 and won't link here). Verified: all 28 .so in the release bundle
  are 16 KB-aligned.
- **Outgoing dials never timed out on desktop.** An unanswered dial now ends after the
  same 60s bound as incoming rings (proper hangup: far side stops ringing, session
  tombstones against invite retransmits).

### Changed
- **Desktop call screen rebuilt to macOS parity.** Full-window brand-gradient stage; 1:1
  shows the other person full-bleed with your mirrored camera as a corner PiP; groups get
  the adaptive tile grid; the active speaker glows (full-stage border in 1:1 — which now
  actually lights: the level detector used to disable itself with a single peer); avatars
  resolve photo → emoji → initials; circular glass controls anchored bottom-centre with
  mic/speaker device pickers.
- **Minimized calls dock into the tab bar** as a "Call" tab beside You (green pulse dot)
  instead of a floating pill that covered the composer. Audio keeps playing; the tab
  exists exactly while a live call is minimized.

### QA
- Desktop gained webview-driving ops (`ui`: call_start/accept/end/minimize/expand +
  `probe`, which reports the rendered DOM through the trail channel) — the desktop leg
  can now PLACE and ANSWER calls under test, and layout states are assertable without
  screen capture.

## 2026-08-22 — 1.6.0 (satellite wave, final)

### Satellite / low-data (the headline)
- **512px AVIF preview tier verified end to end** across MLS circles, legacy "My Circle", and DMs:
  only the ~6 KB preview crosses an ultra-constrained link; the full photo completes automatically
  on return to coverage. The negative gate (full media must NOT cross) is asserted per keying path.
- Ultra-constrained link policy (Text/KeyConvergence/Preview allowed; media deferred) exercised in
  both directions on every platform pair.

### Fixed — silent content loss (most serious)
- A contact's roster arriving by relay pull never replayed parked envelopes, and an already-held
  roster reported as *refused* — content could arrive and stay unreadable forever, with nothing
  logged. Both paths fixed; regression-tested (fail-without-fix verified).
- Epoch advance (rotation, tree commit, sibling-device registration) now triggers a history re-seal
  via the engine's own `take_epoch_moved` signal, replacing the roster-change proxy that missed the
  MLS tree-driven case and stranded receivers on unopenable envelopes.

### Fixed — crashes and aborts
- Android: opening the circle switcher crashed the app every time (uniffi `UInt` into `%d`);
  guarded by a source-scanning unit test.
- Desktop: a clock-step underflow in a stale-timer check aborted the entire app via mutex
  poisoning; all four sites now saturate, and **desktop mutexes no longer poison at all**
  (parking_lot) — a panic now costs one operation, not the process.
- iOS: feed video looped audibly with the app backgrounded and the phone locked; background pause
  now stops every registered player and looping asks the coordinator (foreground-aware).

### Fixed — media correctness
- EXIF orientation was dropped when minting previews/thumbnails on all three platforms and when
  drawing feed photos on Android (sideways photos, "flipping" on full-res arrival). All decode
  paths now normalize to upright; Android also banks post-rotation dimensions.
- Desktop still-loading placeholder collapsed into a 38px "pill"; now sized like real fitted media.
- Shared locations show selectable coordinates + "Map unavailable offline" when tiles can't load
  (off-grid is exactly when a pin matters). "Open in Maps" remains the offline path.

### QA infrastructure (why the above became findable)
- Per-leg delivery diagnostic (`parked` / `held_slots` / `missing_keys`) distinguishes "never
  arrived" from "arrived unopenable".
- Dump liveness (`dump_seq` + heartbeat) on desktop and Apple drivers — a frozen dump now reports
  itself instead of impersonating 20 delivery failures.
- Fail-fast for targeted runs; pixel-distinct fixtures per scenario; DM dump rows carry companion
  markers; Android dump reports markers/companions; call dumps report session + last frame handled.


## [Unreleased]

### Added — the 512px preview tier

- **Photos now carry a picture small enough to cross a satellite link.** Attaching a photo mints a
  512-pixel AVIF beside it — about six kilobytes, under two text messages, against the ≤32 KB thumb
  companion that already existed and a full photo measured in megabytes. It rides the signed media
  list as a `preview:` marker, the same shape as `poster:` and `thumb:`, so an older client simply
  ignores it.

  It uploads before anything else in the post, which stopped being a matter of politeness: on a
  constrained link the upload may only get through the first rank before the pass ends, so what is
  first decides what a recipient can see at all. It is fetched even under data saver, being the
  cheapest thing in the post. And it never draws as its own tile — without that guard a post would
  show the same picture twice, small then full, the moment the real bytes landed.

  AVIF rather than JPEG because JPEG cannot reach the budget: measured on real device photographs at
  512 pixels its floor is twelve kilobytes and it looks worse there than AVIF does at half the size.
  All three platforms encode to the same **byte** budget rather than a shared quality number, which
  would have silently meant three different things — their encoders' scales do not line up.

  **Off-grid, only the preview goes.** On a satellite link the upload queue sends the six-kilobyte
  picture and holds everything else back — the optimized copy and the original cannot cross that
  bearer, and trying would spend the whole pass failing. The post itself has already gone: it is
  real, signed and sealed. What is deferred is bytes, not authenticity. Nothing is dropped, only
  queued, and the moment service returns both halves finish on their own — the sender's remaining
  blobs upload and the recipient's deferred fetches run.

  **You can react to a picture before you can see it properly.** A post arrives complete in every
  way that matters — readable, with a real if small photograph — while the full copy is still on the
  sender's phone. Reactions and replies are text, and text crosses. What was missing is that the
  full picture then lands silently and nobody tells the person who engaged with it. Now they get one
  notification when it does. That is remembered entirely on the device; what you looked at and
  reacted to is not something anyone else learns.

  All three platforms mint previews at attach time. Desktop is the odd one out mechanically: it
  downscales and re-encodes photos in the webview, and Chromium's canvas can write PNG, JPEG and
  WebP but not AVIF — so that one encode happens in Rust instead, on the same sanitized bytes the
  composer is about to attach.

### Docs

- **A design for pictures that survive a satellite link.** [`docs/PREVIEW-TIER-DESIGN.md`](docs/PREVIEW-TIER-DESIGN.md)
  works out a fourth media tier small enough to cross the bearer low-data mode was built for. Nothing
  is implemented; the arithmetic decides the feature, and this time the arithmetic is encouraging.

  A 512-pixel preview costs about six kilobytes — under two text messages — but only in AVIF. JPEG
  cannot get there at all: its floor at that size is twelve kilobytes and it looks worse at the
  bottom than AVIF does at half the bytes. Measured on real device photographs and scored against the
  uncompressed original rather than eyeballed, because a size without a quality number attached means
  nothing.

  Every claim about what the platforms can do was checked rather than assumed, which mattered,
  because the requirement is not just reading these files but writing them — any device can be the
  sender. iPhones turn out to encode AVIF natively, confirmed by running the check on a simulator
  rather than trusting documentation that only ever mentions reading. Desktop cannot do it in the
  webview where it encodes images today, so that work moves into Rust, where it takes about twenty
  milliseconds. Android is the one gap and needs either a bundled library or a higher floor — a
  decision the document states plainly rather than burying.

  The rest is what the small picture buys: sending a photograph from a place with no signal, and
  other people being able to see it, react to it and reply before the full-resolution copy exists at
  all. Everything needed to make it complete itself later is already there — the reference travels
  inside the message, the bytes are fetched separately, and a missing blob already draws an honest
  "waiting for sender" placeholder. What is missing is a nudge at the moment service returns, and a
  note to anyone who reacted to a picture they could not fully see yet that it has arrived.

### Fixed

- **The Apple logic-test suite compiles again in CI.** It had been failing on every push since the
  carousel work — not a failing assertion, but the Swift type checker giving up on a single
  expression in the perceptual-hash tests: one `UInt8(…)` initialiser wrapping a mix of `/`, `&*`,
  `&+` and `%`, which leaves it enumerating integer overloads until it times out. The whole target
  fails to build, so all 81 tests were cancelled rather than run, and a red suite that stays red
  stops being read.

  Rewritten as typed statements. Worth recording that this does **not** reproduce on a fast local
  machine — the suite passed there both before and after — so the fix was verified against CI, not
  against a green run locally that proved nothing.

- **iOS now declares itself eligible for a carrier satellite network too.** The Android half of this
  shipped with the manifest declaration; the Apple half was written down as an open question,
  because the opt-in Apple documents is a per-connection Network.framework flag and Haven's mailbox
  traffic is QUIC and HTTP from Rust over ordinary sockets, with no object to set it on.

  That framing was wrong, and Signal's own repository settled it: the real mechanism is a pair of
  *entitlements*, which apply to the process rather than to individual connections. Signal shipped
  satellite support in a thirty-six line, code-free commit that adds nothing but those keys to every
  target that touches the network. Haven now carries the same two keys — optimised-for-carrier-network
  and an app category of messaging — on the iPhone app, the notification service extension and the
  share extension.

  Not on the Mac targets: Apple lists the entitlement for iOS and iPadOS only. Not on the broadcast
  extension either, which exists for screen sharing during calls, and calls are refused outright on a
  satellite link.

### Added — all platforms (low data mode)

- **Android now declares itself satellite-optimised.** A one-line manifest declaration is what gets
  an app access to a carrier satellite network when it is the only network available, and what lists
  it under the system's satellite settings. Without it the rest of low-data mode is a well-behaved
  app that never gets offered the link it was built for.

  The Apple equivalent is unresolved and is written down as unresolved: the opt-in Apple provides
  governs Network.framework connections, and Haven's mailbox traffic is QUIC and HTTP from Rust over
  ordinary sockets, with no object to set the flag on. Whether the restriction bites there too is a
  question for a real bearer, not a guess, and `docs/SATELLITE-DESIGN.md` now says so plainly rather
  than implying the box is ticked.

- **The wire savings are now real, not just available.** The compact envelope container landed able
  to be read but not written, because emitting it to a client that cannot parse it costs that client
  the message outright and there is no renegotiation once the bytes are in a mailbox. Circles now
  flip to it, and the trigger is unanimity: every member must have affirmatively advertised that
  their build can read it before a single byte changes shape. One member on an older app, or one
  whose profile has not reached you yet, keeps the whole circle on the old container. Silence always
  means legacy, never downgraded — the same reading of absence the seed-drop and MLS gates use.

  The capability rides inside the account-signed profile card, so a relay can neither forge it — which
  would push a circle onto a container someone cannot read — nor strip it, which could only ever cost
  bytes. A forged card teaches nothing and is covered by a test.

  A real bug got caught on the way: the marker was being learned only in the call desktop makes, and
  not in the one iOS and Android make. The gate would have opened on desktop and stayed shut forever
  on the two platforms that matter, and it would have failed *silently* — everything working, simply
  3.5 times more expensive for good. Both entry points now teach, and the test that covers it was
  confirmed to fail without the fix rather than merely assumed to.

  Measured end to end: the same message that took 12,953 bytes now takes 3,632.

- **Haven now notices when the network can't afford what it was about to do.** On a metered hotspot,
  a bandwidth-constrained cell, or a satellite bearer, it sends your text and holds the rest back
  until you ask. There is a three-way switch in Settings — automatic, always on, off — and automatic
  is the default, so it works without anyone finding it.

  What each level does is a deliberate choice rather than a slider. On a merely metered link a
  conversation still feels like a conversation: text, reactions, typing and calls all carry on, and
  thumbnails still load, because a feed with no pictures in it is a broken feed and not a thrifty
  one. What stops is the speculative and the bulky — stories, link previews, older history you
  haven't scrolled to, and syncing with your own other devices. On a satellite link only text moves,
  plus the key material needed to decrypt it. Photos and videos sit between the two at both levels:
  never fetched behind your back, never silently dropped, always available if you tap them. Silent
  refusal is worse than an informed expensive choice.

  **Nothing about the encryption changes at any level.** Every message is sealed exactly as before,
  with the same hybrid Ed25519 and ML-DSA-65 post-quantum protection, whether it crosses fibre or a
  satellite. Low data mode decides *whether* to send bytes, never how they are protected.

  "Off" is honoured everywhere except a genuinely ultra-constrained bearer, where it stays on and the
  UI says why — the operating system will refuse that traffic regardless, and an explanation beats a
  send that fails for no visible reason.

  The detection uses what Apple and Google actually shipped rather than what was announced. Apple's
  is the ultra-constrained path family from iOS 26 — there is no satellite framework, and the one
  reported for iOS 27 is not in the beta SDK. Android's is the API 36 bandwidth-constrained
  capability plus the satellite transport. Both sit behind availability gates, so the iOS 17 and
  Android 10 floors are untouched.

  The rule for what may cross lives in the shared Rust core, and all three clients ask the same
  function: iPhone and Android over the FFI, the Tauri desktop by linking the core directly. That is
  the point — a policy written three times is three policies. A test sweeps every combination of
  link and traffic kind and requires the FFI mirror to agree with the source on all of them.

### Core (low-data mode, stage S0)

- **One policy table, consulted by both platforms.** Low-data mode now has a definition rather than
  an implementation: `haven_p2p::transport` gained a three-level link constraint — normal, low,
  ultra — and a table saying what each level permits for each kind of traffic. Apple detects the
  level with `NWPath` and Android with `NetworkCapabilities`, but both then ask the same Rust
  function what may cross, so the two clients cannot drift into different ideas of what the mode
  means. That drift is exactly what the parity rule exists to prevent, and mirroring the enums
  across the FFI boundary would have reintroduced it, so a test sweeps all thirty-three
  link-by-traffic cells and requires the mirror to agree with the source on every one.

  The shape is deliberate. Low Data Mode keeps a conversation feeling like a conversation — text,
  reactions, typing, calls all still work — and stops what is speculative or bulky: stories, link
  previews, history you have not scrolled to, and syncing with your own other devices. An
  ultra-constrained link, which is what a satellite bearer reports, keeps only text and the key
  material needed to decrypt it. Media is the one thing that sits between allowed and refused at
  both levels: never fetched in the background, never silently dropped, but always available if you
  ask for it and accept the cost. Silent refusal is worse than an informed expensive choice.

  Two invariants are pinned by tests rather than intent. Text and key convergence are permitted at
  every level, because the moment either becomes conditional this has stopped being a messaging
  feature. And tightening the link may never loosen the policy — a sweep asserts that every category
  is at least as strict on ultra as on low, so a future row cannot be added the wrong way round.

- **A Haven message is about to stop costing thirteen kilobytes to send a word.** The envelope every
  message travels in was still serialised as JSON, which renders each byte of ciphertext as three or
  four characters of ASCII. Measured on a one-word direct message: **12,953 bytes on the wire, of
  which 3,632 are real** — the other nine and a third kilobytes are decimal digits and commas
  describing them. The same waste was found and fixed for sealed media envelopes, where it had been
  turning a 48 MB video into a 167 MB blob, but the epoch envelope never got the same treatment.

  It now has a compact binary container alongside the JSON one, tagged so the two can never be
  confused, and it is **3.57x smaller across every message size measured**.

  Nothing about the encryption changes, and there is a test that says so rather than a comment
  claiming it. The hybrid Ed25519 and ML-DSA-65 signature is computed over a transcript that hashes
  the envelope's *fields*, never their serialised form, so the identical envelope in either container
  carries the identical signature bytes and verifies identically. The test asserts that equality
  directly, then opens a compact-encoded envelope through the real verify-and-decrypt path, then
  flips a bit in its signature and requires the open to fail. Post-quantum protection is exactly what
  it was on both containers; only the packaging got smaller.

  **Nothing sends the new container yet, deliberately.** Reading it ships first. The mailbox key is a
  SHA-256 over the envelope's exact bytes, so a client that started emitting the compact form would
  both move every key in every mailbox and hand un-upgraded members a body their parser cannot read.
  So this release only learns to *read* both, and the send path is unchanged and byte-identical —
  pinned by a test, because that hash is load-bearing. Writing flips in a later release once a circle
  is known to be fully capable, the same staged pattern the seed-drop and MLS gates already use.

  One trap worth recording: postcard is non-self-describing, so struct fields are positional with no
  names on the wire. The ratchet index is `skip_serializing_if` — correct and byte-saving for JSON —
  which would have written six fields and then expected seven back. The compact form uses an explicit
  wire struct that always encodes it, costing one byte, with a regression test covering both the
  absent and present cases.

### Docs

- **A design plan for carrying Haven over carrier satellite data.**
  [`docs/SATELLITE-DESIGN.md`](docs/SATELLITE-DESIGN.md) works out what it would take for Haven to
  be usable on T-Mobile's T-Satellite bearer, and on the direct-to-cell services arriving behind it.
  Nothing is implemented. It is a sibling of the LoRa spike below and deliberately reuses that
  document's byte-budget stages rather than restating them, because the two transports have the
  same disease three orders of magnitude apart.

  The platform half turned out to be easier than the reporting suggested. Apple did not ship a
  satellite framework and the one rumoured for iOS 27 is not in the beta SDK — diffing the iOS 26.5
  and 27.0 SDKs turns up two cosmetic lines in the networking headers and nothing else. What Apple
  actually shipped, in iOS 26.0, is a third tier below expensive and constrained: a path can now
  report itself ultra-constrained, and report a link quality of minimal, moderate or good. A
  connection will not touch such a path unless the app explicitly asks for it, which is the whole of
  the story about Apple discouraging satellite reliance, and is the right default. Android's
  equivalent is older, wants a line in the manifest declaring the app satellite-optimised, and warns
  that the system may cut off an app that transfers too much. Both are available today; there is
  nothing to wait for.

  The hard half is not code. A one-word Haven message is about twelve kilobytes on the wire, which
  is survivable on a bearer that carries real IP where it was fatal on radio, but it is still mostly
  waste and the fix is the same postcard encoding the LoRa spike already proposes. Past that, the
  carrier admits apps by private allowlist, and the apps on it share a property Haven does not have:
  a small fixed set of backend endpoints. Haven dials arbitrary peers and user-run relays that did
  not exist when any list was written. Whether that matters depends on whether admission is enforced
  by app identity or by destination, which is not publicly documented, and the document's first
  recommendation is to ask before building anything that assumes an answer.

  The rest is a policy table of what may cross the bearer — text yes, media and calls and stories and
  history backfill and self-sync no, as hard refusals rather than throttles — a per-pass governor,
  and an open question about whether push reaches a third-party app over satellite at all. If it
  does, Haven is unusually well placed, because the ciphertext already rides inside the notification
  and a delivered message costs almost nothing to receive. If it does not, off-grid Haven is a
  foreground experience and should be designed as one rather than apologised for.

- **A design spike for carrying Haven over LoRa radio.** [`docs/LORA-DESIGN.md`](docs/LORA-DESIGN.md)
  works out what off-grid text messaging between two people with no internet, no cellular and no
  Wi-Fi would actually take. Nothing is implemented; the document exists because the arithmetic
  decides the feature, and the arithmetic is unflattering.

  A one-word direct message is about twelve kilobytes on the wire. A radio packet carries roughly
  two hundred bytes. Two things account for almost all of the difference: the epoch envelope is
  still serialised as JSON, which renders every byte of ciphertext as three or four characters of
  ASCII — the same waste that was found and fixed for sealed media envelopes but never for this one
  — and ninety-three percent of what remains is the post-quantum half of the signature. Fixing the
  encoding is worth doing on its own, for every message on every transport, and the spike proposes
  it as a stage that ships independently of any radio.

  The rest of the document is honest about what the link cannot do rather than optimistic about what
  it might. You cannot meet someone new out there — an identity is thirty-two hundred bytes and
  buying the post-quantum property is exactly what makes it too large to send. If a circle rotated
  its keys while you were away, that conversation stays dark until someone reaches the internet.
  And a radio transmitting is a beacon that anyone within kilometres can hear, which is a worse
  position than any transport Haven has today and belongs in front of the user before they switch
  it on, not in a support thread afterwards.

## [1.5.0] — 2026-08-14

### Changed — Apple (history arrives as it is read)

- **Adding someone no longer hands them your whole history at once.** It used to re-seal every event
  you had ever authored to that circle — real cryptography per event — send the lot, and drag the
  entire media backlog behind it, all before the new member had looked at anything. On an account
  carrying an imported archive that is hundreds of envelopes and a gigabyte of media for a first
  screenful nobody had scrolled past yet.

  They now get the newest 60 up front and ask for the page before their oldest post as they scroll
  back — the same way media has always been fetched only when a tile appears. The reply is ordinary
  event frames, so the receiving side is the path that already ingests and deduplicates; only the
  ask is new. Requests are membership-checked, so a stranger cannot make you re-seal anything.

  The periodic full re-send is unchanged and remains the backstop: a page can be dropped, or
  answered by nobody, and history still reconciles on its own. Direct messages are exempt — a
  conversation is read from the beginning and is small enough that paging it would cost a round trip
  to save nothing.

  Apple only in this release; the core API it rests on (`sync_envelopes_page`) is shared, so Android
  and desktop need the request handler and the scroll trigger to follow.

### Fixed — Apple (the You tab after an import, and importing twice)

- **The You tab built every post at once and the app was killed for memory.** Both profile lists —
  your own and a circle member's — used a plain `VStack`, so opening the tab instantiated every card
  with its media, its blurred backdrop bitmap and its own view graph. With a handful of posts nobody
  noticed; after an Instagram import there are hundreds. A device report caught it at 59% CPU
  sustained for two and a half minutes, its samples 254 SwiftUICore / 160 UIKitCore / 103 QuartzCore
  / 43 AttributeGraph against 33 in Haven's own code — a view graph being built, not work being done
  — with the app dying shortly after the tab appeared. Both lists are `LazyVStack` now, the stories
  strip is a `LazyHStack`, and the cards are `.equatable()` so a feed republish doesn't re-evaluate
  every one of them. The circle feed had been lazy all along; these two were simply never given the
  same treatment, and no ordinary account had enough posts to expose it.

- **Importing the same archive twice imported everything twice.** Resuming by index only ever helped
  the run it was written for: pick the same export again — because the first attempt was killed, or
  to bring over the stories you skipped the first time — and every post landed a second time.
  Imported items are now recorded against an identity taken from the archive itself (the media
  entry's path plus its capture time), checked *before* anything is read, so a re-import skips what
  is already here without decoding, transcoding or identifying its way through it again. The preview
  screen says how many will be skipped, so a re-import that finds nothing new doesn't look like an
  import that silently failed.

- **An interrupted import couldn't resume.** The checkpoint is keyed on a security-scoped bookmark of
  the archive, and that bookmark was being taken *outside* the file's security scope, where the
  system needn't allow it — written with `try?`, so when it failed no checkpoint was recorded at all
  and the per-item checkpointing that depends on it never ran either. The bookmark is now taken
  inside the scope, and every path that abandons a pending import says so in the log instead of
  failing invisibly.

### Fixed — Apple (a post wider than the phone)

- **One post in the feed rendered wider than the screen**, its picture cut off at both edges, while
  the post directly below it was perfect. The cause was a single modifier. A post whose full-size
  bytes have not landed yet draws its small `thumb:` companion instead, and that placeholder used
  `.scaledToFill()` — which returns a size that COVERS its proposal rather than fitting inside it.
  Nothing upstream shrinks an oversized child: the page's `.frame(maxWidth: .infinity)` grows to fit
  it, and the `.clipShape` after that then clips to the grown width instead of the card's. Measured:
  a 512×288 thumb inside a 325pt page claimed **1208pt**; a panorama claimed 2720pt.

  A **tall** source — a cropped screenshot, which is what was reported — breaks differently and just
  as visibly: there the page's width comes out correct, and the picture is instead drawn 325×705
  inside a 325×406 page and clipped to a magnified vertical slice. One modifier, two symptoms,
  depending only on whether the photo is taller or wider than the page it lands in.

  It only ever hit posts still waiting on their media — once the bytes land, a different code path
  draws them with `.fit` — which is why it struck one post and not its neighbour, and why it lasted
  this long. The placeholder now fits, which is also what the full-size image cross-fading in over it
  does, so the swap no longer re-frames the picture. The page additionally proposes its own size to
  that branch (the one branch that wasn't given it), and the strip either side of a fitted thumb
  carries the blurred wash rather than the card's flat surface.

  Covered by `PostMediaPageWidthTests`, which asserts two invariants rather than the modifier — a
  page never claims more width than the card offered it, and the placeholder shows the whole photo
  rather than a slice of it. The second exists because the first is green for the tall case: the
  frame around the picture reports a clamped size however big the picture inside it goes, so the test
  has to measure the image, not its container.

### Fixed — desktop (the import shakedown)

Running a real 1.28 GB archive end to end on desktop found a long tail of faults, several of them
long-standing and only exposed by the volume:

- **Nothing was optimized.** The importer runs headless in Rust and the only encoder this app has
  lives in the WebView, so archive bytes were sealed exactly as they came out of the zip. It asks
  the WebView now, over a job-id bridge, and falls back to the raw seal whenever that cannot answer.
  Stills are encoded in a worker, off the thread that paints.
- **Video re-encode wrote SILENT clips** — imports *and* anything posted from the desktop composer,
  which shares that path. It muted the element to keep playback quiet and then took the audio from
  its `captureStream`, which carries nothing usable when muted. Audio is decoded from the source
  bytes now and mixed straight into the recorder.
- **Only oversized clips are re-encoded.** The encode plays a clip through a canvas in real time on
  the main thread, so doing it to every video cost each clip its own duration — the beachballing.
  An Instagram export is already ≤1080p, so most clips need nothing.
- **Media was clipped, not cropped.** A percentage `max-height` resolved against the page's
  aspect-ratio height rather than its capped one, so a 9:16 clip laid out 1229px tall inside a 460px
  page and `overflow: hidden` cut the rest.
- **Neither feed paged.** The You tab appended every post — hundreds of cards with their own media.
- **The feed re-read every envelope in the circle** on each of the engine's frequent change events.

Also on desktop: autoplay follows the centred post (video and its song, one at a time, super data
saver the only kill switch); clips have a mute control; stories auto-advance, play their attached
song, and layer their chrome over the story rather than around it; the song picker searches the
catalog and auditions a track before attaching it; the post editor changes media, song and location;
and every dialog has a visible way out.

### Added — all platforms (bring your Instagram archive over)

- **Import from Instagram**, in Settings. A guided walkthrough — open Instagram's download page,
  request the export, come back days later and hand Haven the `.zip` — because there is no API for
  this and the wait is on Instagram either way. The one irreversible mistake (choosing their HTML
  format, which contains no importable data and cannot be converted) is called out at the step
  where it is made rather than in the error afterwards.

  Nothing publishes until a preview is confirmed: what was found, the date span, the total size,
  and any files referenced but missing from the archive. Posts and reels arrive **backdated** and
  **silently**; photos and videos are re-encoded through Haven's usual optimizer with a poster still
  cut for every video, so imported media behaves like media posted by hand. Carousels stay a single
  post. The import runs in the background with a progress banner, survives the app being killed, and
  resumes where it left off.

  Verified end to end against a real 1.28 GB export: 372 items (203 posts, 85 reels, 84 stories),
  1129 media files, zero unresolved references.

- **Stories are opt-in and off by default.** Instagram archives *every* story automatically, so an
  export holds all of them rather than the ones added to a Highlight — and it records no marker
  distinguishing them. Turned on, they are saved as **kept stories** on your profile, never
  published to the circle.

- **Song suggestions.** Open the song picker with nothing typed and the top tab suggests tracks
  drawn from what the photo shows and what the caption says. Available in the feed composer, the
  post editor, DMs and the story composer. Explicit tracks are never suggested, and neither are
  songs in a language you don't read.

- **Shazam song credits.** A reel that shipped with its soundtrack gets the real song named on it.
  The credit never becomes a second audio source — the video keeps its own sound — and requests
  that Shazam declines are retried later in their own queue rather than lost.

### Added — Desktop (Instagram archive import)

- **Import from Instagram** on Windows, Linux and the desktop Mac build, in Settings — the same
  guided walkthrough Apple ships. Three steps (ask Instagram, wait for their email, pick the `.zip`),
  the JSON-not-HTML warning at the step where that mistake is made, then a preview of exactly what
  was found — posts, reels, photos and videos, total size, date span, and any file the archive
  references but does not contain — with nothing published until it is confirmed.

  Posts and reels land **backdated** and **silently**, newest first so the feed grows downwards and
  never jumps under whoever is reading it. Carousels stay a single post. The run lives on its own
  thread in the Rust backend, so closing the sheet does not stop it, a floating pill keeps the
  progress visible wherever you browse, Stop takes effect immediately (mid-album, not at the end of
  it), and quitting Haven resumes from the last completed item on the next launch.

  The parser is verified against the same real 1.28 GB export the Apple build was: 372 items
  (203 posts, 85 reels, 84 stories), 1129 media files, zero unresolved references.

- **Stories are opt-in and off by default here too**, and land as kept stories on your own profile —
  never published to the circle.

- **Song suggestions for silent posts**, from the free iTunes Search API (the source Android already
  uses), chosen from the caption's subject words and the post's era. A post that already makes a
  sound keeps its own audio and is never given one — desktop reads the MP4 track table directly to
  tell a muted clip from an audible one. Explicit tracks are never suggested, songs in a script you
  don't read are rejected while accented Latin titles are kept, and no track is attached twice in
  one run.

### Known gaps — Desktop

- **Imported media is not re-encoded, and videos get no poster still.** `desktop/src-tauri` carries
  no encoder by design: the only one a WebView exposes emits VP8/Opus in WebM, which no other Haven
  client can play, so transcoding an Instagram export here would replace working H.264 with video an
  iPhone cannot decode. The bytes are imported as Instagram already encoded them (≤1080p), and the
  re-optimize scan still reports anything genuinely oversized. Apple's build does re-encode and does
  cut a poster.
- **No Shazam song credits.** Identifying the song already playing in a reel is Apple-only; desktop
  only ever *suggests*, and only into silence.
- The importer's UI strings are English-only for now; the six shipped languages fall back to English
  until the generated dictionaries catch up.

### Added — Android (Instagram archive import)

- The same importer on Android: walkthrough, preview, background progress banner and resume. Media
  goes through Android's normal optimize-and-poster ladder, stories are opt-in and kept to your
  profile, and the feed's recompose is coalesced so a several-hundred-post import doesn't thrash it.
  No Shazam credits (that is Apple-only), though a credit attached on an Apple device still syncs
  here and shows on the post.

### Changed

- **Nobody is notified by an import, and nobody is made to download it.** Several hundred posts
  would otherwise mean several hundred notifications for content that is often years old. Members
  fetch only thumbnails and video posters until they actually open something, so a large import
  costs the rest of your circle almost nothing.

- Relative times roll over to years — a 2023 post reads "2y", not "32mo".

### Fixed

- **The feed no longer moves under you while posts arrive.** Two independent causes: cards changed
  height as their media landed (a card is sized by its media's shape, which was re-guessed on every
  render), and imported posts were being inserted above whatever you were reading. Media shape is
  now remembered from first sight, and imports fill in from the bottom.
- Story songs stop when the story is skipped or dismissed, and a story silences the feed behind it.
- Song previews play without an Apple Music subscription.
- Android compiled again (broken since 1.4.5 by a duplicate accessor).


## [1.4.7] — 2026-08-12

### Fixed — Apple (battery)

- **Haven asked iOS to wake it every 15 minutes forever, whether or not anything was waiting.**
  1.4.1–1.4.6 made each background wake cheaper; none of them stopped the app from *requesting*
  wakes. A `BGAppRefreshTaskRequest` was chained unconditionally on every background entry and again
  at the end of every refresh, so each granted window ran a full mailbox LIST across every circle
  plus a media-backup pass and then immediately booked the next one — a self-sustaining treadmill on
  a phone where nothing had happened, and every grant of it counted toward Settings' "Background
  Activity".

  A refresh is now requested only when there is work we already know is unfinished — authored
  envelopes still queued for a mailbox, media still owed to a relay, or a mailbox backlog mid-drain
  — and the next wake is chained *after* the pass, based on what is still owed rather than booked up
  front. With nothing outstanding, Haven schedules **one** wake at the moment a 6-hourly safety-net
  sweep comes due (≈4 idle wakes a day instead of ≈96), and a wake with no backlog and no sweep due
  flushes what it owes without listing any mailbox at all. Push hints are still fetched on every
  wake (targeted single-key GETs), so delivery is unchanged: APNs remains the delivery path.

- **The 15s/30s heartbeats were gated, not stopped.** Backgrounding parked their due-gates but left
  both repeating `Timer`s scheduled on the main runloop. For as long as anything kept the process
  unsuspended — an upload flush, a media-backup assertion, a push wake, a BGAppRefresh grant — they
  kept firing and hopping the main actor purely to compare two integers and return. They are now
  invalidated on background and re-armed on foreground, and a cold *background* launch (push, VoIP,
  BGAppRefresh after a kill) no longer arms them at all. A PushKit VoIP launch still arms its
  live-call frame poll, which is the one timer a backgrounded call genuinely needs.

  Net effect: a pocketed Haven with no circle activity has nothing scheduled and nothing to wake it
  but a real push. MARKETING_VERSION 1.4.7, build 471.

## [1.4.6] — 2026-08-12

### Fixed — Apple (battery)

- **Still multi-hour Background after 1.4.1/1.4.2 with zero activity.** Residual warm paths that
  survived the earlier parks:

  1. **Live Multipeer sessions stayed up in the pocket.** Discovery was parked, but a connected
     (or flapping) `MCSession` kept AWDL/Bluetooth warm; peer-left then re-opened Bonjour for 45s
     with no foreground check.
  2. **Push-hint media `requestMedia` armed a 5s retry timer** that outlived
     `fetchCompletionHandler` / `setTaskCompleted` and kept restore Tasks + peer asks running.
  3. **Cold pocket configure still started media-backup drain + upload flush** under their own
     background-task assertions, stacking with the push/BGAppRefresh work.

  Now: on background, fully disconnect Multipeer (not just park discovery) and kill the fresh-media
  timer; refuse peer-left rediscovery, `requestMedia`, and `requestMissingMedia` while pocketed;
  slim wakes skip media fetch entirely (envelopes only — media loads on open / NSE prefetch);
  remint-only cron does remint and reports `.noData` with no flush/LIST; re-park after every wake
  completes. MARKETING_VERSION 1.4.6, build 470.

## [1.4.5] — 2026-08-12

### Changed — Apple + Android + Desktop (story replies in DMs)

- **Replying to a story now attaches a deep link, not a resealed permanent media copy.** The DM
  bubble shows a **tall portrait crop** of the story (author framing applied) that matches the
  story canvas. Tap opens the real story sheet — progress bars, music, caption framing — the same
  deep-link path as the activity feed. When the story's 24h window ends, the tile becomes
  **"Story expired"** unless the author **kept** it on their profile (kept stories still open the
  full viewer). Localized across the supported languages. Same behavior on iOS, Android, and
  desktop for cross-platform parity with "Message the author" post links.

- **Retroactive for older story replies.** Pre-1.4.5 replies that only resealed media (no deep link)
  are matched back to the peer’s (or your) story that was live when the reply was sent — tall crop,
  full story open when still live/kept. **When the story is past 24h and not kept, the DM tile is
  always "Story no longer available"** — never the eternal resealed media thumbnail (hard 24h
  window + association so purged events still swap out correctly).

## [1.4.4] — 2026-08-11

### Fixed — Apple (feed media)

- **Feed videos still painted black letterbox bars over the blurred poster wash.** 1.4.3 cleared
  `AVPlayerLayer.backgroundColor` and stacked the blur under the player; on device CoreAnimation
  still filled the pillar/letterbox regions with opaque black for the whole loop. Photos never hit
  this because `Image` `.fit` leaves those strips transparent.

  Now: size the live player to the video's own aspect (same layout as a photo tile). The layer no
  longer letterboxes at all, so the blurred poster wash fills the strips for the whole loop.

## [1.4.3] — 2026-08-11

### Fixed — Apple (feed media)

- **Feed video letterbox lost its blurred edge wash as soon as playback started.** Photo posts (and
  a video's poster still) use `Image` `.fit`, so the blurred edge wash shows in the letterbox strips.
  The live `AVPlayerLayer` defaulted to an opaque black letterbox fill, which painted over that wash
  for the whole loop — "thumb has the blur, then it disappears when the video starts."

  (Incomplete: clearing the layer background was not enough on device — fixed properly in 1.4.4.)

## [1.4.2] — 2026-08-11

### Fixed — Apple (battery)

- **The 1.4.1 battery park still left a door open on cold background launches.** Settings → Battery
  could still show multi-hour Background time with zero circle activity after the 1.4.1 fix shipped
  in build 470. Root cause: `FeedStore.appIsForeground` defaulted to `true`, and a pure background
  launch (content-available push, VoIP, BGAppRefresh after the process was killed) never fires a
  `scenePhase` `onChange` — so `setForeground(false)` never ran, the 15s/30s heartbeats kept the
  "on screen" cadence, Multipeer still opened a discovery window, and the daily mailbox re-assert
  could seal+upload under a background assertion. Same trap `AudioCoordinator` already fixed for
  silent overnight music.

  Now: seed `appIsForeground` from `UIApplication.applicationState`; re-sync at configure, remote-
  notification, and BGAppRefresh entry; skip Multipeer discovery + daily backfill + immediate
  self-sync fan-out on pocket boots; re-nudge Multipeer only when the user is actually frontmost.

## [1.4.1] — 2026-08-09

### Fixed — Apple (battery)

- **Haven ran for hours in the Background with zero activity.** Settings → Battery showed multi-hour
  Background time while nothing was happening in the circle. Three things stacked:

  1. Every `content-available` push wake (including the storage-owner remint cron) called
     `forceSync()` — Multipeer discovery for ~45s plus hello/roster fan-out to every contact — and
     always reported `.newData`, so iOS never treated the wake as empty.
  2. Backgrounding only *stretched* the idle timers. Any leftover `UIApplication` assertion (media
     backup drain, envelope flush) kept the main runloop alive, so the 15s/30s heartbeats kept
     LISTing and fanning out for the whole assertion window.
  3. The media-backup drain could re-arm every 2s while pocketed whenever the backlog was non-empty,
     holding a background-task assertion each pass. Background tasks also had no expiration handler.

  Now: hard-park Multipeer and park timer due-gates on background; mailbox/sync timers and
  `syncWithContacts` no-op while pocketed; push and BGAppRefresh use `slimBackgroundSync` only
  (inbox + mailbox pull + one upload pass) and report `.noData` on an empty poll so the process can
  suspend immediately; remint-only cron does not sync; media backup does one budgeted pass while
  pocketed and does not re-arm; upload drains install expiration handlers.

### Fixed — Apple + Android + Desktop + relay core

- **A large video could get permanently stuck at "No longer available", with the original sitting on
  your other device.** A chunked blob is 8 MB windows at `haven/media/<ref>.p/<i>` under a tiny
  `HVCHUNK1` manifest at `haven/media/<ref>`, and four separate places treated the manifest as if it
  were the blob. Together they made an incomplete relay copy permanent and undetectable:

  - The **backup probe** asked only whether the manifest key existed. A manifest over a partial chunk
    set therefore read as a finished upload, went into the write-once backup ledger, and was never
    looked at again — so the author's device reported the post as safely backed up while nobody could
    fetch it. It now verifies the final window too, and re-uploads when it doesn't check out.
  - The **own-relay upload discarded its own failure**: `localPut` returns a `Bool` that was thrown
    away, and the caller's `try?` swallowed thrown errors before marking the ledger regardless. A
    window that never landed let the loop run on and write the manifest anyway. A failed window now
    stops the upload before the manifest is written and is not recorded as backed up.
  - **Restore pinned the manifest's source** and pulled every window from it, so a source holding a
    manifest but not all of its chunks was a dead end even with a sibling relay holding the complete
    blob — it was never asked. Missing windows now fall through every reachable relay/bucket, and a
    window that is absent *everywhere* is reported as an incomplete stored copy (repaired in place if
    this device holds the plaintext) instead of retrying the same hole forever.
  - **Relay mesh replication** pulled a manifest and its windows as unrelated keys, in lexicographic
    order — which puts `<ref>` *before* `<ref>.p/0`, so the 100-byte manifest reliably landed and the
    8 MB windows were what got cut off by the per-pass cap. Windows now rank ahead of manifests, and a
    manifest whose windows aren't local is skipped until they are.

  The probe fix, the ledger invalidation and the own-device ask land on all three clients. Android and
  desktop already failed over to the next relay when a reassembly stalled, so only Apple needed the
  per-chunk source fallback; the mesh-replication fix is in `haven-net`, so every relay gets it —
  including standalone Linux/Docker ones.

- **Your own media could only move between your own devices over the local network.** The media ask
  (frames 3/33) fanned out over iroh to *contacts* only, and your own devices are not contacts — they
  live in the account's device roster. The own-device *serve* was likewise nearby-only, while the
  friend path has always mirrored each chunk over iroh as well. So one of your devices could hold a
  video the other needed, both online, and no transport connected them off a shared LAN. Both lanes
  now include your own devices, and a nearby rate-limit no longer abandons a transfer that iroh is
  carrying successfully.

- **"Notify me when it's back" did nothing for your own posts.** `requestMediaWhenAvailable` treated
  "I authored this" as "no peer is needed" — true of the account, false of the device. On a device
  holding no plaintext (a post made on your phone, viewed on your Mac) it logged and gave up. It now
  asks your other devices, which is exactly who has it.

- **A peer asking us directly for media we hold now re-checks our backup.** That ask means a relay
  failed to serve them, which is the only signal in the system that a stored copy has gone bad — and
  nothing listened to it. Throttled to once an hour per ref, and a probe rather than a forced
  re-upload: it re-sends only what a destination actually turns out to lack.

- **Some posts drew no blurred backdrop, apparently at random.** `BlurredMediaBackdrop` loaded once
  via `.task(id: ref)` and, on failure, left itself unloaded "so a later run retries" — but `ref`
  never changes and the view observes nothing, so there was no later run. Both ordinary failures are
  transient (bytes not on disk yet; a video poster that hasn't been cut), so any card built before its
  media arrived kept a flat black letterbox for the life of that card. It now retries on a widening
  backoff for ~2 minutes, ending as soon as the card scrolls away.

- **Videos pillarboxed on a wide window when they could have filled it.** The single-media page height
  was capped at a flat 460pt on anything but a portrait phone. At the ~820pt of card width a normal
  Mac window gives, that page is 1.78:1 — so every clip narrower than that (3:2, 4:3, 1:1) was fitted
  by height and drew blurred pillars either side. The cap is now a minimum page *aspect*, which is
  width-independent: 4:3 and 3:2 fill the card, and only genuinely tall media letterboxes.

## [1.3.1] — 2026-08-03

### Fixed — Apple + Android + Desktop

- **"Post unavailable" for every activity row about a comment.** Reacting to (or replying to) a
  comment is ordinary — the core's `react`/`comment` work on ANY event id — so those rows and their
  push notifications carry the **comment's** id as their tap target. But a comment is not a top-level
  feed item: it lives inside its parent post. Every deep-link screen looked the target up with
  `feed(circle).first { $0.id == target }`, matched nothing, and reported the one failure message it
  has for deleted / not-yours / not-synced. The post was sitting right there in the feed the whole
  time.

  All three clients now resolve an id that names a comment **up to the post that carries it**
  (`FeedStore.post`, `PostLinkScreen`, `openPostLink`) — which also fixes the same tap arriving from
  a notification, since every entry point funnels through that one lookup. The linked comment is
  shown (never hidden behind "show all N comments") and tinted, because landing on a post with a
  dozen comments doesn't answer *which* one was reacted to.

## [1.3.0] — 2026-08-02

### Added — Apple + Android

- **Share into Haven from anywhere, and pick who it goes to.** The share sheet now takes text,
  links, photos, videos **and files** (PDFs, zips, .docx, audio), and asks where they should go: a
  post in one of your circles, a story, or a conversation — a friend or a group DM.

  Files are the new content type on both platforms. On Apple the extension prefers
  `public.file-url` over `public.url`, which is the subtle part: a document shared from Files
  conforms to both, and the URL branch had been turning a real attachment into a `file:///…` string
  nobody could open. The document keeps the name the sender saw. On Android there's a new
  `application/*` + `audio/*` SEND filter, and the ingest moved off the main thread — a shared file
  can be hundreds of megabytes, and reading it on the looper is an ANR. Both platforms cap the
  attachment at the same size, and Android checks the size *before* reading rather than after.

- **Your Haven conversations now appear in the row at the top of every app's share sheet** — the
  same place Messages, Signal and Slack put theirs. Tapping one skips the "where should this go"
  step and opens straight into that thread's composer.

  Apple donates an `INSendMessageIntent` per conversation (`ShareSuggestions.swift`); Android
  publishes long-lived sharing shortcuts with a `<share-target>` (`ShareShortcuts.kt`). Both are
  ranked by recency, both carry the conversation's name and avatar and **never any message
  content**, and both are retracted when the thread is deleted, its circle is locked, or the account
  is wiped. There's a **Settings ▸ Privacy ▸ Share sheet** switch (default on) — turning it off
  erases what was published.

  Locked circles are never suggested, on either platform. A locked circle hides that it exists,
  which a tile bearing its name in every other app's share sheet would not — the same rule Spotlight
  indexing already followed.

- **Android can open a file someone sent you.** It could receive a `file_` attachment and show a
  tile for it, and that was the end of the road — no way to read it, save it, or pass it anywhere.
  A document now has a real page in the feed and in DMs: name, size, **Open**, **Share**, and a
  Download when the bytes aren't on the device yet.

  A `file_` blob is a ZIP, always — the ref carries no filename or type on the wire, so the real
  name only survives inside an archive. Android has no built-in zip viewer, so handing it the
  wrapper would be a dead end for the ordinary one-document case; a single-entry archive is
  unwrapped and the *document* is what gets handed over. Entry names are treated as hostile
  (`../` in a zip entry is the classic path-traversal, and this one is written to disk), so only
  the basename is ever used. The decrypted copy is staged in a cache directory served by a
  `FileProvider` with a one-shot read grant and swept after an hour — never a world-readable path,
  and never Haven's own sealed store.

### Fixed — Apple

- **Tapping Haven in the share sheet looked like the sheet just closing.** The extension had no UI:
  it extracted the attachments, tried to launch the app by walking the responder chain for an
  `openURL:` selector, and completed. That trick isn't a supported way for an extension to open its
  host app, and when it's refused there's no feedback at all — the sheet dismisses and nothing
  happens until you open Haven yourself.

  The extension has a **composer of its own** now: attachment thumbnails, a caption field, and a
  destination list — conversations, circles, or your story. It still doesn't *send* (no identity, no
  engine, seconds to live); it records the decision beside the media and Haven performs the sealed
  send the moment it's frontmost. The difference is that the tap always opens something, and the
  app-launch hand-off is no longer load-bearing: if iOS refuses it, the share is queued rather than
  lost, and Haven no longer asks you a second time where content you already routed should go.

  The picker reads a small snapshot of destinations the app mirrors into the App Group — names,
  ids, and small avatars. **No message content, and no biometric-locked circles**: the extension
  runs outside the app's Face ID gate, so a locked circle is omitted at write time rather than
  filtered at read time.

- **Haven's conversations never appeared in the share sheet's suggestion row.** The donations were
  correct and the `NSUserActivityTypes` declaration was there, but the share extension didn't
  declare `IntentsSupported: [INSendMessageIntent]`. Donating tells the system the conversations
  exist; without an extension that says it can *receive* that intent, iOS has nothing to hand a
  tapped suggestion to, so it draws no tile — silently. Nothing warns about this.

- **One shared video showed up as three attachments**, one of them a document icon. The routing
  sheet drew `refs` verbatim, and a video is three refs — the playable clip plus its poster and
  original companions. It renders `MediaVariants.displayRefs` now, the same contract the feed uses.

- **A direct message sent from the share sheet could vanish.** `FeedStore.sendMessage` returns
  quietly when the engine isn't configured — which is exactly the state a *cold* launch is in when
  `onOpenURL` fires — and the queue entry was deleted regardless of whether anything was sent. The
  only copy of the message went with it. Sending now reports success, the queue keeps anything that
  wasn't delivered, and the drain waits for the engine (and retries) instead of racing it.

- **Tapping a share action didn't open Haven.** A share extension *can* launch its host app — the
  trick is SwiftUI's `@Environment(\.openURL)` fired from the button action itself, while the
  extension still owns user interaction. Requested any later (after `completeRequest`, or from a
  controller callback) iOS drops it silently, which is what made it look impossible. Every action
  now asks for the launch first and commits the share second. Two backstops sit behind it:
  `NSExtensionContext.open` (which does work for share extensions on modern iOS, docs
  notwithstanding) and a responder-chain walk that now matches **`UIApplication` specifically** — the
  earlier version performed `openURL:` on the first responder that merely answered the selector,
  which isn't necessarily the app and quietly does nothing while reporting success.

- **The story editor didn't reliably open, and backing out of it landed on the routing list.** It
  was raised as a full-screen cover over that list by an `onAppear` toggle. When the extension has
  already chosen Story, the composer *is* the sheet — no cover, no toggle, nothing behind it.

- **A share that launched Haven didn't load its editor until you switched tabs and came back.**
  The app opens on `onOpenURL`, which fires before the tab content is composed — so the post draft
  was published to a `FeedView` that had no subscriber yet, and the story sheet was presented into a
  view still mid-launch-transition. Both were dropped silently, and switching tabs just happened to
  re-fire the `onAppear` that pulls the draft. The queue now drains only once the tab UI is actually
  on screen, alongside the existing "engine must exist" gate — same rule, same reason: wait rather
  than proceed and lose it.

- **Sharing twice before opening Haven destroyed the first share.** The App Group inbox was a
  single `payload.json` with the media beside it, so the second share's manifest replaced the
  first's and the app only ever saw the last one. It's a **queue** now — one directory per share,
  each with its own manifest and its own media — and the app drains all of them, oldest first.
  Anything that needs a composer stops the drain and keeps its turn instead of racing for one sheet.

- **A shared post now opens Haven's real composer**, so you get the circle switcher, attached music,
  the location toggle and scheduling — the mini form in the routing sheet had none of it. Same for a
  story, which opens the story editor. A **direct message** is still finished in the share sheet
  itself: it's a person and some words, and making you open the app to type them defeats the point.

- **Backing out of the story editor revealed the routing list underneath** — a "where should this
  go?" question about content whose destination was already chosen. Closing the editor now closes
  the whole thing.

- **People with an emoji instead of a photo showed as a letter** in the share extension's picker,
  the one place in Haven that didn't honour it.

- The extension now asks to open Haven via `NSExtensionContext.open` — the supported call — before
  falling back to the old responder-chain walk. Neither is guaranteed (an extension isn't entitled
  to launch its host app), which is why the share is committed to the queue *before* the attempt.

- Conversations are also donated when you **open** a thread, not only when you send. The suggestion
  row is ranked by donation recency, and donating on send alone under-reported the conversations you
  read most.

- **Stock iOS blue icons in Haven's own share sheet.** A `Label`'s systemImage takes the environment
  tint inside a `List`, and a row `.tint` colours the label, not the glyph — so the icons had to be
  tinted directly.

### Changed — Android

- Shared content no longer lands silently in the Circle composer. That made every share a post in
  whatever circle happened to be active, with no way to send it to one person; it now goes through
  the routing sheet, matching Apple.

### Changed — release process

- **The tag now decides the Play track.** A `vX.Y.Z-rc.N` tag is a release candidate and reaches
  testers only — `internal` + closed `alpha` — and **never production**, not via the `PLAY_TRACK`
  variable, not via a manual `play_track` input. A plain `vX.Y.Z` tag goes straight to
  `production`. Previously *every* tag defaulted to `internal`, so shipping a finished release was
  a manual dispatch somebody had to remember rather than something the tag said.

  Apple's rc channel needs no tag at all: Xcode Cloud already ships every push to `main` to
  TestFlight internal. Submitting to the App Store stays a **deliberate, by-hand step** — an App
  Store version can't be reused, rewound or un-submitted, so it should not be a side effect of a
  tag. Promoting a candidate is tagging the same commit without the suffix, so the build testers
  used is the build that ships.

- `Scripts/asc-new-version.mjs --build latest --wait <minutes>` attaches the newest VALID build of
  a version instead of naming a number. Xcode Cloud assigns build numbers from its own run counter,
  so submitting an XCC build meant looking the number up in App Store Connect first — and hitting a
  build still in PROCESSING meant an error rather than a wait.

## [1.2.3] — 2026-07-31

Apple's 1.2.2 never shipped — it was still in review when this was found, so it is re-cut as 1.2.3
carrying everything 1.2.2 had plus the fix below. Android and desktop 1.2.2 ARE published; Android
takes this fix as 1.2.3, desktop's authoring half is called out as still open.

### Fixed — Apple

- **The phone was still heating up on build 414 — the battery fix had a door left open.** Reported
  on two iPhones, one of them remote over the internet.

  1.2.2 made the media-backup drain honour `MediaBackupBackoff` and stop re-arming every 2 seconds
  while holding a `UIApplication` assertion. That was correct, and incomplete: it assumed `backup()`
  records a stall on **every** failure. Three paths return `false` without recording one —

  - `guard dests.count >= 2 else { return false }` in `mirrorSealedAcrossRelays`, reached whenever
    the local plaintext is gone (an evicted blob, or a queue restored from disk in a later session).
    **A device with one relay is the ordinary case**, so this returns false immediately, does no
    network work at all, and records nothing;
  - the same guard on the mirror path inside `backup()`;
  - `guard await healForbiddenRelays(…) else { return false }`.

  A ref that fails without a backoff entry is never skipped by `shouldSkip`, so the next pass takes
  it again, and the re-arm check sees no window and fires 2 seconds later. Forever — and it is the
  *fastest possible* spin, because the failing guard returns before doing any I/O at all. The
  original battery bug, reaching the same end through a door the first fix did not close.

  The stall is now recorded at the **one choke point**: the drain itself, where `ok == false` means
  "reached no destination this pass" by definition. No path inside `backup()` can escape it.

  Two short gaps (5s, 20s) now precede the long ones. Honouring the backoff everywhere would
  otherwise mean a freshly posted story's media waited a full two minutes after one unlucky attempt,
  and "my friends didn't get it for minutes" is what the priority lane exists to prevent. Two quick
  retries cost 2 wakeups; the spin cost roughly 1,800 an hour.

  Apple-only: Android drains through a coroutine `Channel` rather than a self-re-arming timer holding
  a wake assertion, so it has no equivalent loop.

- **The feed recomputed upload state every second, forever, on the main thread.** Reported as a warm
  phone plus "scrolling the You and Circle feeds is a fair bit choppy — obviously some infinite loop
  eating CPU". It was, and it was in the UI rather than the network layer.

  Each of YOUR OWN media posts renders an upload-state cluster inside
  `TimelineView(.periodic(by: 1.0))`. That ticks once a second per visible cell, forever — including
  for posts uploaded weeks ago whose answer cannot change. On the You feed every cell is yours, so
  the app never stopped. And each tick called, per blob:

  - `MediaBackupLedger.hasAnyRemote` / `hasAny` — implemented as `set.contains { $0.hasSuffix("|ref") }`,
    a linear scan of up to **20,000** strings doing suffix comparisons;
  - `MediaBackupQueue.hasPending` — **four** array scans, `pending` bounded at **10,000**.

  Tens of thousands of string comparisons per second, on the thread drawing the feed. That is both
  the heat while idle and the stutter while scrolling — each frame competed with it.

  Three fixes: the ledger keeps a derived `ref → dests` index (the `dest|ref` set stays the source of
  truth and the on-disk shape) making every lookup O(1); the queue keeps a `Set` of pending refs,
  re-derived at `save()` — the one choke point every mutation already passes through; and a post
  already confirmed on a relay someone else can read drops to an hourly tick, because a
  content-addressed blob's verdict cannot be revoked. Posts still in flight keep the 1s cadence the
  progress ring was built for.

  Found while the phone was unavailable for Instruments — it needs to be unlocked and on USB for
  xctrace to attach, and this was reachable by reading the render path instead.

### Fixed — Apple (feed heat and audio)

Measured on a real iPhone with a device log, before and after, rather than reasoned about.

- **Every feed video was decoded TWICE.** `playerFor` cached the player it built inside
  `DispatchQueue.main.async`, so it returned BEFORE the cache was populated; the next evaluation in
  the same pass missed and built a second `AVPlayer` for the same clip. Both stayed alive, so every
  video ran two hardware decode sessions of the same file microseconds apart — audio playing over
  itself ("static sounding"), a mute toggle that could only reach one of them, and 2x decode per
  video. Hardware decode is not CPU time, which is why six Time Profiler runs showed no hotspot while
  the phone got hot. Instrumented: `player #1`/`player #2` for every clip with an identical cache id;
  after, 17 creations and zero duplicates.
- **`FeedStore` published up to 44 times a second.** `lastSendError` accounted for 64 of 66 publishes
  in a 5-second window: `sendIroh` writes it on every send, and with several targets some succeed and
  some fail, so it genuinely alternates nil → error → nil. Every write invalidated every view
  observing the store — the whole feed. It is a debug-panel value and is no longer `@Published`.
  Idle invalidations went from 44/s to 0.4/s, and idle card body evaluations from 21/s to ~0.3/s.
- **Mailbox key parsing ran on the main thread.** `pollMailbox` filters and sorts every key a relay
  lists, and `SharedStore` is a `@MainActor` enum, so thousands of string operations landed on the
  render thread on every poll — 4.4% of all main-thread samples, and the reason it never reached
  idle. The hosted-relay path already did this off-main; the HTTP and iroh paths now match it.
- **The contact fan-out ran every 1.7 seconds** against a due-gate meant for 60s, because a dozen
  event-driven callers bypassed the timer. A floor in `syncWithContacts` fixed it wherever the
  trigger lives: ~300 log lines/min → 31.
- **A video's audio could start in the background**, and a rebuilt player could start silent while
  the speaker icon read unmuted. Both came from the same shift (players are now built when a card
  reaches the centre): the coordinator now owns a per-post player registry and decides audibility in
  one place.
- **Your own reaction count was pink text on a pink capsule** and vanished into it.

### Changed — Apple (PostCard)

- **PostCard was 1,629 lines; it is 407.** Eleven components came out — header, media, reactions,
  comments, comment field, mute button, pin button, masonry tile, placeholder, carousel dots, file
  page — each owning the state it uses. Three of four global stores are off the card entirely, and
  the media (player cache, carousel page, measured width) is a child view, so paging a carousel no
  longer re-renders a header and a comment list.

### Fixed — calls

- **Public STUN is for users with NO Haven relay — full stop.** A circle that runs its own relay
  never hands its callers' addresses to a third party during ICE, even when that relay announces no
  TURN of its own; the relay's path proxy serves the WebRTC hairpin and media rides that.

  Recorded honestly, because this rule was reverted and restored inside one release: a call came up
  connected-with-no-audio and it was attributed to this rule, since it matches the documented field
  failure the old unconditional fallback was written for. But the same build in the same session
  also placed a call that connected and carried audio over the hairpin, so the rule cannot be the
  whole explanation. **That call remains undiagnosed** and wants a capture from both ends.

  What this makes load-bearing is the hairpin: with a fabric and no usable TURN it is the media
  path, not a rescue. Making it establish reliably is the work — not weakening the privacy rule to
  paper over it.

- **The speakerphone toggle did nothing, in either direction.** The audio session is configured
  `.playAndRecord` with `.defaultToSpeaker`, and under that option `overrideOutputAudioPort(.none)`
  does not mean earpiece — it means *the default*, which is the speaker. Turning speakerphone off
  therefore left the route on the speaker, and `syncSpeakerState` then read `.builtInSpeaker` back
  off the route and flipped the flag returned. The category now moves with the override. The
  audio-recovery path had the mirror bug: it reasserted `.defaultToSpeaker` unconditionally, putting
  an earpiece call back on the speaker mid-call.

### Fixed — battery and responsiveness (Apple)

Measured on a real iPhone with `devicectl --console`, 60s steady-state windows, before and after:
**~300 log lines/min → 31**, and `putHello` drops **~180/min → 2.9**.

- **The media-backup drain still spun after 1.2.2's fix.** That fix honoured the backoff but assumed
  `backup()` records a stall on every failure. Three paths return `false` without one — most
  commonly `guard dests.count >= 2` when the local plaintext is gone, which is a device with a
  single relay, the ordinary case. Such a ref never gets a window, so every pass retook it and
  re-armed 2s later, holding a `UIApplication` assertion. Now recorded at the drain itself, where
  `ok == false` means "reached no destination" by definition, plus two short gaps (5s, 20s) before
  the long ones so a transient blip still recovers fast.
- **The feed recomputed upload state every second, forever, on the main thread.** Each of your own
  media posts renders its cluster inside `TimelineView(.periodic(by: 1.0))` — ticking for posts
  uploaded weeks ago whose answer cannot change. Per tick, per blob, it called ledger lookups
  implemented as a linear scan of up to 20,000 strings and a queue check doing four array scans
  bounded at 10,000. That is the choppy scrolling and the warm idle phone. The ledger and queue now
  answer in O(1), and a post confirmed on a relay someone else can read drops to an hourly tick.
- **The contact fan-out ran every 1.7 seconds.** `startSyncTimer`'s 30s heartbeat and 60s due-gate
  govern the timer only; a dozen event-driven callers bypass it. A floor in `syncWithContacts`
  itself fixes it wherever the trigger lives, with user-visible work (invites, new members) still
  greeting immediately.
- **One call frame became ~60 HTTP PUTs.** The live-call lane was handed every circle; a PUT into a
  circle the destination is not in cannot be read by them. Scoped to member circles.

### Fixed — Apple and Android

- **A video story arrived as a spinner that never finished.** Reported straight after the fix above
  shipped: "my friends got my video story right away but theirs have not loaded yet" — ring present,
  "Downloading story…" forever. Caused by that same fix.

  Selecting the playable ref was right; publishing **only** the playable ref was not. Every video in
  Haven travels with its poster still, and three separate things depend on that companion existing:

  - the receiver has something to draw *immediately* — otherwise the viewer shows a spinner for as
    long as the whole clip takes to transfer, which is what "never loaded" was;
  - `enqueueAuthoredMedia` uploads thumbs and posters **ahead of** big blobs, specifically so the
    placeholder-feeding bytes land first — with no poster there are none to send;
  - `dataSaverPrefetchRefs` skips full videos by contract and falls back to the declared poster, so
    under super data saver a poster-less story prefetches **nothing at all**.

  `CameraView.withPosterCompanions` already existed for exactly this — its own doc records the
  camera path having had the identical bug ("no poster was ever published, so recipients and super
  data saver had nothing either"). The library path now goes through it too, in `postStory`, so the
  companions are re-attached after the picker deliberately narrows to one clip.

  The viewer had to change with it. Companions are published poster-FIRST, so `media.first` is the
  poster — the very trap the picker fell into — and reading it would have rendered every video story
  as a frozen frame again. The viewer now resolves through `displayRefs`, requests the poster
  alongside the clip, and draws that still under the progress ring while the video transfers. A
  still with a spinner reads as loading; a black screen reads as broken.

  **Android had the same bug independently, and older.** Its `postStory` publishes a single ref
  through `withThumbMarkers` and never attached a poster either, so an Android video story has always
  arrived poster-less — same spinner, same dead data-saver prefetch. It now routes through the same
  companion step (`LocalMedia.ensurePosterImage`, which already existed), and its viewer resolves
  through `MediaVariants.displayRefs` for the same reason Apple's had to.

- **An Android camera story uploaded the raw recording.** `StoryCameraScreen` read the finished
  capture's bytes and handed them to `LocalMedia.store`, which only hashes, seals and writes — no
  transcode, no companions. The post, DM and share-sheet gallery paths have always gone through
  `prepareVideo`, and iOS's camera optimizes too (`addVideo` → `prepareVideo`), so this was the one
  capture path on either platform shipping video at whatever bitrate the encoder happened to pick.
  It now runs `prepareVideo`, which also mints the poster still from the OPTIMIZED bytes — the still
  a receiver draws while the clip transfers.

  Worth stating plainly since it bounds the fix above: **Android stories are camera-only.** A story
  can only be captured, never picked from the gallery, so the library-selection flow this release
  fixes on iOS has no Android counterpart yet. That is a feature gap, not a bug.

### Known gap — desktop

- **A desktop-authored video story still publishes no poster.** Same bug, but the fix is not the same
  size: desktop has no video-poster generation (its `posterFor`/`stillFrom` stills are a client-side
  render cache, never stored as a media ref) and `post_story` takes a single `Option<String>` rather
  than a companion list. Deliberately not rushed into a release cut. Desktop as a VIEWER is already
  correct — `storyContentNode` resolves through `displayMediaRefs`, so poster-first stories from
  phones render as video, not as a still.

## [1.2.2] — 2026-07-31

macOS 1.2.1 is live and iOS 1.2.1 was in review, so this began as one fix riding its own version
rather than waiting for them. It grew: build 412 is what shipped, and it carries everything below.

### Fixed — Apple

- **The phone ran hot, and never slept.** Reported as "why is my iPhone warm from using Haven for
  1 minute" — and the battery screen said what the minute could not: On Screen 1m, **Background
  4h 45m**, 15% of the day's battery.

  The media-backup drain took a `UIApplication` background-task assertion, ran five jobs, requeued
  whatever failed, and re-armed two seconds later whenever the lanes were non-empty. On a phone
  whose relays are unreachable that condition is *always* true, so it dialled dead destinations
  every two seconds forever, holding an assertion each pass — iOS was never permitted to suspend
  the app. The log is a wall of `relay dial in cooldown` → `backup NO-DEST` → `RETRY … requeued`.

  The brakes already existed and were correct: `MediaBackupBackoff` grows the retry gap from two
  minutes to an hour, and `backup()` records every stall faithfully. But `shouldSkip` had exactly
  one caller — the enqueue sweep in `FeedView` — and the drain that actually runs the work never
  consulted it. Written, and wired to nothing. The drain now filters both lanes through it, and
  re-arms only when something is genuinely due.

- **A video picked for a story published as a photo.** Reported as "it only loads the first frame".
  That was literal. Picking a video does not yield one ref — it expands to its companion group, and
  `composeVideoMedia` builds that group **poster-first** so a feed tile has something to paint
  immediately: `[poster, posterMarker, playable, original?, originalMarker?]`. The story picker took
  `refs.first`, which is the poster: a still of frame 0. The composer was handed an image, and the
  story faithfully published an image. The clip processed correctly and was then thrown away.

  Selection now runs through `MediaVariants.displayRefs`, which drops posters, thumbs, originals and
  markers. Deliberately still ONE ref: `StoryDraft`'s `refs` are separate *clips*, each posted as its
  own story, so passing the whole group would publish the poster as a second silent photo story
  beside the real one.

### Changed — every platform

- **Public STUN is now a last resort, not a default companion.** Requested rule: reach for ICE/Google
  STUN only when no Haven relay is available to the parties on the call.

  | Fabric | TURN                | ICE                                                    |
  |--------|---------------------|--------------------------------------------------------|
  | no     | none / private only | Google STUN (nothing else can pair two home NATs)      |
  | no     | public              | circle TURN + STUN on the same host                    |
  | yes    | any (incl. none)    | circle TURN/STUN if present — never Google             |

  Before, Google was appended whenever no *publicly reachable* TURN was configured — including when
  a perfectly healthy fabric was present. A circle running its own relay still disclosed its callers'
  addresses to a third party during ICE, purely because that relay had no TURN of its own. A fabric
  counts as an available relay even with no TURN, because the relay's path proxy serves the WebRTC
  hairpin: media has a route that never touches anyone else.

  **The risk, stated plainly, because this re-opens a documented field failure.** The Google fallback
  was added after a relay advertised a Docker-internal `turn:172.20.0.2:3478`, leaving both phones
  with one dead server, no STUN, and host candidates only — calls that "connected" carrying zero
  media. The no-fabric half of that case still applies (an unreachable private TURN is not an
  available relay) and is now pinned by a test on every platform so the last resort cannot be deleted
  by accident. The fabric half is a deliberate trade of a limp-through path for not talking to Google
  — sound now in a way it was not when that fallback was written, because the hairpin did not then
  exist.

  Landed on Apple, **Android and desktop in the same wave.** On Android this meant repairing a split
  brain: `FabricIcePolicy` already encoded the rule, but `CallManager.iceServers()` deliberately
  overrode it and added STUN anyway — and `FabricIcePolicyTest` carried a warning saying it pinned
  "the POLICY OBJECT, not the caller's behaviour". A green run proved nothing about any device. The
  policy object now returns the final server plan, the caller only translates it into WebRTC's types,
  and the tests assert what actually ships. Two stale comments went with it: both claimed Android had
  no media hairpin, which stopped being true when `CallHairpin`/`CallMediaBridge` were written — and
  that claim was the stated reason for overriding the policy in the first place.

### Fixed — every platform

- **Automatic media repair announced itself on Apple and desktop.** 1.2.1 silenced this on Android
  and nowhere else — the commit is `fix(android): …`, and its only Apple change was the version
  number — so an iPhone or a Mac still woke people with "X put back the media you asked for" for
  media they had never asked about. A night of repair, a stack of notifications.

  One set was doing two jobs. The held-but-unreadable sweep asks a post's author to re-seal media it
  cannot decrypt — automatically, constantly, with no user involved — and that ask wrote to the same
  `MediaWantedStore` the "Notify me when it's back" button uses. When the author answered, the gate
  (`isWanted`) could not tell a person's request from the plumbing's, so both notified. The manual
  asks are now a separate, persisted subset, and only they are announced; everything else still
  fetches silently, which is the part that matters — the picture appears either way.

  Two more, found on the way:
  - The **"We'll tell you when it's back"** label read the shared set on ALL THREE platforms, so an
    automatically-asked ref promised a notification that deliberately never comes — and hid the
    button that would have earned one.
  - Android's manual set was **in memory**, so a genuine ask quietly stopped earning its
    notification if the app restarted before the author came back online. Authors are offline for
    days; that is the normal case, not the edge one. Persisted now, like Apple's and desktop's.

## [1.2.1] — 2026-07-30

Tester reports across Android and Apple. Nothing in `core/` moved — these are client fixes, so
1.2.1 is re-cut rather than bumped.

### Fixed — Apple

- **The Mac froze for ten seconds at a time while hosting a relay.** Every local-store accessor on
  `RelayHost` had been made `nonisolated` so its file I/O could not land on the thread drawing the
  UI — every one except `localTouch`, which is the most expensive of the set. A TOUCH is the
  mailbox liveness stamp: one `open` + `set_modified` + `close` **per key**, and `touchHeldKeys`
  hands it every mailbox key the device has ever ingested for a circle. On a real hosting Mac that
  is ~12,000 files of synchronous I/O in a single call, on the main thread.

  What hid it is that the caller looks correct: `backfillMailbox` already wraps the whole sweep in
  `Task.detached`. But `SharedStore` is `@MainActor`, so `await SharedStore.touchHeldKeys(…)` from
  a detached task hops straight back onto the main actor and runs the loop there. Sampling the
  shipping build showed the main thread spending 56% of a 15-second window inside it — `open`,
  `fsetattrlist`, `clock_gettime`, `close`, in a tight loop, which is `touch_now` in
  `core/haven-net/src/blobstore.rs` exactly. `localTouch` is `nonisolated` now like its siblings,
  and both call sites run the batch (and the re-PUT of any misses) off-main.
- **An Activity row opened a blank page instead of the conversation (iOS).** Tapping the row asked
  for the Messages TAB and published the thread to push in the same turn, so the tab received a
  push while it was still becoming visible — and SwiftUI dropped it. Instrumented runs show the
  destination being built three times with the correct circle and its body evaluated once against a
  perfectly healthy thread (`known=true msgs=4`), with an empty page and a lone navigation bar on
  screen. Every path that worked — a list row, a pinned tile — pushed while Messages was already the
  current tab; this was the only one that did not. The tab switch now lands before the thread is
  published, and the push itself still waits a runloop turn (both are needed; neither fixes it
  alone).

  Two plausible-looking explanations were wrong and are recorded so they don't get re-derived: the
  thread id was never bad (one run showed `known=false`, which turned out to be stale demo-seed
  data — on a clean container it is `known=true` and still blank), and pinning was not causal, it
  only shifted the timing by changing what the list draws. A first attempt shipped in build 404 on
  the pinning theory and fixed half of it, which is why the report came back.

  `HavenUITests.testActivityRowOpensDMAfterItWasOpenedAndPopped` now encodes the full sequence —
  open the thread, back out, Circle, Activity, tap the row — because the trigger is the *pop*, and
  two manual checks that skipped it both reported a fix that wasn't one.
- **A video in a DM had no sound control.** The full-screen viewer is where a DM's video plays and
  it carried no speaker chip — the clip opened at whatever the global choice happened to be, with
  no way to change your mind without backing out. Adds the same glass chip in the same
  bottom-right position the feed's videos have always had, writing the same persisted preference
  (not a second, viewer-local one), and the running player now follows a mid-video toggle instead
  of reading the volume once at open.

### Fixed — Android

- **The Circle title bar grew to five lines tall.** The circle name was measured first with the
  whole bar to spend, so a long one ("Android Supremacy") took the width and left the connection
  chip a few dp. A squeezed `Text` wraps by CHARACTER: "Connected" came out as `Co / nn / ec / te
  / d`, the bar grew to match, and the add-friend button was pushed clean off the right edge. The
  name is now the elastic element — the status and the button are measured first and always get
  their intrinsic size, the name takes what is left and ellipsizes — and every status label is
  `softWrap = false`, so the bar can run out of room without ever growing downward. Reproduced at
  a raised display size, where it was five lines; now one row on any density.
- **The DM composer left ~80dp for the message you were typing.** Camera, photo, song, voice and
  a ⋮ menu each held a fixed 40dp slot, so most of a phone's bar was spent before the text field
  was measured. They collapse into a single `+` menu (iOS Messages parity), which also carries
  secret and disappearing; disappearing keeps a chip outside the menu because it is the one choice
  with no other trace on screen.
- **System back always closed the app.** Haven navigates by state, not by a fragment stack, so
  every back press fell through to the activity — from a DM, from Settings, from any tab that
  wasn't Circle. Back now walks back: it leaves a conversation, pops a Settings sub-section,
  closes the Connect / Activity / post sheets, minimizes a call (and is swallowed entirely while
  one is ringing), and returns a non-Circle tab to Circle. Circle is the root, so back from there
  still leaves the app — the one case where exiting is right.
- **An invite link needed two taps to open the right screen.** `MainActivity` ran in the default
  `standard` launch mode, so a tapped link started a SECOND activity while the first was still
  alive and composed. Two `RootScreen`s then raced to consume the one pending link from a
  process-wide inbox; the backgrounded one usually won, and the freshly-launched one found the
  inbox empty and opened Connect on its own invite QR. The activity is `singleTask` now (one
  instance, one composition, links arrive at `onNewIntent`), and the link is taken from the inbox
  by `RootScreen` and passed to `ConnectScreen` as an argument rather than read out of a global
  from inside the screen.
- **The Circle feed could come up empty until you left the tab and came back.** `HavenNet.init()`
  runs from a `LaunchedEffect`, so it necessarily lands after the first composition: `CircleScreen`
  had already called `engine.feed()`, caught the not-yet-initialized failure and cached the empty
  result in a `remember` keyed on `feedVersion`/`circlesVersion` — neither of which init moved. The
  empty feed was then final until some unrelated event bumped a version, which is exactly why
  tapping Messages and back again "fixed" it. Boot now bumps both keys on the way out of `init`.

Also: `CallWireTest` had not compiled since hangup frames started naming their session in 1.1.5,
so the Android unit suite was failing to build rather than failing a test. Updated to the current
wire shape (123 tests, green).

## [1.1.5] — 2026-07-27

Responsiveness and reliability pass on what 1.1.4 shipped, plus a night of live testing on a
real iPhone, a real Android phone and the NAS relay. 1.1.4 was pulled from App Store Connect
and the Microsoft Store before general release.

### Fixed

- **The call-media hairpin has never worked, on any platform.** Three faults stacked. The free
  quick tunnel pointed at the media server (`:8674`) instead of the path proxy (`:8675`), so
  `/webrtc/hairpin` AND the iroh DERP fabric were 404 from the internet — the path proxy exists
  precisely to fan one hostname out to all three. The proxy then relayed backend responses
  verbatim, advertising HTTP/1.1 keep-alive while closing after a single request, so cloudflared
  pooled the socket and the next request died with "broken pipe" (this was quietly costing media
  fetches too). And `Sec-WebSocket-Key` was matched against two hand-picked spellings, while Go
  canonicalises to `Sec-Websocket-Key` — capital W, lowercase s in "socket" — so every upgrade
  through cloudflared fell through to `None` and the handler bailed *before writing a response*.
  That last one hid the longest because `curl` and `nc` send the conventional spelling: direct to
  the origin it always returned 101. It worked on the LAN and failed over the tunnel, every time.
- **Five CallKit transactions assumed they would succeed (iOS/macOS).** Mute, answer, decline,
  end and start each requested a transaction and trusted a provider callback that may never
  arrive — no error to catch, no callback to act in, so the tap did nothing. The worst was start:
  no invite was sent at all, leaving "Calling…" forever while the callee's phone stayed silent,
  which is indistinguishable from being ignored. Mute additionally was never a logic bug at all —
  `callButton` is an `Image`, and SwiftUI hit-tests an image against its rendered glyph, so only
  taps landing on the mic strokes counted.
- **A stale hangup could end any call, on every platform.** The handler never checked the session
  id, and Android and desktop did not even send one. Hangups are retransmitted and relays deliver
  them late, so a BYE from a call that ended minutes ago tore down whatever was running.
- **Incoming calls never rang an Android phone.** The call existed only as in-app UI, so it was
  seen only if Haven happened to be open. Adds a call notification channel with a full-screen
  intent and Answer/Decline. Answering also had to bring the app forward first — Android 10+
  blocks background activity starts from a receiver, so accepting there connected a call with no
  UI and no way to end it.
- **"Start over" kept the device identity (Android).** Every store wiped by the reset committed
  asynchronously and raced `Runtime.exit(0)`. Losing the device seed produced a device whose id
  was unchanged while its account was new, so every peer still mapped it to the old account and
  dropped its call frames as forgeries — calls hung up the instant they were answered, and media
  sealed under it could never be opened.
- **Media that could never arrive starved media that could.** The restore queue is serialized and
  insertion-ordered, so one circle's permanently-unopenable backlog owned it and a DM's media was
  never requested at all. Posters also queued behind full-size video, so tiles fell back to
  generating a poster locally — exhausting VideoToolbox decode sessions to redo work the sender
  had already done and shipped.

### Changed

- **"Add — new posts only" is gone.** A circle is keyed by a shared epoch: joining it hands over
  the key that opens the circle's content, and the relay serves that content to any current
  member. The choice could be honoured in the UI and nowhere else. Adding someone to a circle
  shares that circle, and the dialog now says so rather than implying a boundary the design does
  not have.

### Fixed (from the earlier 1.1.5 pass)

- **Answering a call could kill the app (iOS/macOS).** `WebRTCCall`'s constructor called
  `fatalError` when `RTCPeerConnectionFactory` returned no peer connection — and the factory
  returns nil when it REJECTS THE CONFIGURATION, which is not ours to control: `iceServers` is
  built from `haven.fabric.turnUrls`, whatever the circle's relay advertises. One entry WebRTC
  won't parse invalidated the list, and the accept path (`startMesh` → `connectPeerIfNeeded` →
  the constructor) then terminated the process at the exact moment of picking up. A bad ICE
  server should cost you server-reflexive candidates, never the process: construction now tries
  the circle's config, then plain STUN, then no servers at all, and a genuine refusal surfaces
  as a failed call instead of a crash.
- **Desktop calls had no path across the internet.** Desktop's ICE policy still returned an
  EMPTY server list whenever a fabric was configured — host candidates only, which works on a
  LAN and cannot complete a single call between two home NATs. Apple and Android both corrected
  this after the field report where a relay advertised a Docker-internal TURN host; desktop was
  the last platform still doing it. It now derives STUN from the circle's own TURN host and
  falls back to public STUN only when the circle offers no publicly-routable server itself.
- **Posts took minutes to appear after a relay already had them (iOS, Android).** The mailbox
  poll shared its idle back-off with the contact fan-out, and that back-off measures
  INTERACTION, not attention — so reading the feed for 30 seconds without tapping put an iPhone
  on a ×4 multiplier (45s → 3 minutes), then ×10 (7.5 minutes). The two have very different
  costs: the fan-out is hello + roster sealed to every contact and is the thing that cooked
  phones; the poll is one LIST of your own mailbox. The fan-out keeps stretching exactly as
  hard as before. The poll is now capped at 2× base while the app is on screen, and its
  heartbeat no longer quantises the due time up by half its own interval.
- **A compressed video attached to nothing visible (iOS).** Both composer trays required a
  decoded bitmap before drawing anything, with no final `else` — so an attachment with no
  pixels vanished from the tray entirely. A just-encoded video hits that exactly: the poster
  frame is cached as nil whenever `AVAssetImageGenerator` can't cut one, and the thumbnail
  lookup then returns nil now and on every retry. The clip was attached and would have posted
  fine; the composer just never said so. Every attachment now draws a tile — the picture when
  there is one, a labelled glyph when there isn't. The DM tray additionally drew nothing at all
  for files, and only ever showed the FIRST attachment on Android.
- **"Media still loading…" over a photo you could already see.** A post whose bytes were simply
  still syncing fell through to the spinner branch even when its thumbnail was on screen and
  sharp. Progressive loading needs no narration: the thumb sits there and the full-resolution
  image cross-dissolves over it. Android cross-fades now too, instead of cutting.
- **DM threads scrolled themselves to an unusable position (iOS).** An open conversation
  re-scrolled on every change to the ACTIVE CIRCLE's feed — every sync tick, reaction, comment
  and story anywhere in that circle — which is the "it jumps somewhere random every few
  seconds" report. A DM's scroll may now only be moved by that DM. Scrolling also targets a
  zero-height end-of-thread marker rather than the last bubble, whose `.bottom` anchor resolved
  against the composer-sized content inset (and, for a bubble taller than the screen, against a
  frame it couldn't show) and landed short of the bottom.
- **Notification taps could leave a request stuck (iOS).** `@Published` publishes from
  `willSet`, so the handlers that cleared `openThread` / `requestedTab` inline ran before the
  store had written the value and were immediately overwritten. The request stayed pending
  forever: it replayed on every later subscription, and a second tap on the same conversation
  published a value that was already there, so nothing pushed at all. A `dm:` id from a
  notification is also now matched against known threads by PARTICIPANTS, not just by text, and
  an unpopulated circle list no longer reads as "you don't have this conversation".

### Added

- **Android can relay call media when ICE fails.** Apple and desktop have fallen back to the
  `/webrtc/hairpin` WebSocket for hard-NAT peers all along; Android's references to that fallback
  were *comments describing code that was never written*, so an Android leg whose ICE could not
  pair had no media path at all — the call rang, was accepted, and sat in "connecting" forever.
  That is the report about calls to and from Android never connecting. Android now has the full
  bridge: audio on its own `AudioRecord`/`AudioTrack` pair at 16 kHz mono with the platform
  AEC/NS/AGC bound to the record session, video through `MediaCodec` H.264 with the frame's
  rotation applied on the GPU by WebRTC's own renderer, a jitter buffer, and the same
  `[type][seq][ptsMs]` framing Apple uses — byte-for-byte, since all three platforms relay through
  the same proxy socket. It comes up alongside ICE rather than after it gives up, and tears itself
  down the moment ICE recovers so a call never runs two media pipelines at once.
- **Tapping a story's cloud badge opens "which relays hold this" (iOS/macOS).** The badge
  already answered "did this reach a relay?" with one glyph, and looked like a button
  everywhere else in the app. It now opens the same backup-detail sheet as posts and DMs.
- **"Where this is stored" on Android and desktop.** The which-relays-hold-this sheet was
  Apple-only, so on the other two platforms the only way to learn which relay actually had your
  photo was to read logcat or the desktop log. Both now group by relay with a per-relay count
  ("3 of 4") and call out the case where only this device's own in-process relay has a copy —
  which looks backed up and is unreachable to everyone else.
- **Disappearing messages on desktop.** The engine takes `retention_secs` and desktop passed a
  hard-coded `None` for every post and DM, so the same account could set a disappearing message on
  a phone and not on a laptop. Both composers now offer it (per-post in the feed, sticky per
  conversation in a DM, matching Apple).
- **Active-speaker highlight on Android and desktop.** Apple polled WebRTC's audio-level stats to
  show who is talking in a group call; the other two just showed a grid. Same 0.02 threshold and
  two-poll debounce everywhere, so all three highlight the same person at the same moment, and a
  1:1 call skips the polling entirely.

### Fixed (parity)

- **Apple↔desktop hairpin media never worked.** Desktop sent and expected BARE PCM while Apple
  frames every packet `[type u8][seq u16 BE][ptsMs u32 BE]`. Apple dropped every desktop frame as
  malformed and desktop played Apple's header bytes as audio, so the fallback that exists to rescue
  a call when ICE fails only ever worked between two desktops. Desktop now speaks the shared
  format.

## [1.1.4] — 2026-07-26

### Added

- **Peers find each other without a shared relay (all platforms).** A contact holds
  your ACCOUNT id — that is what an invite/QR carries — but has to dial your DEVICE
  ids, and the only two ways to learn those (your signed roster, an invite `?d=`
  hint) both need a route to arrive in the first place. Two peers with no relay in
  common therefore had no route at all, even with both devices online and iroh
  perfectly able to hole-punch between them. Haven now publishes the account →
  device mapping in the public pkarr directory under the account key, and resolves
  it for exactly the members it cannot otherwise reach. The record is a signed
  packet, so only that account can write it; even so it is treated as a dial hint,
  never an authorization — content stays sealed to the circle epoch key and inbound
  frames stay gated on the signed roster, so a stale or hostile record costs one
  wasted connect and nothing more.
- **Deleted relays can be restored (all platforms).** "Delete now" used to be the one
  action with no way back: it drops the relay entry, every circle association and the
  default pick, and a relay is a 64-character node id. Deletions are now archived for
  30 days and offered on the Relays screen; Restore puts the relay back in the circles
  it served.

- **In-app Activity list (all platforms).** A bell with an unread badge opens a
  time-ordered list of everything that happened to you — reactions and comments on
  your posts, new posts and stories, DMs, votes, connections, circle adds, linked
  devices — each row tapping straight through to the exact post, story, or thread.
  Derived entirely from already-synced circle data (a new `activity()` reduction in
  core, one FFI for all four platforms); read-state syncs across your devices
  (`setting:activitySeenAt`), so reading on the phone clears the bell on the Mac.
  No server, nothing new stored remotely.
- **Notification taps open the exact content everywhere.** Sealed push banners now
  carry the post id (including for freshly-authored posts, via a new
  `last_authored_event_id` FFI) plus targeted fetch coordinates; Android and desktop
  notifications finally attach deep links at all (they used to just open the app), and
  a new story route opens the story viewer directly. Circle taps no longer open a
  blank sheet on iOS/macOS.
- **Push→content gap closed.** The Notification Service Extension now *fetches* the
  announced envelope (single targeted GET via a relay directory mirrored into the app
  group) and prefetches thumbnails before the banner is even shown; iOS alert pushes
  carry `content-available` so a backgrounded app wakes and syncs before you open it;
  app-open consumes push hints first — hinted circles and refs jump the queue ahead
  of the general sweep. macOS does the same in-process; Android/desktop prefetch media
  before firing their local notifications.
- **Media rides with its post.** Photos mint a tiny thumbnail that uploads first and
  renders (blurred, correctly sized) the moment the post arrives; fresh posts' blobs
  upload in a priority lane ahead of backfill; authors announce "media landed" to the
  circle so receivers fetch immediately instead of polling; fresh refs retry on a tight
  bounded backoff; chunked (>256 MB) relay downloads resume from the last chunk instead
  of restarting; and placeholders are honest — downloading with progress, "waiting for
  sender", or a terminal state with Retry / Ask-for-it-back.
- **Relay delta-LIST.** Mailbox polls send a content digest; an unchanged mailbox
  answers `204 No Content` instead of re-shipping the full key list every 30–45 s —
  the single biggest recurring radio cost while idle. Old clients/relays are untouched
  (graceful fallback both ways).
- **Full cross-device E2E suite with perf gates** (`soren run Haven e2e`): iOS sim +
  Android emulator + isolated mac stub + Tauri desktop on one fleet, exercising posts,
  stories + captions, DMs, reactions, comments, files, music cards, profile edits, and
  circle membership — asserting convergence on every device, gating on propagation-
  latency budgets, and failing on >2× run-over-run regressions. The mac leg is always
  the isolated QA stub; personal accounts can never be touched.

- **Bundled Cloudflare Quick Tunnel for desktop + haven-relay.** Serious always-on relays can expose
  the HTTP media interface over a free `*.trycloudflare.com` HTTPS URL without port-forwarding or a
  user-installed `cloudflared` CLI. Desktop (Windows/macOS/Linux) ships the official Apache-2.0
  binary via Tauri `externalBin` (`tools/fetch-cloudflared.sh`); `haven-relay` downloads it next to
  itself on first tunnel use. Auto-on when no stable `--http-url` / public URL is set; `--no-tunnel`
  or a manual public URL disables it. Hostname is ephemeral (changes on restart).
- **Video posters ship with every video.** Attaching a video always cuts a compressed JPEG still and
  publishes it alongside the playable clip (`poster:<video>:<image>` marker). Super data saver and
  Places can render the card without downloading the video bytes.
- **Also send original.** Settings ▸ Also send original (or auto-optimize off) keeps the camera file
  as an `orig:` companion next to the optimized playable. Recipients see **Show original** in the
  post menu only when that companion exists.
- **File / folder attachments.** Posts and DMs accept arbitrary files and folders via Files… — they
  are zipped into a `file_` content-addressed blob and shared like any other media.
- **Super data saver** (Settings). No autoplay of video or attached music; feed prefetches posters /
  images / audio / files only; videos download when you tap play.
- **Public relay URL field** on the in-app relay toggle. Point friends at a Tailscale MagicDNS name
  or free tunnel to `:8674` so the plain-HTTP media path works without leaning on iroh for blobs.

### Fixed

- **Field-test wave (mom test): call media, DM/story loss, relay sleep, blur, copy.**
  (1) *Calls connected with zero audio/video*: the dockerized relay advertised its
  container-internal IP as the TURN host (`turn:172.20.0.2:3478`) and the client ICE policy
  made that dead entry the ONLY server (no STUN). Relay now refuses to advertise
  container/unroutable addresses (absent TURN beats poisoned TURN) and warns how to set
  `HAVEN_RELAY_TURN_PUBLIC_IP`; clients derive STUN from the circle TURN host and add
  Google STUN whenever the circle has no public server. Also: renegotiation answers were
  dropped forever after the first negotiation (`remoteDescription != nil` guard), wedging
  video/screen toggles — answers now apply whenever an offer is in flight. The call label
  says "Connecting media…" until ICE is actually up instead of lying "Connected".
  (2) *DMs/stories silently lost*: the pending-epoch buffer dropped the NEWEST envelope
  when full at 512 — and stalled circles sat at cap full of permanently-dead entries.
  Now evict-oldest, plus a drain-time GC for envelopes whose epoch keys are provably
  pruned everywhere. Stories additionally got a 48 h re-seal grace on the author-side
  export purge so a late receiver can still reconcile (display still hides at exactly 24 h).
  (3) *Mac relay slept*: new "Keep this Mac awake while relaying" toggle (idle-sleep
  assertion; honest copy — a closed lid still sleeps).
  (4) *Black letterbox behind post media on iPhone*: the backdrop discarded its decoded
  bitmap and re-peeked an NSCache that iOS purges under pressure; it now keeps the decode
  like the front tile always did.
  (5) Copy: "Ask for it back" → "Notify me when it's back", plus a settings-wide pass
  shortening thirty-odd verbose explainer strings.
- **The 55 GB jetsam kill: overlapping mailbox pulls stacked unbounded ingest batches
  (Apple + Android).** Keys are marked seen when the ingest batch RUNS (inside the engine
  queue), but the fetch-time filter reads the seen-set immediately — so with no
  single-flight guard, every overlapping `pullMailbox` re-fetched the same 200 unmarked
  keys and appended another duplicate batch. Once a legitimate 8-circle re-open dumped
  ~8k keys, polls outran the batches and the queue grew to a jetsam kill in 8 minutes
  (`+7747 next poll` frozen across polls was the fingerprint). Pulls are now
  single-flight with coalescing on Apple and Android (desktop was already serialized
  with inline marks). Also: the re-open-after-key-commit seen-wipe now waits for a
  POSITIVE fully-drained proof (real listing, nothing new, nothing deferred) instead of
  firing on a 10-minute clock — any wipe cadence shorter than the ~30-minute drain kept
  the backlog permanently full, and a transient empty LIST must not fake "drained".
  While a backlog is outstanding the poll scheduler holds base cadence instead of the
  idle stretch, so drains finish in ~30 minutes rather than hours.
- **Three per-call crypto/syscall storms behind the residual Mac heat (Apple + core).** Live
  `sample`s of the b350 direct-run found the main thread split between (1) a Secure-Enclave
  ECIES unwrap on EVERY `storedSeed()`/`currentNodeHex()` call — RelayClients' self-dial
  guard alone called it per relay per circle per poll (now session-cached, invalidated on
  every seed mutation; the seed already lives in engine memory, so no new exposure),
  (2) a full `getifaddrs` interface walk per URL-plausibility check (now 15 s TTL-cached),
  and (3) `http_auth_header` deriving the ENTIRE hybrid post-quantum identity from seed on
  every signed HTTP request — hundreds per poll while draining a mailbox backlog, ~10 GB of
  Malloc-Small churn (the seed→signing-secret derivation is now cached in the FFI; the
  per-request transcript signature is untouched). Also: the activity bell badge offset no
  longer displaces the glyph — the bell stays centered and the count tucks inside the glass
  circle's own padding.
- **The standing every-few-minutes CPU/heat storm on every device (core + Apple).** The
  periodic full-history re-send was cheap for the *sender* since the b344 gen-cache — but
  every *receiver* still decrypted the entire blast under the engine lock just to discover
  it was all duplicates, every cycle, on every linked device and history-sharing peer,
  scaling with total history forever (100%-duty engine batches in the b349 beachball
  sample; the hot iPhone). Two halves: `receive()` now rejects re-delivered key-commit and
  epoch-event envelopes by outer-bytes BLAKE3 hash *before* the engine lock (sealing is
  deterministic, so identical bytes provably can't change state; session-scoped so a
  restart, circle leave, or member purge always re-ingests; MLS/roster/legacy tags still
  process every delivery — they may legitimately park and complete via re-delivery), and
  the sender now skips blasting a circle whose change generation hasn't moved since that
  target last got it (new-this-session targets still get one; the mailbox upload also
  de-duplicated from once per envelope *per target* per cycle to once per generation).
- **Mac beachball, render half: the feed re-paid a full text scan per message per frame.**
  Every SwiftUI invalidation re-ran an NSDataDetector pass per visible post/comment and
  re-spliced URLs out of every DM bubble (`range(of:)` loops) — during a sync burst that's
  the whole feed, several times a second, on the main thread (the 100%-pegged 5-second
  sample). `LinkScanner.urls`/`stripping` are now memoized on the exact body text
  (NSCache, pressure-evicting), so re-renders cost a dictionary hit.
- **Main thread no longer opens sealed call/media frames.** The call-frame preamble
  (unseal + device→account roster resolution) ran on the main actor per frame — and
  frames 30/31/32 burst during media sweeps, so each one parked the UI on the engine
  mutex for as long as any storm held it. The crypto now hops through EngineGate off-main
  and only the dispatch returns to the main actor.
- **Instant beachball on 348: duplicate envelopes were re-fetched forever (all clients).**
  The mailbox marked a key seen only when `receive()` reported a change. Once epoch-key
  convergence made re-applied commits honest no-ops, any circle whose seen-set had been
  wiped by the earlier storm re-fetched and re-decrypted its whole mailbox — 200 envelopes
  a pass, several passes a second, under the engine lock (6.3 GB in 105 s). A processed
  envelope is now marked seen regardless of the result: `false` means duplicate (nothing
  left to extract) or buffered — and the pending buffer is durable precisely so the
  mailbox copy is redundant. Held hellos still keep their slots.
- **Media stuck on "Waiting for sender…" while the blob sat on the relay (core + relay +
  all clients).** A CLI relay's HTTP front door only ever reached clients as a pasted wire
  string — so a relay that gained (or rotated) its free-tunnel URL after adoption left
  every client fetching media from a front door they never learned: the mailbox kept
  flowing over iroh, media silently died cross-NAT (the blob dial drops datagrams), and
  the post metadata arrived without its picture. Relays now publish their CURRENT
  interface (public URLs + token + DERP/TURN, generation-stamped) into their own store
  under `haven/relay/__interface__`, served read-only to the members/fleet they already
  serve — the same audience the sealed frame-19 announces reach. Clients that reach a
  relay over iroh but hold no usable HTTP interface fetch it, adopt it, and re-announce
  frame-19 so members with no iroh reach (including older builds) learn the URL from the
  mailbox. Hooks: mailbox poll's iroh fallback, and the media-restore full miss. The Mac's
  in-process relay publishes the same doc on every front-door change.
- **Activity bell badge clipped by the toolbar capsule (iOS).** The unread count was
  offset outside the button's bounds and the Liquid-Glass toolbar clipped it; the badge
  now sits inside padded headroom within the clip shape.
- **Runaway re-ingest storm on relay-hosting Macs — 16.8 GB of RAM in five minutes, UI
  frozen, and a push-notification firehose at your own phone (core + Apple).** Since
  device-signed key commits, a contact's devices each mint a random key for the same
  (account, epoch) — and BOTH competing commits live in the content-addressed mailbox
  forever. The engine adopted whichever it saw last and reported "state changed" on every
  flip; the Mac's linked-host control-envelope re-offer turned that into an endless loop:
  wipe the circle's seen-set, re-fetch the whole mailbox, re-ingest everything, push-notify
  per envelope, repeat — every poll. Epoch-key slots now CONVERGE deterministically
  (numerically-larger key wins, same rule the writer's own devices use), losing keys are
  retained so content sealed under them still opens, and re-applying a known commit is a
  reported no-op. Same convergence applied to state-blob imports, which used to pin
  whichever key imported first — one of the ways linked devices ended up seeing different
  things. Belt-and-braces on Apple: seen-set wipes are throttled to one per circle per
  10 minutes, mailbox-ingest self-sync pushes are capped at the newest 3 per circle per
  pass, and the fabric-rebind debounce no longer cancels itself under a caller stream.
- **Self-sync over relays was dead on every platform (core + Apple).** Three stacked
  causes, live-fleet diagnosed: the relay authorized only the legacy bare `self/…`
  namespace while every client keys `haven/self/…` (which fell to the catch-all deny);
  the owner gate required `peer == account` while device-id-everywhere makes clients
  connect under device ids; and Apple's self-sync transports were iroh-only, so a relay
  reachable only over HTTP (in-app stub / free-CF / cold DERP) — or wired only via its
  HTTP interface, or hosted in-process — was never used at all. The relay now serves
  `haven/self/<acct>/**` (both transports, one policy) to the account's OWN fleet: the
  account id or any device in its stored account-signed devroster; LIST stays scoped
  per account (F3 — no cross-account enumeration, and the roster gate discloses nothing
  the relay doesn't already store). Apple's `tList`/`tFetch`/`tUpload` climb the same
  ladder as event uploads (own hosted relay's local store → signed HTTP → iroh), and
  HTTP-interface-only relay entries now count as self-sync transports. This is the root
  of "my linked devices each show different things".
- **Circle invites lost in dead hello slots (Apple).** Store-and-forward hellos were
  addressed per DIAL TARGET, so a stale/rotated device id became a mailbox slot nobody
  ever claims — and the invite riding it vanished; hellos are now addressed by the
  member's ACCOUNT hex only (device ids remain iroh dial targets). The receiver used to
  claim-and-mark-seen EVERY hello slot it saw (other members', sibling devices', stale
  ids'), consuming invites on whichever device polled first; it now claims only slots
  addressed to its account or current transport device id, leaves the rest for their
  owners/TTL, skips even fetching them, and runs a one-shot seen repair so previously
  swallowed hellos become claimable. Sender-side dedupe is per (relay, key) instead of
  global, so a relay adopted later still receives standing hellos.
- **Rebuilt QA stubs stop spamming macOS keychain-approval dialogs.** Every re-signed
  `HavenStub` triggered login-keychain prompts because the Secure-Enclave key item (and
  legacy fallback read probes) landed in the file keychain, whose per-binary ACLs never
  match a rebuilt binary. The stub now confines every keychain touch to the
  data-protection keychain (entitlement-governed via its `…qa.stub` access group —
  same storage strength, zero dialogs) and never probes the legacy keychain at all.
  Production keychain behavior is unchanged (migration fallbacks kept).
- **Idle heat, round two (Apple).** The remaining steady-state burners: self-sync no
  longer re-seals + re-uploads an unchanged account state every 2 minutes (content
  hash + 6 h liveness floor; epoch rides the hash so rotations still republish);
  hellos stop re-uploading the same avatar-bearing card to every relay each tick
  (seen-set gate); the 3-minute full-history re-seal now stretches with the idle
  multiplier and reuses cached deterministic bundles; missing-media retries back off
  exponentially (90 s → 6 h, persisted) and park at thermal pressure; background app
  refresh does a slim mailbox pull instead of spinning Multipeer + full fan-out; the
  3-second live-call timer only exists during calls; speaker-stats polling dropped to
  1 s and is skipped for 1:1 calls. A shared ThermalPolicy applies the same gates
  everywhere.
- **Linked devices finally converge (Android + desktop parity wave).** Android marked
  mailbox keys seen *at fetch* — an envelope buffered waiting for its epoch key was
  burned forever (that's "one device gets some things, another gets others"); it now
  marks seen only after successful ingest, persists buffers across process death, and
  runs a one-shot seen-set repair. Android + desktop now route `__hello__` /
  `__relay__` / `__live__` mailbox keys like iOS instead of feeding them to the event
  decoder (desktop was re-fetching + re-crypting every `__relay__` announce on every
  poll, and dropping store-and-forward hellos entirely). Avatar + pinned-DM self-sync
  ported to both; desktop's retention setting used a different CRDT key than the
  phones (seconds vs days) and never converged — it now speaks both. Circle re-adds
  lift the engine tombstone on all platforms. Own-device internet catch-up covers ALL
  circles via round-robin (it silently skipped everything past the first two).
  Android + desktop gained the push-wake leg (authored/ingested events now wake
  recipients' and your own other devices' phones — previously Apple-only).
- **Bonjour teardown crash hardened.** Discovery objects now retire through a static
  main-confined pool that outlives their owner (the `_CFAssertMismatchedTypeID` /
  `CFRunLoopSourceInvalidate` trap fired when a browser freed in the same runloop
  turn as its async cancel), and every transport handoff stops discovery first.
- **In-app copy de-densified everywhere.** Settings/relay/device/onboarding explainers
  across iOS, macOS, Android, and desktop are one plain line each (safety warnings
  keep two), with "Learn more" links into the docs site for real detail — and the
  desktop text claiming linked devices "hold a copy of your master key" is corrected
  (they never do; they get their own revocable key).
- **iPhone scorch + Mac 10 GB / freeze (Apple, field sample build 344).** Live profile: Mac host
  at **237% CPU / 10.6 GB RSS**, path-proxy log **~98% `__live__` LIST** (6–17/sec) while idle;
  main thread still mutex-waiting; Circle Settings sheet re-rendered on every `FeedStore`
  publish. Fix: **no idle live-call HTTP poll** (only while `callInProgress`, one-in-flight,
  ≤6 circles); park Multipeer harder on launch; slow sync/mailbox/media cadences; Circle
  Settings no longer `@ObservedObject`s the full feed store; opening a DM no longer
  `forceSync()`s the world.

- **Mac beachballs / main-thread engine lock (Apple, field sample build 343).** Sample of a
  linked Mac host: main + ~14 cooperative utility threads all stuck in `__psynch_mutexwait` on
  the single `HavenSocial` mutex (2.1–2.6 GB RSS). Root causes: (1) `messages(in:)` re-ran full
  `feed()` decrypt on every SwiftUI chat body paint and per-envelope after mailbox ingest;
  (2) concurrent `Task.detached` workers (receive / exportRecent / exportState / purge) thrashed
  the same mutex while main waited; (3) `reannounceOwnRelay` sealed on main; (4) `syncEnvelopes`
  history resend on main. Fix: `EngineGate` serializes heavy FFI, 2s messages cache + coalesced
  off-main notify/badge side effects, seal/export/receive/persist behind the gate, Mac host
  adaptive stretch + slower catch-up/reannounce while serving.

- **Linked-device matrix harness (iOS sim + Tauri over HavenStub).** `Scripts/qa-linked-device-matrix.sh`
  links desktop to the sim account seed, injects stub HTTP mailbox prefs, and checks that
  photo/video/story posts land on both fleet devices. Stub host can load
  `qa-authorize-members.txt` (account + transport device hexes) so the mailbox is not only the
  host account. Cross-device mailbox still RED when membership auth fails (HTTP REFUSED) — calls
  over internet deferred while QA auth is fixed.

- **Matrix QA now attaches real photo/video media** (DEBUG). iOS `qa-cmd` / Android intents accept
  `media=photo|video` plus optional fixture paths; synthetic JPEG and 1s H.264 fixtures live under
  `Scripts/fixtures/`. Bidirectional `qa-peer-bundle` ingest seeds contacts without HELLO dial.
  Author-side post/story/DM with `img_`/`vid_`/`poster:` refs proven green on sim+emu; cross-device
  restore still needs a membership-authorized relay (stub REFUSED until roster lands).

- **Call shows Connected but no audio (iOS + Android).** ICE can complete while WebRTC playout stays
  off: iOS used CallKit `useManualAudio` with `isAudioEnabled=false` until `didActivate`, and if that
  never arrived (or arrived after media) the UI said Connected with silence both ways. Now enable
  and re-assert the playAndRecord/speaker session on mesh start, ICE connected, CallKit activate,
  and a 1.5s fail-open; mid-call CallKit deactivate recovers instead of muting forever. Android
  re-asserts `MODE_IN_COMMUNICATION` + speakerphone after start.
- **Mac host relay beachballs / multi‑GB RAM (field sample 4.6 GB).** Mesh anti-entropy ran every
  ~20s against every sibling (including dead NAS), listing the full store and pulling ≤256 MB blobs
  into memory; media backfill enqueued whole libraries and sealed them in one drain. Host mesh is
  now ≥5 min, only proven/public peers, ≤24 pulls/pass (mailbox first); media backup drains 5 jobs
  at a time with yields; host backfill caps enqueues; Mac sync interval stretches while serving.
- **Nearby videos abort mid-transfer (Apple).** Multipeer rate-limit (~64 KB/s + one 50 ms retry then
  `break`) finished photos (fit the burst) but **stopped multi‑MB videos after a few chunks**. Media
  serve now waits for tokens (`broadcastWaiting`), raises the bulk ceiling to ~256 KB/s, and soft-
  paces backlog instead of hard-aborting. Resume still fills any remaining holes; resume requests
  are no longer blocked for 25s by the serve throttle after a partial abort.
- **Push banner with empty feed (Apple).** Opening the app after a notification only drained the
  inline push inbox; if those envelopes failed to open (or the body never rode the push), the
  mailbox was never pulled. Foreground now always `syncBecauseOfPush`, and failed inbox opens still
  poll the mailbox.
- **Internet media stuck behind a dead NAS while Mac CF is live (Apple).** Media/mailbox dest order
  preferred pool order, so a long-dead NAS was probed (60s timeout) before the live Mac Cloudflare
  front door. Destinations are now sorted (own host → public HTTP → proven-alive → others), HTTP
  GET timeout is 20s, and all-URL failure records `RelayHealth` failure so dead relays drop down the
  list and stop looking "online" in Storage ("Listed · not proven online").
- **HTTP live-call lane when iroh dial is dead (Android + iOS).** Call invite / accept / SDP / ICE
  frames fan out under `haven/mailbox/<circle>/__live__/<dest>/` and poll every 2s, so two-way
  video still connects on HTTP-mailbox-only relays (HavenStub, free CF) instead of hanging forever
  on `dial backoff … unreachable`. Companion fixes: claim-before-dispatch markSeen (no double
  ingest), never markSeen on put (callee must still ingest), ignore duplicate remote answers once
  WebRTC is stable, and live dests are account + roster only (not every historical device hint).
- **Peer epoch keys update on re-seal (core).** `receive_key_commit` always adopts a successfully
  opened commit instead of first-wins `or_insert`, so a peer who re-sealed the same epoch after a
  membership change no longer permanently bricks reverse-path open of later posts/stories/DMs.
- **Video poster stills are not their own carousel slides (core + all UIs).** The poster rides with
  the video page so super data saver / Places tap downloads and plays the clip instead of zooming a
  dead still.
- **Android targets API 36** (`compileSdk` / `targetSdk`) so Play Console accepts new uploads.
- **Push banners name the real activity.** Reactions no longer say "Posted in the Circle", stories
  say "Shared a story…", DMs show a short message preview (or "Sent a photo" / voice note), and
  comments include a clipped preview. The NSE still only decrypts a tiny sealed JSON — richness is
  decided at send time (`PushBanner`) because the extension has no circle engine. Un-reacts and
  moderation flags stay silent so they don't spam the lock screen.
- **Lock-screen privacy for notification detail.** Senders seal both a full body and a private
  kind-only body; the recipient's NSE picks based on iOS Show Previews and a new Haven setting
  (Settings → Lock screen → Notification previews: full / name+type only / minimal). "When
  Unlocked" never quotes message text on the lock screen.
- **DM push inbox no longer leaves sibling devices with a banner and an empty thread.** Inline push
  events now fan out to the user's other online devices, fetch DM media, recompute DM badges, and
  still pull the mailbox for anything that didn't fit in the push payload.
- **Backup / "which relays hold this" sheet is a half-sheet on iOS** (medium detent), not a full-cover
  sheet — for both feed posts and DMs.
- **Device heat under thermal pressure.** Sync/poll cadence stretches further when the device is warm
  (or super data saver is on), on top of the existing idle multipliers.

### Added (prior unreleased)

- **"Re-optimize media I already shared" now works on Windows/Linux/macOS desktop** (Settings ▸
  Advanced ▸ Storage), alongside "Clean up unused media". The compression work above only ever
  applied to the *next* thing you post; everything already out there stayed exactly as big as it
  was, on every member's device. This is the lever for that: it re-encodes photos you shared, then
  re-shares them, so the whole circle gets the smaller copy. Two clicks by design — the first
  measures and tells you what it found, the second commits — and it does at most 25 items per click,
  can be stopped between items, and refuses to start if the disk is nearly full.
- **Desktop covers photos only, and says so.** The desktop app has no video encoder of its own: all
  its media processing happens in the WebView, whose only encoder produces WebM/VP8 — a format
  iPhone cannot play. Re-encoding a video here would take a clip every member can currently watch
  and replace it with one Apple devices cannot open, which is worse than leaving it alone. So videos
  and voice notes are *counted and reported* ("N videos can't be re-optimized on desktop — use
  Haven on your phone for those") but never rewritten. Photos have no such problem and are handled
  in full.

### Changed

- **Photos and videos you send are much smaller, on every platform.** "Auto-optimize" used to cap
  the *dimensions* of a video and then let the encoder pick its own bitrate — around 8 Mbps at
  1080p, an archival setting applied to something meant to cross a network. That is how a single
  clip reached 320 MB. All three platforms now encode to an explicit 4.5 Mbps, and photos to 1600px
  at JPEG q0.62 (was 2048 at q0.70). Measured on a 1080p test clip: 5.80 MB → 2.30 MB, same
  duration, same resolution, still upright. Android was the worst offender and did not look it: its
  "≈4 bits/pixel, clamped to 2–8 Mbps" formula works out to 8.3 Mbps at 1080p, so it pinned itself
  to the 8 Mbps ceiling on every single clip while appearing to adapt.
- **Videos longer than 15 minutes are refused when you attach them**, rather than quietly costing
  everyone in the circle the storage and transfer. Refused before anything is saved, so a refusal
  can never leave a post carrying an attachment with no video behind it.
- **Optimizing will no longer make a file bigger.** A clip already leaner than the target — a screen
  recording, something re-shared, anything already compressed — was being re-encoded *up* to
  4.5 Mbps, paying bytes and a generation of quality for it. Android now keeps the smaller original.

### Fixed

- **Editing a caption on desktop silently removed the post's photos, for everybody.** An edit event
  carries the post's whole attachment list and replaces what was there — it is not a patch — and the
  desktop client was sending an empty list. So fixing a typo detached every photo on the post, for
  every member of the circle. The current attachments are now re-sent unchanged; only the text moves.
- **Same bug on Android, in direct messages.** The circle-post editor was fixed alongside desktop,
  but the DM editor shared the same underlying call and did not pass anything through — so editing
  the text of a message deleted its photo, its video and its attached song, for both people in the
  thread, permanently. Editing a message's text is now text-only by construction: the attachments
  are read back off the message itself rather than handed over by whichever screen is doing the
  editing, so no editor can drop them by forgetting to mention them. Editing a muted video's caption
  also no longer un-mutes it for everyone.
- **A stopped or out-of-disk re-optimize run now tells you it stopped.** The run ends by
  re-measuring, and re-measuring cleared the message it had just set — so "Stopped." and "not enough
  free space to re-encode safely" were both wiped before they could be read.
- **Android and Windows/Linux desktop kept trying to reach a relay at an address that could not
  work.** A relay hosted inside the app announced every local network address it had. To someone on
  the same Wi-Fi those are the fast path; to everyone else a `192.168.4.x` address is simply
  unreachable — and because that path is tried *first* for photos and videos, every remote member
  paid a connection attempt and a timeout on it, per operation, before falling back to the slower
  route that works. Addresses on a network we aren't on are now discarded when they arrive, and a
  relay with a configured public address advertises only that, instead of appending local addresses
  behind it. (Apple already had this fix.)
- **A photo could stay broken forever on Android and desktop once a bad copy reached a relay.** If a
  relay held bytes that arrived but could not be decrypted, the app stored them anyway, decided it
  now had the media, and stopped asking — so the post kept an empty placeholder with nothing said
  about why. It now checks that a downloaded blob actually opens, says plainly when it doesn't,
  drops the bad copy rather than counting it as the media, and stops re-downloading the same
  unopenable bytes. The author's device still repairs it by re-uploading, and that repair is picked
  up on the next run.
- **Android's "backed up" tick counted this device's own relay.** Copying media to a relay running
  inside your own app is a local file copy that cannot fail, so posts showed a confident tick while
  nobody else could fetch them. It now means a relay someone else can read, with a distinct warning
  state for media that has only reached this device's own relay. (Apple parity.)
- **Dragging a photo or video onto the desktop app sent its GPS location and full resolution.** The
  file picker stripped location and downscaled; the drop target sealed the file straight off disk
  and did neither, so which of two identical-looking gestures you used decided whether your capture
  coordinates went to the circle. Drops now go through exactly the same processing as every other
  import.
- **A relay was frozen to whatever circles its link said on the day you set it up.** It read the
  link once at startup and refused everything else for the rest of its life — including every DM
  conversation, which is created the first time two people message and so can never be in a link
  pasted beforehand. Those conversations therefore had no relay holding messages for later at all:
  a DM only arrived if both devices happened to be awake at the same moment, which looked like
  "received DMs only show up on one of my devices". The link is now a one-time **pairing**: once a
  relay is serving you, your app tells it about new circles as you use them, and it remembers them
  across restarts. Nothing to re-paste.
- **A relay in Docker silently reverted itself on every restart.** `HAVEN_RELAY_LINK` in `.env` was
  re-applied each time the container came up, and it overwrites the saved link — so re-linking a
  relay by hand worked until the next restart quietly undid it, with nothing in the log to say so.
  The link is now applied only on a relay's first run; later starts keep the saved one and say so.
  Set `HAVEN_RELAY_LINK_FORCE=1` for one start to re-link on purpose.

### Added

- **You can now shrink media you already shared, for everyone (Apple, Android).** The compression rewrite only
  ever helped the next thing you posted — everything already out in your circles stayed as big as it
  was, and one device was carrying 1.3 GB with single videos at 320 MB. Settings ▸ Storage now
  measures what you shared before Haven learned to compress properly (or shared with auto-optimize
  off), re-encodes it through the same path new attachments use, and quietly re-shares the smaller
  copy so every member gets the space back. Captions, comments, timestamps and feed order are
  untouched, and only your own posts are eligible — nobody can rewrite someone else's. Measured on
  real files: 305.7 MB → 37.7 MB for a video, 10.9 MB → 2.8 MB across five photos. Runs in bounded
  batches, one encode at a time, and can be stopped mid-run. It sits alongside "Clean up unused
  media" rather than replacing it — the two solve opposite halves of the problem, since cleanup
  frees space on your device only while this frees it for everyone. A re-encode that doesn't come
  back clearly smaller is thrown away and the original kept, and the old copy is never deleted here:
  someone who is offline still has the pre-edit post, so those bytes retire through the ordinary
  weekly sweep instead. On Android the same button re-encodes photos and videos; voice notes are
  already recorded at the target and are left alone.
- **Haven's own relays can answer "where is node X".** Today every connection bootstraps through
  Number Zero's public DNS and relay fleet; if those stop, installs that can't hole-punch stop
  connecting. A node can now publish a short, signed record of where it can be reached to a relay it
  already trusts with its sealed mailbox. The relay is a shelf, not an authority: the record is
  signed by the node itself, so a hostile or seized relay can refuse to answer, but it cannot send
  you to the wrong person. Number Zero stays wired in as a fallback rather than the only path.
- **The push relay is no longer welded in at build time (Apple).** It can be pointed at a different
  server, or switched off entirely, on an already-installed app. With it off, Haven checks for
  messages when you open it and opportunistically in the background — slower, but nothing is lost.
- `docs/DECENTRALIZED-DISCOVERY.md` — the design, a full audit of every third-party dependency in
  the connection path, and the threat model.
- `docs/NOTIFICATIONS-FALLBACK.md` — how notifications work with no push server, and an honest
  account of what iOS will and won't deliver.
- `docs/SUCCESSION.md` — whether Haven could outlive its author, what a successor could and couldn't
  legally do with the source, and a checklist. Not legal advice.

## [1.1.4]

### Fixed

- **iPhone overheats with Haven merely open.** Live-call mailbox LIST no longer runs every 2s
  while idle; linked-device catch-up / media backfill / relay re-announce are slower and
  thermal-gated on iOS; Multipeer discovery parks sooner; serious thermal parks radio work
  until the device cools (push still wakes mailbox).

- **NAS Docker image ships `cloudflared`.** Free trycloudflare auto-tunnel works without
  setting `HAVEN_RELAY_HTTP_URL` (hostname still ephemeral on restart). Optional
  `HAVEN_RELAY_TUNNEL_TOKEN` for named tunnels; `HAVEN_RELAY_NO_TUNNEL=1` for LAN-only.

- **Linked iPhone missing newest Mac messages.** Own-device catch-up was iroh-only every 5 min.
  Host Mac now re-pushes the newest envelopes over silent APNs self-sync as well, on a 90s
  cadence while hosting (3 min otherwise).

- **Friends saw no available relays while the host showed them all enabled.** Frame-19 re-announce
  required proof-of-life within 5 min, so free-CF DNS flaps on the phone stopped re-advertising
  a live Mac host. Relays with a public HTTPS URL are announced even without a recent local proof,
  and announces are also written to the mailbox under `__relay__/` so friends learn them over HTTP
  LIST when iroh dial fails.

- **Notification taps only raised the app.** Local + remote notifications now carry a deep link
  (`haven://m/…` for DMs, `haven://p/…` for posts, `haven://c/…` for circles) so a tap opens the
  interaction directly.

- **Mac TestFlight builds silently had no push entitlement.** Native Mac App Store profiles grant
  APNs under `com.apple.developer.aps-environment`; the Mac entitlements file used the iOS short
  key `aps-environment`. codesign intersects by name and dropped push entirely (profile had
  production push; the signed app had none). Mac entitlements now use the Mac-form key so silent
  content-available pushes can register again.

- **Linked Mac host showed none of mom's activity while the iPhone got every notification.** The
  Mac was serving the relay and held hundreds of sealed DM blobs on disk, but peer epoch keys never
  stuck (or key commits were marked "seen" while still unopenable), so the feed never re-opened them.
  Host mailbox poll now re-tries key commits / device rosters even when already seen, prefers control
  plane before content, and after a newly opened key commit forgets that circle's seen cursor so
  events re-drain. One-shot linked-host repair clears stuck DM seen-cursors. Live contact delivery
  also `syncSelf`s to other linked devices (not only mailbox ingest / own sends), and DM live receive
  updates the Messages badge.

- **Friend DMs reached the host Mac but not a linked iPhone.** Mailbox poll on the host already
  live-delivered over iroh, but a sleeping or cellular phone often missed that path and only learned
  events via HTTP poll (flaky free Cloudflare DNS) or a silent APNs self-sync that only ran for
  *own* sends. Ingested mailbox events now call `syncSelf` so linked devices get the same silent
  push path as self-authored posts.

- **iPhone relay status cycling unreachable ↔ reachable.** HTTP mailbox success never stamped
  relay health (only iroh dial did), and a single dial/DNS blip zeroed proof-of-life. Free
  trycloudflare URL cool-down was also 120s. HTTP LIST/PUT success (and 403 roster refusal)
  now count as reachability; proof-of-life clears only after two consecutive failures; trycloudflare
  cool-down is ~25s and clears when a new public URL is announced. iOS mailbox poll base ~20s.

- **Opening the free Cloudflare URL in Safari often downloaded a 0 KB file.** Browsers hitting
  the media mailbox root (or a mis-hopped path) got `401 application/octet-stream` with an empty
  body — Safari saves that as a download. Path-proxy `/` now serves a small HTML status page for
  browsers; media non-API paths return HTML/text 404 instead of empty 401; proxy hops force
  `Connection: close` and rewrite `Host` so keep-alive cannot strand the next request.

- **Relay media URL vs DERP split (free Cloudflare).** After a fabric rebind, media was re-announced
  as LAN-only (`http://10.x:8674`) while iroh/DERP kept the public trycloudflare URL — so messaging
  and live fabric worked and media never reached remote peers. Media announce now always prefers the
  live tunnel / path-proxy public URL; reattach and health watch heal LAN-only wipes.

- **Cloud sync icon missing when a device knows no relay.** Own posts/stories/DM attachments hid the
  backup indicator unless a relay was already configured, so "not syncing" looked like "nothing to
  report." Always show the indicator; orange ⚠️ when no relay is known or upload is stuck.

- **Previous media never re-uploaded to a newly available relay.** Backfill skipped any blob already
  marked on *any* destination, including this device's own in-process relay (a local file copy).
  Backfill now requires confirmation on a relay others can read. Learning a public HTTPS media URL
  for a known relay also re-triggers event+media backfill.

- **Cloudflared diagnostics.** Free-tunnel logs and DNS checks write to
  `Application Support/Haven/logs/` (`cloudflared-main.log`, `cloudflared-dns.log`); Settings has
  "Open cloudflared logs". Tunnel hard-stop no longer crashes the app; free-tunnel DNS NXDOMAIN is
  diagnosed (system vs DoH) without thrashing restarts.

- **Faster cross-device catch-up while hosting.** Frame-19 reannounce every 45s when hosting (was 3 min);
  media backfill every 60s (was 2 min); post/DM with media publishes device roster and reannounces
  the host relay immediately.


## [1.1.3]

### Fixed

- **Hosting a relay made the app crawl — worst on the machines most likely to host one.** Turning on
  "be my circle's relay" left Haven pegging a CPU core and stuttering constantly; on an M1 Mac it piled
  up hangs within seconds of starting. Two separate causes, both the app doing the relay's file reads
  on the thread that draws the screen. Reading everything the relay had just been handed happened in
  one unbroken burst, so the app froze for as long as it took; and, separately, a routine check of
  which media the relay already held was reading every file in full merely to ask whether it existed.
  The first is now spread across passes and done off the drawing thread; the second asks the question
  without opening anything. A faster Mac hid this rather than escaping it.

- **Uploads that could never finish.** Sending a large photo or video to a relay restarted from the
  beginning every time it was interrupted — and on a phone, leaving the app *is* an interruption. Past
  a certain size nothing could ever complete: each attempt threw away what the last one achieved.
  Uploads now resume where they stopped, so a big video finishes over however many sessions it needs.

- **"Auto-optimize" quietly shipping the original.** If shrinking a video failed for any reason — the
  app backgrounded mid-export, low disk, an awkward recording format — Haven silently sent the full
  original instead, which for a 4K clip is hundreds of megabytes nobody asked to upload. It now retries
  at a smaller size first, and records what it actually sent.

### Added

- **You can see uploads progress now.** A post being stored on a relay showed one motionless arrow
  whether it was moving, crawling, or permanently stuck. It now shows a real progress ring, and turns
  orange when an upload has retried enough times to be worth your attention rather than your patience.

- **`haven-relay version`.** A relay is invisible while it seems to work, so a home server could sit on
  an old build indefinitely with no way to ask what it was running — while the symptoms of an outdated
  relay look like ordinary "my media won't load". It now answers, and the Docker image tracks the newest
  release instead of a pinned pre-1.0 one. Re-running the installer is also a working upgrade now: it
  used to fail outright when the relay was already running, and blamed a missing download for it.

## [1.1.2]

### Added

- **Big videos and photos pick up where they left off.** A large item could take a minute or more to
  arrive, and anything that interrupted it — locking your phone, a lift, a dropped signal, closing the
  app — threw away every byte and started again from the beginning. That is why large media often
  seemed to never load: it wasn't failing once, it was restarting forever, and a video that needed
  longer to arrive than you usually leave the app open could never finish at all. A part-finished
  download now survives being interrupted and even survives closing the app, and when it picks back up
  it asks only for the pieces it is still missing. An item that stopped one piece short now finishes in
  a moment instead of downloading all over again. Half-finished downloads that nothing has fed for a
  day clean themselves up, and a part-finished item is never mistaken for a complete one.

- **Android and desktop no longer load a whole video into memory to receive it.** Both used to hold
  every piece of an incoming item in memory until it was complete, which took several times the item's
  own size — so both refused anything past a fraction of available memory, on Android by silently
  discarding it. On a phone with little memory to spare, large videos weren't slow, they were quietly
  impossible, and nothing said so. Pieces are now written straight to storage as they arrive, so
  receiving a 500 MB video takes no more memory than a small photo and the size limits are gone
  entirely rather than merely raised. iPhone and Mac already worked this way.

### Fixed

- **A notification for a message that never appeared (iPhone, Mac).** You could get a banner for a
  message or a reaction in a conversation you were literally looking at, and the thing itself would
  never show up — not after waiting, not after force-quitting and reopening. A notification that
  arrives while you have Haven open is handled differently by the system than one that arrives while
  it's closed, and on that path Haven showed the banner and threw away the message that came with it.
  Nothing then went looking for it either, so it was simply gone. Notifications now hand the message
  over properly, and any notification prompts a check for anything else waiting — so a message can no
  longer be announced and lost at the same time. Reactions were the most affected: a missed message is
  obvious, while a missed reaction just quietly leaves your copy of a conversation wrong.

- **Setting a relay as your default served one circle and quietly refused the rest.** A relay only ever
  authorized what its link granted, and a link carried a single circle — but the apps let you pick a
  relay as the default for every circle. So you set it once, one circle worked, and every other circle
  was refused permanently. This is what "media isn't on any relay" has usually been: the relay holding
  the bytes and declining to hand them over. Relay links now carry every circle they grant. Existing
  links keep working and don't need re-pasting, and a new link pasted into an older relay still
  authorizes at least its first circle rather than failing outright.

- **Media that never arrived because it kept starting over.** Asking for a large item while it was
  already being sent started a *second* copy of the same transfer, then a third — each competing with
  the last, none of them finishing, so the item never landed and got asked for again. One transfer per
  item per recipient now, and a request that arrives mid-transfer is correctly ignored, because the
  bytes are already on their way. This was fixed on iPhone and Mac in the last release; Android and
  desktop have it now too.

- **Sending a large item no longer queues the whole thing up at once (Android, desktop).** Both used to
  hand every piece of a file to the network as fast as they could produce them, without waiting for any
  of it to actually go out — so sending a 200 MB video meant the entire video sat queued in memory,
  once per device it was going to, and the slower the connection the worse it got. Sending now keeps
  pace with the connection itself: one piece in hand at a time, as fast as the link will actually
  carry it.

## [1.1.1]

### Added

- **A story's song now plays on Android, and is named on desktop.** Attaching a song to a story only
  ever did anything on iPhone — everywhere else the story played in silence with nothing on screen to
  say a song was ever part of it. On Android the song now plays while you watch, the clip goes quiet
  underneath it, and a pill names the track and opens it in your own music app. What Android plays is
  a 30-second preview rather than the record: there is no music library for Haven to drive, so the
  song is matched by title and artist the same way the feed's song chip already does it. Desktop shows
  the same pill and deliberately plays nothing — it has neither a library to drive nor a licence to
  stream, and a player that sometimes made noise would be worse than an honest one that doesn't.
  Song chips across the app also stopped being dead links on iPhone-authored posts, where the song
  arrives as a catalog id rather than a web address.

- **Haven now yields the speakers like a normal app.** Nothing on Android had ever asked Android who
  owned the audio, so Haven would talk straight over a podcast, and a phone call arriving mid-story
  left the music playing underneath it. Every surface that makes noise now takes and gives back audio
  focus on one consistent rule: a call or an alarm **pauses** it and it resumes afterwards, a
  notification **ducks** the music out of the way, and another app taking over playback **stops** it
  for good. Voice messages pause rather than duck, because a ducked voice message is just an
  unintelligible one — they used to claim the speakers and then never react to losing them at all.

### Security

- **Link previews no longer load themselves.** A link in a message used to be fetched by *your* device
  the moment the message scrolled into view, without you touching it. That quietly told whoever sent it
  when you read it and what your IP address is — a read receipt you never agreed to — and pointed your
  device at whatever address they chose to name, including addresses on your own home network that only
  your device can reach. Previews now wait for you to tap **Load preview**, and before anything is
  fetched Haven refuses destinations that are not on the public internet: your own machine, your home
  network, and the link-local addresses used to reach cloud metadata. Redirects are re-checked at every
  hop on Android rather than followed blindly. The 256 KB limit on a page is now real — the whole page
  used to be pulled into memory and only *then* trimmed, so an endless reply could exhaust it — poster
  images are capped and size-checked before being drawn, and the preview cache is bounded instead of
  growing for as long as the app is open. See [`docs/SECURITY.md`](docs/SECURITY.md#link-previews-peer-supplied-urls).

### Fixed

- **A message could reach one of your devices and none of the others.** A friend's DM arrived on the
  tablet and never on the phone. Whoever sends you something dials the devices *their* copy of your
  device list resolves — often just one — and nothing passed it on from there, so anything a contact
  sent stopped wherever it happened to land. Now an event accepted from a contact is handed on to your
  own other devices, and a periodic catch-up repairs messages that were already stranded. Previously
  that catch-up only ran over the local network with a second device physically nearby, so two devices
  on different networks never reconciled at all; on Windows and Linux, which have no local-network
  transport, it never ran. The catch-up is deliberately bounded — at most 50 events per circle, no more
  than once every five minutes, one batch at a time — because it re-seals each message as it sends it.

- **"Keep" on a story re-posted it to everyone instead of keeping it.** It published the story again as
  a permanent post, so it reappeared in the circle feed as something new that everyone saw — which is a
  different thing from wanting to hold on to it yourself. Keep now holds the story on **your own
  profile** past the 24-hour window and leaves everyone else's story row on schedule, keeps the photo or
  video from being cleaned up (otherwise a kept story became a row of "no longer available"
  placeholders), reads Keep/Kept so you can tell at a glance whether it is on, and syncs across your own
  devices per story — keeping one thing on your phone and another on your tablet ends with both kept,
  and un-keeping something is not quietly undone by another device. Windows and Linux had no Keep at all.

- **Story controls that lit up and did nothing (Android).** Keep and Delete showed their press effect
  and then didn't fire: the swipe recognizer covering the whole screen was claiming the touch out from
  under them the moment your finger moved a few pixels. The gestures now sit on the story itself rather
  than above the buttons. Press-and-hold also *closed* the story instead of pausing it; it now pauses
  and reliably resumes. The ✕ was only tappable across the glyph itself and now has a real target.

- **A peer who turned their camera off froze on Windows and Linux.** Desktop never sent or understood
  the "my camera is off" signal, so switching your camera off left everyone looking at your last frame,
  and a phone doing the same left desktop looking at theirs. Both directions now show an avatar.

- **"Message the author" sent something you hadn't written (Android).** It immediately sent the post's
  photos and videos into a new conversation and dropped you into the wrong layout. It now opens the
  conversation with a link to the post waiting in the message box, unsent, for you to write around.

- **Haven links opened a web page inside Haven (Android).** Tapping a shared post link took you to the
  web version, which then offered an "Open in Haven" button that could do nothing — you were already in
  Haven. It now goes straight to the post. Where a link preview is shown, the raw URL no longer sits in
  the message text repeating what the preview card already says.

- **The story editor previewed a song against the wrong part of the clip (Android).** Picking a song
  while the video loop was partway through paired it with whatever moment happened to be on screen, so
  the pairing you approved wasn't the one that shipped. The clip now restarts with the song.

- **Android and desktop caught up with the call, media and roster fixes.** Everything above that was
  fixed on iPhone and Mac now behaves the same way on Android, Windows and Linux: a relay's refusal is
  told apart from an outage and self-heals, a contact's device list is *pulled* from the relay instead
  of only ever being announced (so a call between two home networks connects rather than sitting on
  "Calling"), a device that has fallen behind can re-authorize itself instead of being locked out
  forever, answering a call on one device stops your others ringing and joining behind your back, a
  friend's newly-linked device is recognized as theirs instead of arriving as a stranger, and the
  30 KB device list is no longer re-sent to every relay every couple of minutes.

- **Older media stopped being reachable — it was refused, not missing.** A relay now denies any device
  it hasn't been told about (a hardening fix), and media requests are covered by that check. The apps
  still assumed media was permission-free, so a `403 Forbidden` was handled as a transport error: the
  relay got backed off as if it were down, the fetch fell through to asking the author directly, and
  the whole thing was logged as "NOT FOUND on any relay/S3" — for blobs sitting on that relay's disk
  the entire time. That is why fresh media looked fine (the author was usually online to answer
  peer-to-peer) while anything a few days old appeared to have vanished, and why it followed the
  viewer rather than the network. A refusal is now told apart from an outage, reported as a refusal,
  and self-heals: the device re-publishes its signed roster to the relay that refused it and retries,
  so it authorizes itself instead of waiting for someone to notice.

- **Notifications work again — all of them.** Nothing was being delivered: no DMs, no post alerts, and
  no incoming-call ring, on any network, in any direction. The signed push envelope carried the sender's
  full hybrid post-quantum bundle (3,200 bytes) plus a hybrid signature (3,373 bytes), which base64'd to
  roughly 10 KB against Apple's 4 KB ceiling — so APNs rejected every push with `413 PayloadTooLarge`,
  and the push worker checked the response only for success and threw the reason away. That is also why
  calls never rang and no fallback banner appeared: the VoIP push blew its 5 KB limit, and the alert the
  worker fell back to blew the 4 KB one. The envelope now carries the sender's 32-byte node id — which
  already *is* their Ed25519 public key — and an Ed25519 signature, so the doorbell still proves who
  sent it and still can't be forged by anyone holding only your public key. Message *content* remains
  hybrid post-quantum sealed, as does call signalling, which has no size limit to respect. A test now
  asserts the envelope fits inside the APNs budget, and the worker logs the exact APNs rejection reason
  rather than discarding it.

### Added

- **Android and desktop caught up with tonight's four changes.** "Ask for it back" on swept media,
  private circle nicknames, "Message <author>", host-chosen relay media limits and the three named
  onboarding paths now work the same way on Android, Windows and Linux as they do on iPhone and Mac.
  Two things differ on purpose. The author side of "ask for it back" is *bounded* on the new platforms
  — a ten-minute per-blob cooldown and a one-upload-at-a-time guard — because serving one full upload
  per request, as written, lets anyone in your circle spend your bandwidth by asking repeatedly. And
  the desktop story composer still can't zoom out or rotate (it has no such gesture at all), though it
  now *displays* stories framed that way on a phone correctly, over their own blurred colors.

- **Ask a post's author to put media back.** "No longer available" used to be a dead end: relays sweep
  media on whatever retention their operator set, but the person who posted it almost always still has
  the original. Tapping "Ask for it back" now asks them, and it reaches them whenever they next open
  Haven — even a week later — because the request travels the same store-and-forward path your messages
  do. When they put it back you get a notification that opens the post, and the media fetches itself.
  Media now lasts as long as its author keeps a copy, rather than as long as a relay's retention window.
  Notifications on Android also finally open what they're *about* instead of just opening the app.

- **Your own name for a circle.** Renaming a circle renames it for everyone in it, which isn't the same
  as wanting your own name for it. There's now a private nickname alongside the rename: only you see it,
  it never leaves your device, and the circle's real name is still what everyone else sees.

- **Message a post's author.** A post's ⋯ menu offers "Message <name>": it opens (or reuses) your DM
  with them and carries the post's photos or videos, so they know which post you mean. Not the text —
  quoting someone's own words back at them reads like something they didn't write.

- **Relays can be told how much disk to use.** Hosting a relay meant volunteering your whole drive.
  You can now cap it by age and by size — 30 days and 32 GB by default, generous but finite — and
  either can be set to no limit independently. Undelivered messages are never swept, only media.

- **Onboarding says what each choice does to the device you already have.** Starting fresh, adding a
  second device, and moving your account to a new one used to read as the same kind of thing, with two
  of them tucked away as small links. All three are now named, each stating its consequence.

- **Share a post as a story.** A post's ⋯ menu now offers "Share as story": it opens the usual story
  composer (filters, caption, music, reframing) with the post's photos or videos already loaded, and the
  story it publishes links back to the original. Anyone watching sees a "View post" chip that opens the
  post right there in the app. The story goes to the same circle the post is in, so everyone who can see
  the story can already open the post — and if it's since been unsent, the tap lands on a plain "Post
  unavailable" card rather than doing nothing.

### Fixed

- **The website stops asking to open the Haven app.** Browsing wemiller.com/apps/haven — the home page,
  Features, Docs, Relays, the download section — kept offering to launch the app, including from
  ordinary in-page links like "Privacy" or "Download". Invite and post links now live on their own
  page, and that page is the only one the app answers for; everything else stays in the browser where
  it belongs. Links already shared still work: they open the page, which offers a button to continue
  into the app rather than jumping there by itself.
- **Tall, narrow photos get their blurred backdrop again.** A post whose photo is much taller than it is
  wide sometimes drew against flat grey instead of the soft blurred copy of its own colors. The backdrop
  was built from a 64-pixel thumbnail, and at that size a narrow photo shrinks to a sliver a couple of
  pixels across — stretching that far enough to fill the card produced a layer too large for the graphics
  system to draw, so it drew nothing at all. Narrow photos now use a larger source and a bounded fill, so
  the backdrop renders at every shape. Ordinary photos are unchanged.

## [1.1.0] — 2026-07-17

A reliability and polish release focused on multi-device sync and feed smoothness. Everything here
lands on **every** platform — iOS, macOS, Android, Windows, and Linux — sharing one wire format so
mixed-device accounts stay consistent.

### Fixed

- **A story you post reliably reaches a relay — even if you lock your phone right after.** Posting sends
  the post itself and its photo/video to the circle's relay on two separate paths; the media path wasn't
  as durable as the post path, so backgrounding the app before the upload finished could leave the media
  stranded — friends saw the story but its photo/video "failed to load." The media upload now survives
  backgrounding and app restarts and retries until it's confirmed on a relay. Your own media posts now
  show a small indicator: an up-arrow while it's uploading to a relay, a check once it's safely there.
- **Changes you make on one device now hold on all of them.** Removing a circle member, deleting a
  contact, deleting a circle or DM, editing your profile, and changing your synced settings are now
  reconciled by *who changed it last* rather than *who synced last*. Previously an additive merge
  could re-introduce something you'd removed, and two devices with different profile pictures could
  overwrite each other in a loop — both are fixed, across iOS, macOS, Android, Windows, and Linux.
- **Upgrading a circle no longer leaves a duplicate.** The upgraded circle carries its history, and
  the older circle collapses into it on every one of your devices instead of lingering as a second
  row (any duplicates from before this release heal themselves on the next launch).
- **Story screens and story rings show profile pictures.** A friend's story now shows their real
  profile photo in the header, and every story ring shows the sharer's avatar rather than a frame of
  the story's own media.
- **Direct messages open at the newest message** — including long group threads, which previously
  opened scrolled too far down.
- **Smoother feed scrolling.** The feed no longer jumps around as you scroll. Every card now knows its
  size before its photo or video loads, so nothing resizes underneath you: media dimensions are
  remembered between launches, and posts with a big photo grid, a video carousel, or a shared location
  no longer do heavy work while you're scrolling past them (a location post draws a cached map image
  instead of a live map). A post's song also starts only once you settle on it.
- **Interface polish:** the You tab no longer slides sideways on a scroll, and the macOS You tab opens
  cleanly. The story editor's controls sit properly against the screen edges — they were inset twice,
  leaving a band of wasted space above the top buttons and below the Share button.

### Sound

- **Music plays on profile feeds too.** Scrolling your You tab or a friend's profile now plays the
  centred post's song, and coming back to a circle no longer leaves the feed silent.
- **A camera never plays a post's music.** Opening any camera stops post audio outright rather than
  pausing it — previously it could come back by itself the moment a recording ended. Sheets and
  full-screen views that cover the feed (settings, circle membership, pickers) quieten it too.
- **The ring/silent switch is respected while the app is open**, not only at launch — flipping it now
  takes effect within a couple of seconds. Your own in-app mute still wins until the switch actually moves.
- **The story editor can play your story's sound.** A speaker button previews the story as it will
  actually play: the attached song, or the clip's own audio when there's no song. The clip keeps
  looping either way, and the preview no longer cuts out a moment after it starts.

### Camera & capture

- **Story video capture, rebuilt.** Recording is far more reliable — clips no longer cut off after a
  second, and the shutter keeps working take after take. A long hold **auto-splits** into segments (up to
  15s each), a story caps at **90 seconds** (or 8 segments), and the first shutter action locks the mode
  (tap = photo, hold = video). Recorded clips come out upright with sound, and the progress bar and zoom
  controls behave cleanly across each segment.
- **The camera preserves your framing.** A landscape shot keeps its **full wide frame** in the review
  screen (previewed at its true aspect instead of being cropped into portrait), and the extra space shows
  a full **grid of filters** to pick from.
- **Swipe between people's stories.** In the story viewer, a horizontal swipe jumps to the next (or
  previous) person's stories, instead of stepping through one story at a time.
- **Smoother, steadier feed.** Fast flicks no longer flash a half-loaded image or nudge the scroll
  position around — images fade in cleanly and the feed only redraws when something actually changed.

## [1.0.9] — 2026-07-17

Everything in 1.0.7 (below), plus the fixes for bugs caught right after it was submitted —
1.0.9 replaces 1.0.7/1.0.8 so no one receives the broken build.

### Fixed

- **Removing someone from a circle now sticks.** On an account with more than one of your own
  devices, a member you removed could reappear when your other device's still-has-them state synced
  back — circle membership merged additively, and the removal was only tracked in the app layer, not
  the engine that does the merge. The removal is now a durable engine-level tombstone: a removed
  member is never re-admitted by a sync/restore, and a deliberate re-add clears it.
- **A friend's photos and videos load again.** Posted media is signed and sealed so any authorized
  member opens it, regardless of device state (this changes nothing about who *can* open it — the
  media reference already lives inside the end-to-end-encrypted post, which gates access). Media
  posted before this fix could be stuck unopenable because a stored media file is cached once and
  never re-sealed; the next time each person opens Haven, their own affected media is quietly
  re-sealed and the stored copy is overwritten in place, so a friend's previously-stuck photos and
  videos start loading. The repair runs once in the background, only for media you still hold, and
  retries across launches until every reachable copy is refreshed.
- **"Keep on this device" is now in the post ⋯ menu.** The storage screen advertised it, but it was
  only reachable by long-pressing an individual photo. It now lives on each post's menu (pinning all
  of the post's photos/videos so no cleanup ever removes them), on every platform.
- **"Upgrade this circle" now actually appears on the circles that need it.** The offer was gated on a
  per-device record of which circles you created — which the pre-1.0.7 circles that need upgrading
  never had, so it never showed. It now appears on any circle with no verified owner yet; because no
  device can know who made a legacy circle, the offer is shown to every member and the follow prompt
  names each claimant so members pick the real creator.

## [1.0.7] — 2026-07-16

The security-and-polish release. It re-roots multi-device identity so a **linked device never has
to hold your master seed**, lands the entire machinery for **cryptographic device revocation** —
both rolling out **gradually and per-circle as everyone updates**, with nothing to do and nothing
lost — and builds in a next-generation **MLS-style group-encryption** layer for circles with a
**verified owner** (every circle you make from now on). Plus a real **storage-management** suite and
a fixed metadata leak.

> **Two honesty notes up front, because this is a security product.**
> 1. The new crypto activates **per circle, as every member's devices update** — a coexistence
>    (dual-seal) path keeps un-upgraded peers fully working the entire time. It is not an instant,
>    universal flip.
> 2. The MLS-style group layer is **enabled in this release, but it does not switch your existing
>    circles over by itself.** It applies to circles that have a **verified owner** — every circle you
>    make from now on. Circles you already have don't have one (nothing recorded who created them back
>    then), and an owner can't be added after the fact in a way anyone else could trust, so they keep
>    the encryption they already have — which still cuts off someone you remove. To carry an older
>    circle across, whoever made it offers an upgrade and **each member taps once to follow it**; we
>    show who's asking, because that's a judgement only a person can make. Even on a circle with an
>    owner it turns on only once everyone's devices have updated and joined, and it only ever changes
>    *which key* seals content, never *whether* content is encrypted. Its audit to date is an
>    **internal, AI-driven adversarial review** — 0 critical, 0 high — which is a strong first pass,
>    **not** a formal external audit; an independent cryptographer's review is planned and we don't
>    claim it's done. It is **MLS-*shaped*** (TreeKEM mechanisms on Haven's own post-quantum
>    primitives), **not** RFC-9420 wire-interoperable.

### Security

- **Seedless device linking (seed-drop, D16 Phase 2 · S2–S5 core).** Historically every device you
  linked held a *copy of your account master seed*, so revoking a device was a strong deterrent
  against a **lost/stolen** phone but only advisory against a genuinely **compromised** one (the
  seed it already held kept decrypting, and — because roster authority *was* the account key — a
  seed-holder could re-sign a higher-version device list and re-add itself). This release re-roots
  day-to-day operation on **per-device keys**: a device now authors and signs under its own keypair,
  carries an account-signed `DeviceCredential`, and content seals to authorized **device bundles**.
  A device enrolled through the new **seedless** flow holds *only* its device key + credential and
  **never receives the master seed**; the seed concentrates on one primary device
  (Secure-Enclave-wrapped) plus the existing SE-wrapped iCloud-Keychain escrow. Seedless-enrollment
  onboarding UI ships on **iOS, macOS, Android, and desktop**. See
  [`docs/SEED-DROP-DESIGN.md`](docs/SEED-DROP-DESIGN.md).
- **Revocation becomes a cryptographic cut — content *and* the account-state channel.** With the
  machinery above, revoking a device can now cut it off cryptographically: it is excluded from the
  circle's next key commit (can't read anything posted after) **and** the self-sync key is re-keyed
  on revocation, so a revoked device can no longer read or write your account-state stream
  (profile / contacts / circles / settings). A seedless device also **cannot forge** a higher-version
  roster to re-add itself, because roster authority is the account key it does not hold. Proven by
  the `s5` core test (a revoked seedless device can neither decrypt post-revocation content nor
  re-enter). **Rollout is per-circle:** the account-key seal is retired for a circle only once every
  member's devices affirmatively advertise capability (an all-present-positive signal, never inferred
  from absence), so until your circle finishes updating, revocation stays on the safe dual-seal path.
- **MLS-style group encryption — TreeKEM on Haven's own PQ primitives (D16 Phase 5, enabled for owner-verified circles).**
  A ratchet-tree group layer — propose/commit/welcome, O(log n) path updates, a one-way epoch
  schedule — that adds **post-compromise security** (a device that refreshes its leaf heals a past
  key exfiltration within the weekly rotation, without anyone noticing the compromise), a real
  **forward-secrecy deletion discipline**, and **per-message forward secrecy for DMs** (a sender
  ratchet). It reuses Haven's existing hybrid primitives (X25519+ML-KEM-768 → AES-256-GCM,
  Ed25519+ML-DSA-65) and the shipped epoch/content path unchanged — the tree only changes how the
  32-byte epoch key is *agreed*. It is deliberately **not** RFC-9420 interoperable (every ratified
  MLS ciphersuite is classical; interop would regress the post-quantum posture that is the product's
  headline). The core keying master switch **defaults off**, and the 1.0.7 clients **enable it** —
  but only for circles with a **verified owner**, i.e. circles created from 1.0.7 onward, whose id is
  cryptographically bound to their creator. **Circles that already exist do not switch over by
  themselves:** they have no owner (nothing recorded who created them), and an owner cannot be added
  after the fact in a way other members could trust, so they keep the encryption they already have —
  which still cuts off someone you remove. To carry an older circle across, whoever made it **offers
  an upgrade** and **each member taps once to follow it**; the app shows who is asking, because no
  signature can prove someone created a circle that never recorded an owner — that judgement is a
  person's. Even on a circle *with* an owner the layer activates only **once every member's devices
  have updated and joined** (an all-present/all-joined gate), and until then it stays byte-identical
  to the live sender-keys+epochs path — a device that falls behind reverts within one sync, and it
  only ever changes *which key* seals content, never *whether* content is encrypted. The crypto has had an
  internal, human-directed adversarial code review; a formal external cryptographer's review is
  planned and remains the gate before the core default flips on (design M7). See
  [`docs/TREEKEM-DESIGN.md`](docs/TREEKEM-DESIGN.md).

### Added

- **Storage management** (all clients). A media-cleanup screen lists everything you've downloaded,
  **sortable by size**, with multi-select delete; deleting media **keeps the metadata** and leaves a
  **re-downloadable placeholder**, so a freed photo/video comes back on demand and nothing about the
  post is lost. A per-item **"keep on this device"** pin protects anything you never want auto-swept.
- **Local + relay retention limits, that really delete.** You can cap on-device media by **age and/or
  size**; auto-delete now **actually removes the media bytes** (with a real blob GC — purge-linked
  deletion plus an orphan sweep — on iOS, Android, and desktop), not just hides the post. A relay
  operator can likewise choose **time and/or size** retention (least-space-wins), and expired content
  is genuinely deleted from the log, not merely masked.
- **Video compression** on posting (Android transcode landed; the optimize-vs-lossless toggle carries
  across), so clips cost less storage and bandwidth end-to-end.

### Changed

- **Stories: full cross-platform parity.** Story styling — including **media framing** — now travels
  intact between platforms, and desktop authors styled captions, so a story looks the same to
  everyone regardless of what they're on.
- **Automatic, in-place migration.** Existing accounts, circles, history, and contact with
  un-upgraded (1.0.x) peers are preserved throughout: devices keep reading older account-sealed
  content (dual-open), capability is negotiated peer-to-peer, and every transition is additive and
  gated on a positive signal — there is no flag day, no re-onboarding, and no new identity.

### Fixed

- **Metadata / GPS leak on video closed on the desktop export path** (the last platform where a video
  could carry EXIF/GPS), matching the iOS and Android strips already in place. A fixed
  plaintext-media-cache leak was also closed as part of the blob-GC work.

### Platforms

- **Windows is live on the [Microsoft Store](https://apps.microsoft.com/store/detail/9NKTFH1MF4LM)**
  (x64 & Arm64), no longer distributed via GitHub Releases. Linux GUI + the `haven-relay` daemon
  continue to ship free on GitHub Releases.

## [Unreleased] — 2026-07-14

### Added
- **Live device-to-device delivery** (multi-device D16, Phase 4b). A post authored on your phone now
  lands on your Mac *while you're looking at it*, instead of after its next mailbox poll — up to 120s
  on iOS, 30–180s on Android/desktop. The fan-out lists that reach your contacts deliberately exclude
  you, so your own devices previously had no direct path at all and depended on that poll (or, on iOS
  only, a push wake). Core: `haven_net::livedelivery`; wired on iOS/macOS + Android.
  **Strictly additive:** the mailbox upload is unchanged and unconditional, so live delivery only
  changes how *fast* a sibling learns, never *whether* — a sleeping device, or one you link tomorrow,
  gets exactly what it always did. Attempts are bounded (3s/device, 5s total) so a sleeping sibling
  never holds a post behind iroh's ~30s dial timeout, and never dial our own id (the self-connect
  path-discovery leak) or the account id (a contact handle that resolves to no endpoint under
  per-device transport seeds). Proven both ways in `core/haven-net/tests/live_delivery.rs`: delivery
  with **no relay in the test at all**, and the identical event still arriving when the direct path
  is dead.
- **Blurred media backdrop.** A tall photo or clip no longer sits in a narrow column with the card's
  grey either side — the page now spans the card and a blurred, cropped copy of the media fills the
  letterbox. All four clients. Video uses the poster still, not a second live layer: an `AVPlayer`
  only ever feeds one `AVPlayerLayer` (and `MediaPlayer`/`ExoPlayer` drive one surface), and behind a
  24pt blur a still is indistinguishable from a moving copy at zero extra decode.
- **Carousel for 2–10 items of any aspect**, replacing the two-row masonry for small mixed sets. Pages
  take the tallest item's shape (clamped) so nothing crops; the backdrop masks the difference.
- **Web-routed post links** — `https://wemiller.com/apps/haven/#p/<circle>.<post>`. The payload rides
  the URL **fragment**, so the host never learns which post is being read. Legacy `haven://p/…` still
  parses. Universal Links / App Links now verify against association files at the domain root.
- **Relay nudge**: a dismissable banner (>2 members, no relay of the circle's own) plus a walkthrough
  covering what a relay does and how the encryption works. All clients.
- **Android: inline feed autoplay** with a centered-post coordinator — exactly one player alive at a
  time (measured via `dumpsys media.player`), muted by default, capped at 128 MB per clip.

### Fixed
- **Docs promised an onion/Tor mode we won't build.** The threat model's IP promise ended in
  "optionally fully hidden", carried by a "planned, not yet shipped" opt-in onion mode — repeated
  across five docs, both marketing pages, and the relay README. The research spike (`docs/TOR.md`)
  concluded **don't recommend**: Tor is TCP-only, so iroh's QUIC/UDP data plane and WebRTC calls can
  never traverse it, and the one constructible variant deletes direct P2P and calling. It's now
  recharacterized as evaluated-and-declined, with VPN or a self-hosted relay/discovery node as the
  supported way to hide your IP from a node. Same honest-IP-guarantees discipline as D14 — an honest
  downgrade beats a stale promise.
- **"Never linked to you" was not true, and is gone** (closes audit **F8**). A configured relay
  authenticates each peer by its iroh node id — which *is* that peer's Haven public key
  (`blobstore.rs:537`) — because that check is what enforces circle membership (`:687-709`) and
  self-sync slot ownership (`:742-748`), and what stops a stranger who learns the relay id from
  enumerating a mailbox. So the relay holds `IP ↔ node id` in memory while it moves your bytes.
  `RELAY-AND-DEPLOY.md`'s "ephemeral rendezvous tokens, not Haven public keys" described a design
  that was never built, and contradicted `SECURITY.md`, which was already honest about it. The
  promise across the docs, both web pages and the relay README is now **never logged, never sold,
  never readable** — explicitly *not* "never seen" — and what a relay can't do is tie that key to a
  real-world you, since there's no account, name, email or phone in the system to tie it to.
- **Relay walkthrough claimed adding a member rotates the circle key. It doesn't** — rotation happens
  on removal/block, device-roster changes, and the periodic `rotate_circle`. The old wording implied a
  new member was cryptographically fenced off from earlier posts; they aren't. Traced to
  `GROUP-KEYING.md` saying "every membership change", which is now corrected at the source.
- **Unsent posts no longer clutter the feed** — and the profile/You screen now filters them too, which
  it never did while other people's profiles always had.
- **macOS: real Liquid Glass adopted throughout.** Sheets that rendered grey bands above and below the
  gradient (Connect, Edit profile, circle + circle settings, reaction detail, DM picker, new circle,
  edit post, connection requests, react picker, share screen, add-to-call, video trimmer) now use
  `HavenMacSheet`; ~20 controls that drew a custom circle/pill without a button style — including every
  emoji in the reaction grid — no longer get macOS's rectangular bezel behind them.
- **Reaction menu** no longer hides its quick emoji behind a submenu (a `ControlGroup` collapsed to
  `❤️ 😎 👍 ›` on macOS); the emoji react on tap.
- **macOS audio**: `silent` is device-local again. It was syncing, so a phone's ringer switch dictated
  the Mac's audio and a late-arriving synced value restarted a song you'd muted. macOS now starts
  muted; the async `play()` path got a real generation token; the speaker button was dead while muted;
  a looping video restarted the song on every loop.
- **macOS post camera** now tucks its filter strip behind a toggle, matching the story camera.
- **Desktop**: video backdrops captured a black frame (`loadeddata` fires before a frame is drawable)
  and `requestVideoFrameCallback` never fires for a paused video, so every video backdrop would have
  shipped black; the blur ran on a full-resolution bitmap (1152×2048 → now 36×64).
- **Android demo seed**: friend posts, stories and DM lines never landed — a bare `receive(envelope)`
  can't open an epoch-sealed event without the author's key commit, so the demo feed had 3 posts
  instead of 8 and every seeded reaction was a no-op. Ported Apple's `replayIntoMain`.

### Infrastructure
- **Xcode Cloud** could never build: `apple/*.xcodeproj`, `apple/Generated/` and `*.xcframework` are
  all generated and gitignored, and no `ci_scripts/` existed. Added `ci_post_clone.sh` that restores
  `HavenFFI.xcframework` from a GitHub Release keyed by the `core/` tree hash (build only on a miss),
  then runs XcodeGen — so a full Rust compile doesn't burn the free monthly compute allowance. Set
  `GITHUB_TOKEN` on the workflow to enable the cache.

## [0.1.0-beta.39] — 2026-07-13

### Fixed
- **Android & desktop parity** for the beta.38 relay/media fixes: media now mirrors to (and loads
  from) any reachable relay you share; each device publishes its account-signed roster so a headless
  relay authorizes it; deleted relays stay deleted across your own devices (timestamped last-writer-
  wins on delete-vs-re-add); and large media is sealed file-to-file to keep memory flat. iOS shipped
  these in beta.38 / App Store 1.0.4.

## [0.1.0-beta.38] — 2026-07-13

### Fixed
- **Deleted relays finally stay deleted.** Deleting a relay ("Delete now" or Deactivate) now writes a
  proper, timestamped tombstone that syncs across your devices, and *nothing* auto-resurrects it: a
  passive re-announce from any member (or your own relay reopening) no longer brings it back, a stale
  re-add can't beat a newer delete (last-writer-wins on the actual timestamp), and launch/bootstrap
  adopt skips relays you've deleted. A deleted relay returns ONLY when you explicitly re-add it. (Fixes
  a family of resurrection paths — the "I delete it and it keeps coming back" loop.)
- **Your own relay accepts your own devices.** A headless/NAS relay authorizes members by account id
  from its link, but a device connects as its device id, so it was rejecting your phone's messages
  (`ERR forbidden`). Your device now publishes its account-signed device roster to the relay, which
  verifies the signature and authorizes your device ids — messages and DMs flow through your own relay.
- **Media lands on any reachable relay** (permission-free), so a video reaches a hosted/NAS relay over
  iroh even when a circle's own relays are offline, and replicates from there.

## [0.1.0-beta.37] — 2026-07-13

### Fixed
- **Your own relay rejected your own devices ("ERR forbidden"), and deleted relays kept coming back.**
  Two symptoms, one cause: a device connects to a relay as its DEVICE id, but your devices didn't
  reliably learn each other's device ids, so each rejected the other — and relay-deletion tombstones
  (which ride the same channel) never propagated, so a device kept re-announcing relays you'd deleted.
  Two fixes: (1) each device now publishes its own device roster over self-sync, so your devices
  recognise each other over any relay they share; (2) a **headless/docker relay** — which only knows
  account ids from its invite link and so forbade every device — now accepts an **account-signed device
  roster** written to `haven/devroster/<account>`, verifies its hybrid signature without decrypting
  anything, and authorizes that account's device ids. Requires the relay AND the app on beta.37.
- **Media had nowhere to land is now mirrored to every reachable relay.** Media keys are permission-free
  on a relay (a relay can forbid a device's messages while still storing its media), so media is now
  mirrored to — and fetched from — every known relay, not just a circle's own. A video lands on any
  reachable relay (e.g. a hosted/NAS relay) even when the circle's own relays are offline, and mesh
  sync replicates it onto the circle's relays when they return.

## [0.1.0-beta.36] — 2026-07-12

### Fixed
- **Posting a large video crashed the app instantly.** Sealing a video for backup passed the whole
  sealed blob back across the Rust↔Swift boundary as one contiguous buffer; on a big clip that single
  allocation trapped (`EXC_BREAKPOINT`) and killed the app before anything synced. Large media is now
  sealed **file→file in native memory** (`seal_circle_media_file`, symmetric to the existing decrypt
  path) and streamed to the mailbox in 8 MB windows, so a 600 MB+ video posts without a memory spike.
- **DMs couldn't be stored on a shared relay.** A relay configured with any circle's membership
  rejected every direct-message operation with `ERR forbidden`, because DM conversations are never
  registered on a relay whose host isn't a DM participant — silently breaking offline DM delivery.
  DMs are now accepted from any known member of the relay (strangers still refused; DM bodies stay
  end-to-end sealed, so a relay can carry but never read them).
- **Media had nowhere to land when a circle's relays were unreachable.** Media is now mirrored to —
  and fetched from — any reachable relay you share (bootstrap relays, and any reachable known relay
  when the circle's own relays are down), not only the circle's configured relays. Content-addressed
  media replicates onto the circle's relays via mesh sync once they return.
- **"My posts sync again and again" heat/traffic.** Media that couldn't reach any relay was re-read,
  re-sealed and re-uploaded every 2 minutes forever. It now backs off exponentially (2 min → capped
  1 h) and clears the moment the blob lands anywhere.
- **Post camera: sideways portrait video + rough UX.** Portrait clips recorded sideways because the
  capture rotation was only set when the device rotated; it's now locked from the physical device
  orientation at record-start, so portrait records portrait. The camera is portrait-locked so the
  shutter never moves (always one-hand reachable) while rotating still captures landscape/portrait
  automatically; the filter strip is collapsed by default (a toggle reveals it, clear of the shutter);
  and pinch-to-zoom was copied over from the story camera.
- **One bad relay could stall all the others.** Relay operations now time out (12 s dial / 30 s op)
  so a single hung relay can't freeze the serial fan-out, and a relay is only reported reachable after
  a real operation succeeds — not merely because a client object was constructed.
- **Mac rang nonstop for 20+ minutes.** An incoming-call ring had no upper bound: if the caller's
  fire-and-forget hangup frame never arrived (caller offline, dropped frame, or a stale invite
  copy delivered late through a relay hop), the looping ringtone played forever. Ringing now
  always stops after 60s and records a missed call (a "Missed call" notification is also posted
  when the caller cancels before you answer). Declining can no longer be re-rung by the caller's
  in-flight invite retransmits (ended sessions are tombstoned past the ~30s retransmit burst),
  and group invites now carry a send timestamp — a copy older than 3 minutes never rings.
  The timestamp is a 4th length-prefixed field on frame 21; Android/desktop parsers already
  ignore trailing fields (locked in by new wire tests on both), so cross-platform calls are
  unaffected. Android/desktop should adopt the same bounded ring + timestamp next.
- **Relay-hosting Mac kept the display awake for days.** Hosting the in-app relay held a
  `PreventUserIdleDisplaySleep` power assertion (misleadingly named "Haven media playback") for
  the app's entire multi-day lifetime — observed at 69+ hours. The Mac assertion is now
  `PreventUserIdleSystemSleep` named "Haven relay hosting": the display sleeps normally while
  the machine stays awake to keep serving the mailbox. (iOS keeps the screen-on behavior — the
  app only relays while foregrounded.)

## [0.1.0-beta.35] — 2026-07-12

### Fixed
- **Deleted relays stop returning — now on Android & desktop too.** A relay you deleted came back
  when its owner reopened the app (their device re-announced it, and the old owner-gate reactivated
  it, ignoring your deletion). Relay tombstones are now timestamped last-writer-wins: a deleted relay
  reactivates only on a genuine re-add newer than your deletion, never on a mere reopen; a
  merely-deactivated (not deleted) relay still comes back when its owner re-announces it. The relay
  announce carries an `addedAt` adoption stamp, byte-compatible across iOS/Android/desktop. Legacy
  tombstones are migrated on load. Ships on Apple as 1.0.3; this brings the same fix to Android and
  the desktop app. (Re-delete any already-resurrected relay once on the fixed build; it then stays
  gone.)

## [0.1.0-beta.34] — 2026-07-10

### Fixed
- **Crash + runaway heat: iroh path-management out-of-memory — all platforms.** Upgraded the
  transport stack (iroh 1.0.0 → 1.0.2, QUIC engine noq 1.0.0 → 1.0.1) to fix an unbounded
  path-queue growth that OOM-crashed the app after minutes on a real network and drove the device
  heat. Full detail below (it was diagnosed from an iOS TestFlight crash, but the leaking code is in
  the shared core, so Android, desktop, and the relay all get the fix). See beta.33 notes.

## [0.1.0-beta.33] — 2026-07-09  ·  App Store 1.0.1

### Fixed
- **Crash + runaway heat: iroh path-management out-of-memory (the real dominant cause).** A
  TestFlight crash report showed a Rust `handle_alloc_error`/`rust_oom` abort deep in iroh's QUIC
  path manager — `VecDeque::grow` inside `open_path_on_conn` / `RemoteStateActor::open_path_on_all_conns`
  — i.e. an unbounded queue growing as the connection's network paths flapped open/abandoned, until
  the app ran out of memory (~6.5 min on a real network). This path-flap churn was also burning CPU,
  making it the dominant device-heat source above the UI issues fixed earlier this wave. Upgraded the
  transport stack — **iroh 1.0.0 → 1.0.2** and its QUIC engine **noq 1.0.0 → 1.0.1** — whose changelog
  specifically fixes "unbounded accumulation of pending path responses," `PATH_CIDS_BLOCKED` handling
  for abandoned paths, and an `active_connections` underflow: exactly this failure mode. (The path
  count can't be tuned down as a workaround — iroh ignores `max_concurrent_multipath_paths` below its
  recommended floor of 13 — and disabling multipath would regress cross-NAT media delivery.)
- **Random non-delivery of posts/stories/messages in circles — the big one.** A member could
  silently never receive a post even after everyone handshook and approved. Root cause: the relay
  mailbox marks a content key "seen" (persistently) the moment the bytes are fetched, but the
  buffer that holds an event waiting for its epoch key-commit or the sender's device roster
  (`pending_epoch`) was IN-MEMORY only — killing the app dropped it, and the mailbox never
  re-served the key (deterministic re-seal ⇒ same key ⇒ filtered by the seen-set). Now the buffer
  is **persisted** and re-drained on every key-commit AND roster arrival, and an "unknown sender"
  event (multi-device roster lag) is buffered instead of dropped. The engine state is also saved
  after a poll that only buffered, so nothing is lost on a kill. Regression test added: an event
  received before its key commit survives a restart and is recovered when the commit lands.
- **Media now pulls from the relay's stored copy first.** `requestMissingMedia` fired the direct
  peer-to-peer request alongside the relay restore, so an online author streamed the bytes
  device-to-device even though the relay already held them (heat + bandwidth on both ends). The
  relay/S3/own-store restore is tried first; the direct ask is a fallback only when there's no
  mailbox or the stored copy can't be fetched.
- **Relay copies no longer expire while people still want them.** A post was refreshed against the
  relay's 30-day GC only by its AUTHOR, so an author offline 30 days lost the post for everyone. Any
  active member now TOUCHes the mailbox keys it holds on the daily pass — any online reader keeps a
  post alive.
- **Device overheating — adaptive sync cadence.** The biggest heat source was a 20s timer blasting
  hello+roster to every contact across every circle, re-announcing relays, and mesh-dialing sibling
  relays — every 20s, forever, even with the app open and idle. Both sync timers are now adaptive:
  they keep a cheap heartbeat, but the expensive fan-out/poll only runs when due (20s/30s base,
  stretching to 60s/90s after 3 min idle, 120s/180s after 15 min). Any real activity — foreground, a
  post you send, a message arriving, a peer connecting — snaps the cadence back to tight instantly,
  and pushes still wake the app for immediacy. An open-but-idle phone no longer runs the radio hot.
  Now on **all three platforms**: iOS/macOS, Android (`HavenNet` sync loop), and the desktop Tauri
  engine (`engine.rs` mailbox loop) share the same base intervals, idle multipliers, and reset triggers.
- **No more re-downloading old posts on every launch (device heat).** The mailbox "seen" cursor was
  saved on a 2s debounce and lost if the app was killed during the initial sync burst, so the next
  launch re-fetched + re-verified the whole mailbox. It's now flushed synchronously on
  backgrounding. Idle churn cut too: the 50-event re-seal + media push for nearby catch-up run only
  when a nearby peer is actually connected, and multi-device self-sync is throttled from every 30s
  to ~2 min.
- **Calls: less lag, pixelation, and audio drop-out.** The video encoder now prefers **H264**
  (hardware on Apple) instead of possibly landing on software VP8/VP9 that pegs the CPU and starves
  audio; senders are bitrate-capped and set to **degrade gracefully** (resolution + framerate drop
  together under pressure) so audio wins the CPU fight.
- **A removed relay can be re-added again.** A removed relay could never be re-announced to members
  (the owner-gate can't recognize an external relay's owner). Relay tombstones are now timestamped
  LWW: a re-add newer than a member's "forgot" time reactivates and repopulates across the circle,
  while a stale echo (older adoption stamp) still loses — no zombie relays.
- **The Docker relay keeps its node id across restarts.** Set `HAVEN_RELAY_SEED` (64 hex,
  `openssl rand -hex 32`) to pin the relay's identity independent of the `/data` volume — a
  recreated container no longer mints a new node id the circle has to re-adopt. Documented in the
  compose file + relay README.

- **Choppy scrolling everywhere + device heating within seconds (the real cause).** Every inbound
  network frame — every peer hello, every media chunk — unconditionally set `@Published`
  `internetActive`/`nearbyActive = true` on `FeedStore`, the object the entire UI observes. Because
  `@Published` fires a change notification even when the value is unchanged, this re-rendered the
  WHOLE app on every packet: during a media transfer (~30–80 chunks/sec) or a post-background
  reconnection burst, that's dozens–hundreds of full-UI re-renders per second — the app-wide scroll
  jank and the "warm in seconds" heat, and worse after backgrounding (all contacts reconnect at
  once). Now it publishes only on the real false→true transition. Also: the "last seen" tracker
  serialized its whole dictionary to disk on the main thread on every DM message during a sync
  burst — now debounced to one write per few seconds. (A related earlier fix: the Messages-tab
  unread badge was decoding a full feed per DM conversation on the main thread inside the
  per-refresh hot path — now event-driven only.) Diagnosed from the device's own iroh connection
  trace (which ruled out a networking runaway) plus the frame-dispatch path.
- **Contact avatars re-decoded on every render (main-thread JPEG decode).** `PeerAvatar` looked up a
  contact's avatar in its `body` — which base64-decoded the string and built a brand-new `UIImage`
  (JPEG-decoded on the main thread at draw) on *every* render, for *every* avatar on screen, also
  defeating UIKit's own decoded-bitmap cache. On-device Time Profiler (over USB) showed this as the
  image-decode cost that spiked the main thread during render bursts. Decoded avatars are now cached
  per contact and invalidated when the photo changes — so scrolling and app-switcher snapshots no
  longer re-decode every face. (Profiling also confirmed the post-quantum signing crypto runs 100%
  off the main thread, so it costs battery during sync but never blocks scrolling.)

### Added
- **Storage usage + "keep my own posts".** Settings → Storage shows how much space synced media
  uses on this device. When auto-delete is on, a new "Always keep my own posts" toggle preserves
  your own posts in your feed as a personal archive (a sender-set expiry on your own post still
  applies). The auto-delete footer now states the semantics plainly: it only tidies YOUR view and
  never deletes anything for anyone else.

## [0.1.0-beta.32] — 2026-07-09

### Added
- **DM unread badges (Android + desktop).** Same feature as beta.31's Apple badges, ported:
  Android gets the pill on conversation rows (pinned rows included) plus a Messages tab badge;
  desktop gets it on thread rows, pinned tiles, and the sidebar Messages badge (which previously
  showed the *total* thread count — it now counts conversations with unread). All three
  platforms share the `setting:dmLastRead` self-sync key (JSON map circleId → unix-ms, per-key
  MAX merge), so reading a thread on any device clears its badge on every other, iPhone ↔
  Android ↔ PC alike. Android: `DmRead` (SharedPreferences); desktop: `Prefs.dm_last_read` + a
  `mark_dm_read` Tauri command. No core changes — self-sync keys are opaque pass-through.
  (Landed just after the beta.31 tag was cut, so it ships as its own release.)

## [0.1.0-beta.31] — 2026-07-09

### Fixed
- **Desktop/relay release builds restored.** The beta.30 `release` workflow failed to compile
  (`Engine::moderation_flag` used reqwest's `.json()` but the desktop crate builds reqwest with
  `default-features = false`, no `json` feature) — so the latest GitHub release shipped with no
  Windows/Linux/flatpak/relay assets and the website's download cards sat on "Building…". The
  ledger ping now serializes its body explicitly.

### Changed
- **Website reflects launch.** haven's landing page no longer says "free while in beta":
  iPhone/iPad/Mac are live on the App Store as a one-time $9.99 purchase; the Android and
  desktop betas remain free until they ship. Download section headline updated to match.

### Added
- **DM unread badges (Apple platforms).** Conversations now show an unread-count pill — on the
  row, on the pinned tile's avatar (iMessage-style), and on the Messages tab (which counts
  conversations with unread, not raw messages). Read state is a per-conversation watermark
  (`DMReadStore`): persistent across launches, advanced only by actually opening the thread —
  opening the Messages tab no longer clears anything. Watermarks self-sync across your devices
  with a per-key MAX merge (monotonic, so a fresh device can never "un-read" a sibling), and are
  seeded on first run so pre-existing history doesn't light every conversation up as unread.

## [0.1.0-beta.30] — 2026-07-06

### Added
- **Zero-tolerance terms of use gate (Apple platforms; App Review 1.2).** Agreeing to the terms
  is now the only door into Haven: new users agree as the final onboarding step ("I agree —
  enter Haven"), and anyone already past onboarding — upgraders, restored identities, linked
  devices (whose flows skipped onboarding's last step) — hits a standalone full-screen
  `TermsGateView` on next launch. The in-app summary spells out zero tolerance for
  objectionable content or abusive users, what's never allowed, circle enforcement
  (report/remove/block), and the content-free moderation ledger; the canonical text lives in
  `docs/TERMS.md` (linked in-app). Acceptance is versioned (`haven.terms.acceptedVersion`) so
  materially revised terms re-prompt everyone.
- **Decentralized content reporting (Apple platforms; App Review 1.2).** Haven circles have no
  owner and the developer holds no keys, so moderation belongs to the members: a new sealed
  `Report` event (`core`: `EventKind::Report`, `report()`/`reports()` FFI) broadcasts a report
  to the WHOLE circle — reporter, reported author (full node hex, resolvable even on devices
  that never received the post), offense category, and an optional note that never leaves the
  circle. Reporting hides the post for the reporter instantly and can block the author in the
  same motion; every other member sees a "Reported by …" banner on the post with their own
  actions (hide for me / remove from circle / block). Older clients drop the unknown event kind
  safely. Reports and blocks also append a **content-free entry to a permanent moderation
  ledger** on the push Worker (`/flag`): actor node id × subject node id × action × category —
  identity-vs-identity only, no content, no PII, so abuse patterns (many reporters × one
  identity) stay visible in a system where the developer can see nothing else.
- **Content reporting on Android and desktop (parity).** The same decentralized moderation UI on
  the other two platforms: Android gets a report sheet (`ui/ReportUI.kt` — the five Apple-identical
  categories, optional circle-only note, "also block" toggle, instant local hide via
  `HiddenStore`), the "Reported by …" banner with per-viewer actions (hide for me / remove from
  circle / block), and ledger pings (`core/Moderation.kt`); the Tauri desktop gets
  `report`/`reports` commands, the same report dialog + reported banner in the web UI, and a
  backend-side ledger ping (`Engine::moderation_flag`) that also covers every block. Category
  wording is identical across platforms so ledger entries aggregate cleanly.

### Fixed
- **macOS UI polish sweep: glass, pills, and single surfaces everywhere.** The Mac app's chrome
  had accumulated doubled control surfaces and stock-AppKit artifacts. New design vocabulary in
  `Theme.swift` — `havenGlass` (real Liquid Glass on macOS/iOS 26+, material fallback below),
  circular/pill glass button styles, a one-surface pill text-field style, and a `HavenMacSheet`
  scaffold that runs the brand gradient to a sheet's extreme edges with glass chrome. Applied
  across the app: the report sheet is a hand-rolled column (macOS Form's label column shifted
  everything right), every custom-shaped text field drops the system bezel that doubled inside it
  (onboarding name, edit profile, edit post, connect, restore, location label), the video mute
  chip no longer draws a rectangular bezel behind its circle, sheet toolbar text buttons are
  glass pills, the in-app browser header uses glass chips, and onboarding/terms/edit-profile/
  connect/device-link center a readable column instead of smearing across wide Mac windows.
  iOS keeps its shipped look (all chrome changes are macOS-conditional or visually identical).
- **Call audio has priority: no post music or video sound while a call is ringing, connecting,
  or live (all platforms).** Feed songs, story soundtracks, the DM song pill, and video audio
  could keep playing (or be started by scrolling) over an active call. Now a starting call
  silences whatever is playing immediately — the outgoing dial and the incoming ring both hook
  the same silencer — and every raise-audio path is gated for the whole call lifecycle, at the
  playback chokepoints so no entry point can sneak sound back in: Apple `MusicPlayback`
  play/resume/unduck + `AudioCoordinator` (feed videos stay playing, muted; stories mute their
  clip mid-call via the call state), Android `MusicPlayer.toggle` + `VideoTile` volume (feed +
  stories; recomposes on call state), desktop `syncFeedVideoSound()` (every `<video data-video>`
  forced muted from first ring to teardown). Normal sound rules resume when the call ends —
  nothing auto-blasts; playback comes back through the usual feed interactions.

## [0.1.0-beta.29] — 2026-07-06

### Fixed
- **Media backup no longer re-reads + re-seals whole video files just to discover nobody
  needs them.** `backup(ref:)` (iOS/macOS), `uploadMedia` (Android) and `upload_media`
  (desktop) loaded the ENTIRE media file into RAM — and on Apple re-sealed it (~2× the file
  size transient) — whenever ANY destination relay wasn't yet confirmed in the backup ledger,
  even if that relay was unreachable or in backoff. On macOS this meant a 522MB and a 673MB
  video were re-sealed on EVERY backfill pass (multi-GB RSS spikes every ~2 minutes, forever,
  for relays that were never coming back). The media key is content-addressed (independent of
  the sealed bytes), so all three platforms now run an existence-probe phase FIRST: confirmed
  blobs go straight into the ledger, and the file is only read + sealed when at least one
  destination is actually reachable AND missing it — a relay that's unreachable or inside its
  RelayHealth backoff window is skipped without touching the file. Desktop additionally gains
  the persisted `media-backed-up.txt` ledger it never had (iOS `MediaBackupLedger` / Android
  `backedUp` parity — it used to re-upload every blob to every relay every 2 minutes).
- **The build-174 runaway leak / watchdog kernel panic: dials are now single-flight per peer.**
  The Mac app hit 100% CPU on one background thread with footprint growing ~41MB/s
  (7.0→10.4GB in 88s, jetsam lifetimeMax ~170GB overnight, then a watchdog panic). Symbolicated
  hot stack: `iroh RemoteStateActor::open_path_on_all_conns` — per-peer path-actor churn.
  The iroh trace showed the driver: bursts of 4–10 **concurrent** `endpoint.connect` calls to
  the SAME offline device id, microseconds apart (~9 dials/sec sustained; 6,688 connecting
  events vs 387 connected in one 24-min session). The per-peer dial gate couldn't stop it:
  it's checked *before* `connect` but only updated when a dial *finishes* (~30s for a dead id),
  so every send queued inside that window opened its own doomed `Connecting`, each one churning
  iroh's path machinery. A busy sync cycle fans out dozens of sends per peer (account→device-id
  expansion, restored to FULL device lists by the beta.28 roster healing — why 174 tipped over).
  `conn_for` now holds a per-peer async lock across the dial: concurrent senders queue, then
  either reuse the winner's connection or bail on the gate the winner's failure just set. A
  burst to one dead id collapses to ONE dial (regression-tested: `dial_single_flight.rs`).
  Verified live on the Mac: connect volume dropped ~40× and RSS holds a flat ~1.4GB baseline
  where build 174 grew without bound.

## [0.1.0-beta.28] — 2026-07-05

### Fixed
- **iOS→iOS calls now ring with Haven backgrounded or killed.** The PushKit→CallKit pipeline
  existed end-to-end but four defects kept it from ever ringing in the background:
  1. **The PKPushRegistry was only created in SwiftUI `.onAppear`** — a VoIP push that
     launches a killed app in the BACKGROUND never renders a view, so no registry existed,
     the queued call push had nowhere to land, and the phone stayed silent until Haven was
     next foregrounded. PushKit requires the registry by the end of `didFinishLaunching`;
     it's created there now (synchronously).
  2. **One VoIP token slot per account on the push worker** — every launch of ANY linked iOS
     device overwrote `voip:<nodeId>`, so only whichever device registered last could ring.
     Now a token LIST (like `/register`), `/call` pushes every device, dead tokens pruned.
  3. **A push-rung call could never become a working call.** The VoIP push rings with a
     placeholder session (`push:<caller>`); when the real frame-21 invite caught up it was
     DROPPED (session-id mismatch), and every SDP frame then failed `validSession` — answering
     from the CallKit screen produced a dead call. The placeholder now ADOPTS the real session
     (from the invite, or from the first offer in the answer-before-invite ordering), and
     re-accepts under the real id if the user already picked up.
  4. **`/call` did NOTHING when no VoIP token was registered.** It now falls back to a loud
     time-sensitive alert push through the regular token path ("📞 Incoming call" via the NSE;
     macOS gets its silent-decrypt banner), and both paths carry `apns-expiration` (~45s) so a
     late-delivered doorbell can't ring a call that's already over.
  Requires `cd push && wrangler deploy` + shipping the app to BOTH parties.
- **The same notifications fired again and again (all platforms).** Three compounding causes:
  the local-notification dedupe set was in-memory only (every relaunch forgot what was already
  notified — and at its 3000-entry cap it wiped ENTIRELY, re-arming every past banner);
  "notify newest" fired on ANY change in a circle (history backfill, key commits, epoch-
  rotation re-seals of old events) and then described the newest EXISTING message rather than
  what actually arrived; and Android/desktop had no dedupe at all (desktop notified per
  changed envelope, including key commits). Now: the dedupe store is PERSISTED on every
  platform (iOS/macOS `haven-notified.txt`, Android prefs, desktop `notified.txt`), caps trim
  instead of wiping, and a banner only fires when the circle's newest inbound item is
  genuinely fresh (< 10 min) — an old message resurfacing is never worth a banner. (The
  roster-revocation fix above removes the biggest churn *generator*; this makes banners
  immune to any future re-delivery/churn source too.)

### Added
- **Relay mailbox garbage collection (all platforms + CLI relay).** Deterministic sealing
  stopped NEW duplicates, but the thousands of legacy ones (a random-sealed copy of every
  event per backfill run, plus a full stale copy per epoch rotation) sat on every relay
  forever: each 30s poll re-LISTed ~6,700 keys (~700 KB per list from a remote relay) for an
  88-event circle, and mesh sync re-circulated the dead entries between siblings for good.
  Entries are opaque to the relay and live keys are never re-PUT (`has()` hits skip the
  write), so a bare mtime TTL would have eaten live history, and a deletion on one relay
  would be resurrected by the next anti-entropy pass. Shipped as three cooperating parts
  (`core/haven-net/blobstore.rs`, identical over iroh `haven/blob/1` and the HTTP relay):
  1. **`TOUCH` (iroh `T` / `POST /t/<prefix>`)** — daily, each member sends the refs of every
     envelope it can deterministically re-seal (own events + current key commit + roster) in
     ONE batched request per relay; the relay bumps those entries' liveness (mtime) and
     replies with the keys it lacks, which the client re-PUTs — the refresh doubles as repair
     and self-heals a relay that GC'd a long-offline member's history. `HAS`/`HEAD` hits
     refresh too; the host's own in-process relay is touched locally (no iroh self-dial).
     Client wiring: iOS/macOS `SharedStore.refreshMailbox` off the daily backfill gate (now
     also re-checked on the 30s poll timer so an always-open Mac refreshes without a
     relaunch), Android `refreshMailboxKeys` off the persisted daily gate, desktop
     `Engine::refresh_mailbox` off a new daily gate in the 15s loop.
  2. **TTL sweep** — every relay host (CLI daemon, in-app RelayHost on iOS/Android/desktop,
     `BlobServer`) hourly deletes `haven/mailbox/**` entries idle > 30 days plus abandoned
     `.part` files; media and self-sync slots are never swept. A `.haven-gc-enabled` marker
     delays the first deletion by 48h so members get a refresh cycle in before anything goes
     (pre-GC stores have ancient mtimes on LIVE entries too).
  3. **Age-preserving mesh sync (`AGES` verb)** — anti-entropy now exchanges `(key, idle-age)`
     pairs, skips mailbox entries already past the TTL (never resurrect what's dying
     elsewhere), and back-dates pulled files by the peer's age, so dead entries age
     monotonically across the whole mesh instead of ping-ponging back with fresh mtimes.
     Falls back to plain `LIST` (everything fresh) against a pre-GC sibling.
  Net: legacy duplicates, stale-epoch copies, and retention-expired events all age out of
  every relay within one TTL; the 30s poll LIST shrinks to the live set. Authorization
  unchanged in spirit: TOUCH follows PUT's membership rules, broad prefixes are refused to
  non-relays, and a member can only keep entries alive — deletion is purely the relay's local
  TTL policy. Accepted tradeoff (documented): an author inactive on ALL devices for > 30 days
  drops off relays until their next refresh re-PUTs everything; devices stay the source of
  truth. Also pinned `RUSTC` in `android/build-rust.sh` (parity with the Apple script) so a
  Homebrew rust can't shadow rustup's Android-capable toolchain.

### Fixed
- **Own-device revocation flip-flop — posts not syncing between your own devices (all
  platforms).** The account's device roster had the Mac's own device id stuck in `revoked`
  (observed live: roster v54 with the Mac's transport id revoked), so siblings never dialed it
  directly and every roster exchange re-signed + rotated every circle's epoch (`my_epoch: 76`
  on an 88-event circle). Two compounding bugs: (1) `DeviceList` union-merge treated `revoked`
  as grow-only, so the explicit re-authorization `register_device` performs at launch was
  re-tombstoned by ANY older roster copy — un-revocation could never propagate. Where two
  account-signed copies now disagree about a revocation, the strictly-newer version's verdict
  wins (replays have lower versions; ties keep the revocation). (2) iOS and Android
  self-registered BEFORE importing persisted state, so the imported (higher-version) roster
  clobbered the registration every launch — registration now runs after import (desktop already
  did). Ship to ALL your devices: an un-updated device keeps re-adding the tombstone.
- **Deleted/deactivated relays stop resurrecting (all platforms).** Every member re-announces
  every relay it holds proof-of-life for, and ANY announce reactivated a deactivated/forgotten
  entry — so a relay you deleted but which is still running somewhere (an old docker container)
  bounced back within one sync tick, forever. Reactivating an existing tombstoned entry now
  requires the announce to come from the relay's OWNER (the announced id is one of the sender's
  authorized device ids, or their account id for legacy account-id relays), authenticated via
  the sealed announce's verified sender (new FFI `open_circle_media_sender`). Third-party
  echoes of a tombstoned relay are dropped; brand-new relays still auto-pool.
- **Posts now carry their key commit to the mailbox.** With the full-history backfill throttled
  to daily, a relay-only peer could receive an event sealed under a fresh epoch long before the
  commit that opens it (it sat undecryptable in the pending-epoch buffer). Every authored event
  now uploads the epoch head (roster + current key commit, new FFI `export_epoch_head`)
  alongside it — near-free, since the commit is cached until the epoch/recipient set changes
  and the persisted seen-set dedupes.
- **30-second cold start on the circle feed, root-caused and fixed (all platforms).** Two
  compounding bugs:
  1. **The mailbox seen-set wasn't persisted.** Every cold start treated the ENTIRE relay
     mailbox as new and re-downloaded + re-verified every envelope — a real circle had
     accumulated ~6,700 mailbox entries for 88 events, so launch burned 30+ seconds on hybrid
     signature verification of duplicates the engine then discarded. The ingestion cursor now
     persists across launches (iOS/macOS `haven-mailbox-seen.txt`, Android
     `haven_mailbox_seen.txt`, desktop `mailbox-seen.txt`), and a key is only marked seen once
     its bytes are actually in hand (a failed download is retried instead of skipped forever).
     Identity reset/adoption wipes the cursor. (First launch after this update re-scans once to
     seed the cursor; every launch after that is fast.)
  2. **The mailbox grew without bound.** Backfill re-sealed the whole history on every launch
     (iOS) / every 2 minutes (Android), and every re-seal produced fresh random bytes — so the
     content-addressed mailbox key was NEW each time and relays accumulated a copy of every
     event per run. Event envelopes now seal **deterministically** (salt is a PRF over the
     plaintext keyed by the epoch key; nonce derived from the per-plaintext event key; the
     hybrid signature was already deterministic), so a re-seal reproduces byte-identical
     envelopes, the relay's `has()` dedupe finally works, and the mailbox stays at one entry
     per event per epoch. An edit derives a fresh salt → fresh key + nonce, so AES-GCM never
     reuses a (key, nonce) pair across distinct plaintexts; no wire change — old receivers just
     read the carried salt/nonce. Key commits (necessarily KEM-random) are cached — and
     persisted with the engine state — per recipient-set, so backfills reuse the same commit
     bytes until the epoch/membership/device set actually changes.
- **Full-history event backfill throttled to daily.** New-relay adoption and share-history
  still backfill immediately; the launch-time (iOS/macOS) and 2-minute-tick (Android) sweeps
  now run at most once a day — the re-seal is a hybrid signature per event, and the daily run
  is a cheap no-op thanks to the persisted seen-set + deterministic envelopes. The iOS re-seal
  also moved off the main actor.
- **`iroh-trace.log` capped.** The connection-diagnostic log grew unbounded (370MB observed on
  a daily-driver Mac) and re-opened the file for every line; it now starts fresh past 16MB and
  reuses one handle.

## [0.1.0-beta.27] — 2026-07-05

### Fixed
- **The frozen feed, root-caused and fixed (iOS/macOS).** "Swiping on a tall video post doesn't
  scroll" turned out to be TWO bugs, both reproduced and verified fixed live in the simulator:
  1. **A main-thread DEADLOCK froze the entire app** — not just scrolling. The sync-status badge
     re-evaluates on a schedule and synchronously read `MCSession.connectedPeers`, which
     dispatches into MultipeerConnectivity's internal queue; while the nearby mesh was busy
     (media chunks streaming — e.g. right after a video post, or whenever your Mac's Haven is in
     Bluetooth range) that read deadlocked against MC's receive thread. The app kept rendering
     its last frame but every touch was dead. Peer state is now cached from the session delegate
     (the sanctioned path); nothing touches MCSession synchronously anymore.
  2. **The video scrub gesture blocked the feed's scroll pan** — on iOS 26 a SwiftUI DragGesture
     on the video surface eats vertical swipes even when attached as `simultaneousGesture`
     (bisect-verified). The scrub is now a UIKit pan recognizer on the player surface that
     REFUSES to begin unless the movement is horizontal — vertical swipes never engage it, so
     the feed scrolls natively; horizontal drags scrub exactly as before (verified: scrub bar
     live in the same session where vertical swipes scroll).

## [0.1.0-beta.26] — 2026-07-04

### Fixed
- **Vertical swipes on tall videos scroll the feed — for real this time (iOS/macOS).** beta.25
  fixed the scrub gesture but missed the second eater: hold-to-pause was a HIGH-PRIORITY
  long-press whose sequenced drag claimed the whole swipe whenever your finger rested for 0.2s
  before moving — exactly how deliberate scrolls start. It's now simultaneous (video posts have
  no context menu to out-prioritize); a slow scroll may briefly pause the video and it resumes
  on lift.
- **Dead relays stop resurrecting and posing as "Reachable" (all platforms).** beta.22 made every
  member re-announce every relay id they'd ever learned — an echo chamber: dead relays came back
  on every device (receivers deliberately reactivate announced relays), media uploads kept
  burning timeouts against ghosts ("keeps reporting it is sending"), and the storage UI showed
  green for anything that simply hadn't been dialed lately. Announces are now LIVENESS-GATED:
  a device only re-announces relays IT completed a successful operation against within the last
  5 minutes (plus the relay it hosts) — a live relay is re-proven constantly by the mailbox
  poll, a dead one goes silent everywhere and ages out. The relay list now shows "Reachable"
  only with a proven success in the last 15 minutes ("Not verified recently" / "Unreachable —
  retrying" otherwise), so the status finally reflects reality. Forgotten relays stay forgotten.

## [0.1.0-beta.25] — 2026-07-04

### Fixed
- **Tall videos no longer block feed scrolling (iOS/macOS).** The video scrub drag was attached
  at high priority, so it won the gesture race for ANY movement — including vertical — and its
  internal "is this horizontal?" bail-out couldn't give the gesture back: a tall video was a
  wall you couldn't scroll past. Now: vertical swipes always scroll the feed (single-video
  scrub is simultaneous + axis-checked; the carousel scrub strip is capped at 96 pt instead of
  a third of the video), horizontal swipes page a carousel or scrub, and the full-screen viewer
  pages off video items (its full-area scrub used to eat every horizontal drag) while
  swipe-down-to-dismiss now works on video pages.

## [0.1.0-beta.24] — 2026-07-04

### Fixed
- **Runaway memory growth that killed call audio (iOS build 167 jetsam at 2.3 GB).** Crash logs
  off the phone showed a single core thread at ~79% CPU growing the app 202 MB → 3 GB in under
  two minutes: iroh's per-peer path actor spinning close → re-open-path → close against a
  FLAPPING peer (a relay whose key was bound by two endpoints — the daemon bug fixed in
  beta.23), allocating fresh QUIC state each lap until the system started killing audio daemons
  mid-call. Defense on the app side: the per-peer dial backoff is now flap-aware — a connection
  that dies within 30 s counts as a dial FAILURE (30 s → 10 min cooldown) instead of resetting
  the backoff, so a flapping peer costs one short-lived connection per cooldown instead of a
  continuous churn loop. (Connections that live ≥ 30 s clear the backoff as before.)
- **Call audio now recovers instead of going permanently silent (iOS).** The app had no
  handlers for audio interruptions, route changes, or the system's "media services were reset"
  (mediaserverd dying — e.g. under the memory pressure above). Once that happened, WebRTC's
  mic/playout units stayed dead for the rest of the call and the speaker toggle did nothing.
  CallManager now reconfigures + reactivates the session, reapplies the speaker route, and
  bounces WebRTC's audio unit on media-services-reset and interruption-end; the speaker button
  also tracks the actual output route instead of showing a stale toggle.

## [0.1.0-beta.23] — 2026-07-04

### Fixed
- **Standalone relay daemon (NAS/Docker) no longer flaps "Unreachable — retrying".** The daemon
  ran its media store as a SECOND iroh endpoint under the SAME key as the connection relay
  (`BlobServer::spawn` beside `RelayNode::spawn`) — the same-key second-endpoint bug that caused
  the beta.13 internet outage in the apps: the two endpoints fight over the node id's DERP
  home-relay registration, so inbound dials flap between reachable and dead. The daemon now
  serves the blob mailbox on the relay's OWN endpoint (one node, two ALPNs — the same
  `enable_relay` path the in-app relays have used since beta.13). The opt-in S3 tunnel gets its
  own seed-derived identity for the same reason (its printed `volunteer_node_id` changes once).
  Relay identity, saved link, mailbox contents, and the HTTP media interface are all unchanged —
  update the container and the same relay id just becomes reliably dialable.

## [0.1.0-beta.22] — 2026-07-04

### Fixed
- **Adopted external relays (NAS / Docker daemon) now actually reach circle members (iOS/macOS +
  desktop).** Adding a relay announced it to the circle exactly ONCE, at adopt time; the periodic
  re-announce only ever covered the relay the device itself hosts. A member who was unreachable at
  that one moment never learned the external relay — "I shared my NAS relay with the circle but my
  friend doesn't see it." The periodic re-announce now covers EVERY active relay known for each
  circle (adopted external + all-circles default + self-hosted), over nearby, direct, and mesh
  paths — parity with Android, which already re-announced all circle relays per hello. Receivers
  were already idempotent (only a genuinely new relay triggers the backfill).

## [0.1.0-beta.21] — 2026-07-04

Stability wave: the add-friend handshake and re-adding a previously-removed friend now work
reliably over the internet, on every platform. **Update all of your own linked devices** — the
removal-record fix converges fleet-wide once each device runs this build.

### Fixed
- **Re-adding a removed friend finally sticks (all platforms).** Removal records synced between
  your own devices were grow-only and permanent: every self-sync pass re-applied the severance,
  so a friend you had once removed — then deliberately re-added via a new invite or approval —
  was silently removed again seconds later, their handshakes dropped and their posts hidden.
  This compounded with each release that made "removal sticks" stricter (iOS beta.10, Android
  beta.20) until whole friendships went mute. Removal records are now last-writer-wins per
  entry (`1` = removed, `0` = deliberately re-added): every deliberate re-add path — approving
  a request, scanning an invite, adding back to a circle — clears the tombstone locally AND
  publishes the clear so sibling devices stop re-severing. Desktop also gained the
  removed-member handshake guard (parity with iOS/Android).
- **Reply-path bootstrap now works on relay-hosting devices (core).** The beta.17 fix (learn a
  dialable device id from any direct hello) never worked on a device that hosts an in-process
  relay: the relay's inbound path zeroed the authenticated sender id before delivering bare
  payloads to the app. Since most devices host a relay, a fresh internet invite often left the
  initiator un-dialable by the invitee — "connected but mute". The sender id now survives the
  relay-hosting path; core tests assert it.
- **iOS/macOS: a freshly-approved friend is dialable immediately.** The 10s dial-target cache
  (beta.18) wasn't invalidated when you approved a connection request or when a handshake added
  a member — the very next sync tick could skip the brand-new friend. The cache now clears on
  every contact/membership change.
- **Android call screen: the share-screen and hang-up buttons are back.** All seven in-call
  controls sat in a single row wider than the screen, silently pushing the last buttons off the
  right edge once the speakerphone toggle landed (beta.20). The controls now match iOS: two
  rows — media toggles (mic / speaker / camera / flip-when-camera-on) above, call actions
  (share screen / add people / hang up) below.

## [0.1.0-beta.20] — 2026-07-04

### Fixed
- **Removing someone from a circle sticks (Android).** A removed member kept reappearing: they
  don't know they're gone and keep broadcasting Hellos, and `handleHello`'s "already a contact"
  branch silently re-added their bundle to the very circle you removed them from. It now honors
  the removal tombstone (parity with iOS); a deliberate re-add still un-bans them.

### Added
- **Android call screen: speakerphone toggle** (loudspeaker ⇄ earpiece via AudioManager, default
  on for video calls; a Bluetooth/wired headset still overrides) and the **add-people button is
  always visible** (dimmed when there's no one left to add) so the control row is stable.
- **Docker Compose for the relay** (`relay/docker/`) — run `haven-relay` on a NAS or home server
  in a container: pulls the static musl binary (amd64/arm64/armv7), persists identity + the sealed
  mailbox to a volume, exposes the `:8674` media interface.

## [0.1.0-beta.19] — 2026-07-04

Launch-polish wave alongside the 1.0.0 App Review submissions (iOS build 166, macOS build 167).

### Added
- **Deep-linked invites on Android + desktop.** Android registered `haven://` but dropped the
  link (ACTION_VIEW unhandled) — it now routes to the Connect screen and connects immediately,
  and a new intent filter offers "Open with Haven" for the invite web link. Windows/Linux
  desktop registers `haven://` at install time (Tauri deep-link) → connect-by-link + focus.

### Fixed
- **Story captions render identically on iOS, Android, and desktop.** Android photos baked the
  caption into pixels with an empty body (the author's position/typography never traveled) and
  used mismatched color/font index tables; desktop neither encoded nor decoded (raw control-char
  text). All platforms now speak the same normalized wire format and match fonts, colors,
  positions, and effect shadows.
- **macOS UI polish**: circular glass icon buttons replace the barely-visible rounded-rect
  chrome; sheets extend the brand gradient edge-to-edge instead of showing gray bands.

### Changed
- **macOS `.dmg` retired** — the Mac app ships on the App Store; all past release dmg assets
  removed and the CI leg deleted.

## [0.1.0-beta.18] — 2026-07-03

### Fixed
- **UI smoothness: the engine no longer runs on the main thread (iOS/macOS).** A main-thread audit
  found the heaviest engine work executing on the main actor: `exportState()` + the atomic state
  write after every post/ingest burst (100-500ms freezes), per-envelope `receive()` crypto during
  mailbox drains and event bursts, the full-feed `feed()` decode + O(posts) filter on every 20s
  tick, N×`deviceNodeIdsFor` FFI calls per sync fan-out, and an O(items×media) disk scan per
  sweep. All now run off-main via Swift structured concurrency: state persistence is serialized
  through an actor (ordered, coalesced), envelope batches ingest on a background task with one
  main-actor apply, the feed rebuild is detached with a stale-result generation guard, dial
  targets are cached 10s (invalidated by fresh rosters/hints), and the media scan is capped to
  once per 2s. Android already ingested off-main (Dispatchers.IO); desktop is Tokio-async.

## [0.1.0-beta.17] — 2026-07-03

### Fixed
- **New internet friends can now talk back ("we're connected but his DMs and profile never
  arrive").** Invite-link dial hints only bootstrap the direction that scanned the link: the
  invitee holds NO dialable id for the initiator, so their hello-back (which carries their
  name/profile), DMs, and posts depended on roster propagation that itself needs a working route —
  a timing lottery. The transport has always AUTHENTICATED each connection's remote endpoint id;
  it's now surfaced through the inbound callback (`InboundListener.on_inbound(from_hex, payload)`),
  and a hello received over a direct connection records the sender's device id as a dial hint for
  their account on all platforms. One successful delivery in either direction now bootstraps the
  reply path instantly; the signed device roster still supersedes hints.

## [0.1.0-beta.16] — 2026-07-03

### Fixed
- **DMs finally land in the relay mailbox ("the push showed her message but the app never
  did").** The relay store's path sanitizer rejected any key component containing `:` — and every
  DM circle id is `dm:<a>-<b>`, so no relay could EVER store a DM envelope: an offline recipient
  got the push banner (which travels via the blind worker) but the message itself had no
  store-and-forward path at all. Disk names are now escaped (`:`→`%3A`, Windows-safe) while keys
  keep their colons on the wire; existing stores are unaffected. Verified live: the first-ever DM
  mailboxes appeared on the relay within minutes of deploying, with history backfilled. Also fixed
  a trailing-slash LIST prefix failing the same sanitizer.

## [0.1.0-beta.15] — 2026-07-03

### Fixed
- **Haven no longer hijacks your music.** Post songs play through the SYSTEM-side application
  music player, which (a) keeps playing even when Haven isn't on screen and (b) steals playback
  focus from the user's own Apple Music session the moment it starts. A background LAUNCH (bg
  fetch / silent push after the app was terminated) builds the feed with no scenePhase change ever
  firing, so the existing "don't auto-play while backgrounded" flag stayed false — the top post's
  song could start playing on the nightstand at 3am, and background refreshes could repeatedly
  yank playback focus from CarPlay (music "self-pausing" mid-drive). Every playback-issuing path
  in `MusicPlayback` (play/resume/unduck, iOS + macOS) is now hard-gated on the app actually being
  frontmost, and the backgrounded flag initializes from the real application state.

## [0.1.0-beta.14] — 2026-07-03

### Fixed
- **Call accept works cross-NAT ("it rang her but she couldn't accept").** Call signaling
  (invite/accept/hangup/SDP/ICE) was DIRECT-only: the push notification rings the callee, but her
  ACCEPT needed a working direct dial back to the caller, with no fallback. Call frames now also
  hop LIVE through up to 3 adopted circle relays as a frame-9 forward (the relay host unwraps the
  inner frame and sends it onward over its own connections). Android and desktop additionally
  learned to process + forward frame 9 (previously iOS/macOS-only, so a phone- or desktop-hosted
  relay couldn't forward at all). Duplicate-tolerant handlers + msgId dedup guard loops.

## [0.1.0-beta.13] — 2026-07-03

THE internet-reliability fix. Every relay-hosting device was unreachable over pure-relay
(cross-NAT) paths — proven by dialing the Mac relay: a direct-addressed dial completed in ~5ms
while the identical relay-path dial timed out at 30s, every time.

### Fixed
- **Relay mesh sync no longer knocks its own node offline.** `sync_pull_from` /
  `relay_sync_from` (the ~20s mesh anti-entropy tick) built its client with
  `BlobClient::connect(self.secret, …)` — binding a FRESH iroh endpoint under the node's OWN id.
  Each tick that ephemeral clone (a) **stole the node's DERP relay registration** (the home-relay
  flapped true→false every cycle, ~2,000 times in one session log), (b) **refused every inbound
  handshake** while it lived (its ALPN list is empty), and (c) died ungracefully after dialing —
  usually a stale, undialable relay entry, burning a 30s timeout. Net effect: inbound relay-path
  connections to any relay-hosting device were a lottery that almost always lost — friends across
  the internet could not fetch posts, media, or call invites from a hosted relay. Mesh sync now
  reuses the node's long-lived endpoint (`BlobClient::over_endpoint`); `BlobClient::close()`
  learned endpoint ownership so a borrowed shared endpoint is never shut down. Verified: relay-path
  blob LIST against the Mac app went from 100% 30s-timeout to ~190ms, zero registration flaps.
- **Per-peer dial backoff at the transport chokepoint.** The 20s sync loop re-dialed every
  unreachable id (friends' pre-multidevice account ids — undialable by design — plus offline
  devices) forever, keeping ~10 doomed handshakes permanently in flight and spamming
  `MultipathNotNegotiated` path-close warnings (~3,300 log lines / 30s). Failed dials now back off
  30s → doubling → 10min cap, reset on success.
- **Standalone `haven-relay` daemon negotiates QUIC multipath** (parity with the in-app node) — a
  multipath-enabled client dialing a non-multipath relay died with `MultipathNotNegotiated` on
  cross-network paths.

### Added
- `haven-net examples/diag.rs` — transport diagnostic (home relay, n0 DNS publish check, timed
  blob dial by node id, `DIAG_DIRECT=ip:port` direct-address bisection) — the tool that isolated
  the ephemeral-endpoint bug.

## [0.1.0-beta.12] — 2026-07-03

Device-id reachability wave: every send site now dials friends by their DEVICE node ids, closing
the gaps that made calls, media, and internet delivery unreliable after the device-seed transport
flip (an account id no longer resolves to any node, so an unexpanded send silently reached nobody).

### Fixed
- **Android call signaling reaches the caller again.** `sendFrame` (which `sendCallFrame` and the
  media request/chunk paths ride) sent directly to the given hex with no account→device-id
  expansion — so a call ACCEPT/ICE/hangup addressed to the caller's *account* id was dropped at the
  iroh layer, even on the same LAN (iPhone rang Android, but Android's accept never came back).
  `sendFrame` now expands to the contact's authorized device ids at the transport edge, exactly
  like iOS `sendIroh` (identity for already-expanded/device-id inputs, so `dialTargets` callers
  stay correct).
- **Desktop dials device ids everywhere.** `send_frame` (posts, DMs, hellos, relay announces, call
  frames, media) gained the same transport-edge expansion; `authorize_membership` now authorizes
  circle members by their device ids too (a friend's device-seed phone was "forbidden" at a
  desktop-hosted relay).

### Changed
- **Desktop moved to the device-seed transport.** The Tauri app bound its iroh node to the ACCOUNT
  master seed (identity == transport address, the pre-flip design). It now mints/binds a per-device
  seed (`use_device_identity` + `register_device`, parity with iOS/Android), announces its signed
  device roster (frame 27) to contacts + circle relays every greet cycle, ingests contacts' rosters
  (re-authorizing its hosted relay), and dials relays over the **warm** long-lived endpoint instead
  of a cold per-fetch endpoint (the cross-NAT 30s-timeout class). The cold fallback and self-dial
  guards now use device ids (never the account id).

### Added
- **Invite links carry device-id dial hints (`?d=`).** The roster-bootstrap deadlock: a friend can
  only reach you after holding your signed device roster, but the roster itself travels over a path
  that needs a dialable id. Invite QR/links now embed the inviter's device node id(s) as a query
  placed *before* the `#` fragment (old parsers read only the fragment, so links stay compatible).
  The scanner stores the hints and dials them at every transport edge until the real signed roster
  arrives and supersedes them. Implemented on iOS/macOS (`InviteHints.swift`), Android
  (`InviteHints.kt`), and desktop.

## [0.1.0-beta.11] — 2026-07-02

Media-transport + LAN wave: direct local connections restored, large videos play on low-heap
Android, media stops re-uploading, and the relay gains a plain-HTTP interface.

### Added
- **Direct LAN connections restored.** The iroh transport had been forced *relay-only*
  (`clear_ip_transports` + a relay-pinning path selector) to dodge a cross-NAT datagram-drop — but
  that routed *every* connection through the n0 DERP cloud, so two devices on the same wifi never
  talked directly and Android↔iOS had no local path at all (Apple's Multipeer LAN mesh doesn't
  bridge to Android's Nearby Connections). Reverted to stock iroh (IP transport on, lowest-RTT path
  selection): same-subnet peers, including Android↔iOS, now connect **directly over the LAN**
  (verified: a direct `Ip(...)` path forms). Media rides the relay-HTTP/S3 transports now, so
  cross-NAT reliability no longer needs direct paths suppressed. (Note: a peer behind macOS firewall
  *stealth mode* stays on the relay path until it's allowed / stealth is off.)

### Fixed
- **Large videos play on low-heap Android.** A 250–650 MB video sealed to the circle couldn't be
  decrypted on a phone whose managed (ART) heap is capped ~512 MB — the whole plaintext came back as
  a `ByteArray` and OOM'd. Decryption now runs in **native (off-heap) memory** via a file-based FFI
  (`open_circle_media_file`) and writes the plaintext to a file the player streams from; bounded by
  physical RAM, not the heap cap. Verified playing at 1080p.
- **Squished video playback.** The player's `TextureView` stretched clips to its bounds; it now
  applies an aspect-fit transform so a 16:9 video is letterboxed instead of distorted.

### Added (relay HTTP)
- **Relay HTTP media interface — the default cross-NAT media transport.** The in-app relay host
  (and the standalone `haven-relay` daemon) now serves its blob store over ordinary HTTP/1.1
  (`core/haven-net/src/httprelay.rs`), alongside the iroh blob ALPN. Because plain HTTP traverses
  any NAT the moment the host is reachable, this is what makes cross-NAT media (videos, large
  photos) actually land — the iroh blob ALPN drops its datagrams over a pure-relay cross-NAT path
  (noq/iroh fork bug). Blobs are E2E-sealed before they hit the wire, so the interface carries only
  ciphertext; it's **bearer-token gated** (one token per relay, generated once and persisted), and
  the token is distributed to circle members ONLY inside the *sealed* frame-19 relay announce.
  `self/…` self-sync slots are never served over HTTP (they stay on the identity-verified iroh
  path). The host advertises its reachable URLs (LAN IPv4s + an optional operator-set public URL
  for port-forward / reverse-proxy / tunnel setups) in the announce; members fetch + upload media
  over HTTP first and fall back to the iroh blob dial only when no HTTP URL is reachable.
  `haven-relay` flags: `--http <bind>` (default `0.0.0.0:8674`), `--http-url <url>`, `--no-http`.
- **S3/HTTP bucket is now an opt-in BYO option, not the default.** A user-configured S3 bucket is
  still supported and still tried before the iroh blob dial, but the relay's own HTTP interface is
  the zero-config default so most users never touch S3.

### Fixed
- **Stop re-uploading media a relay already has.** The periodic (~2 min) media backfill re-enqueued
  every blob a device holds and, on Apple, only deduped via a live `has()`/`head()` network round-trip
  — which fails over a flaky transport and triggered a full re-upload every cycle; Android had no
  dedup at all and re-`put` every blob unconditionally. Now a **persistent per-(relay, ref) ledger**
  (`MediaBackupLedger` on Apple, a prefs-backed set on Android) records confirmed uploads. Since media
  keys are content-addressed (`haven/media/<ref>`) a blob never changes, so a confirmed upload is
  permanent — `backup()`/`uploadMedia()` now skip a blob for a relay it's already on, *before* reading
  and re-sealing the file. Cleared for a relay only when it's erased (so a wiped+re-added relay
  re-mirrors). This is "why does my phone constantly send media the relay already has."
- **Nearby mesh now actually starts + is visible (Android).** Nearby is default-on but its runtime
  permissions were only requested when the user toggled the (already-on) switch, so they were never
  granted and the mesh never ran. Request them once on launch; the connection chip now shows `· Nearby`
  when peers connect, a live "Syncing N" indicator during transfers, and a tappable detail with the
  active transports + honest nearby state. (Nearby bridges Android↔Android only — iPhone/Mac use
  Apple's incompatible nearby system, so cross-platform sync rides the relay.)
- **Android launch crash (OOM) on a large synced video.** Once cross-NAT sync started delivering
  big videos, the feed's `MediaImage` thumbnail read the *entire* decrypted file into a `ByteArray`
  for **every** media ref — including videos — so a ~423 MB video blew the Nokia's ~512 MB heap the
  instant the feed rendered, crashing the app on launch. Fixed: `MediaImage` now decodes IMAGES
  downsampled and renders a VIDEO poster frame via `MediaMetadataRetriever` (never decoding a video
  as a bitmap), and `LocalMedia` skips any media too large to decrypt in RAM on this device
  (`maxInMemoryBytes` guard) rather than OOM-crashing — it still lives sealed on disk + on the relay
  and plays on a higher-memory device.
- **Cross-NAT media sync (videos) now lands.** The iroh **blob** ALPN (`haven/blob/1`) drops its
  outbound datagrams over a pure-relay cross-NAT path (noq/iroh 1.0 fork bug, proven by two-sided
  connection traces) — so posts synced but videos/large photos timed out forever. Media upload +
  fetch now try the relay's **HTTP interface first**, then a configured S3 bucket, and the iroh blob
  dial last (as an opportunistic fast-path / the only path when nothing else is configured), on all
  platforms. Apple also stops gating the bucket leg on "no relays configured", and Apple + desktop
  skip un-dialable `s3:` pseudo relay entries in the dial loops. A reachable HTTP relay that answers
  404 for a key is treated as a real MISS (the iroh path serves the same store), so we don't waste a
  ~30 s doomed dial on it. See `docs/BYO-STORAGE.md` → "Media transport order".

## [2026-06-30]

Multi-device and Messages wave (iOS/iPadOS, macOS, Android, and desktop, all sharing the Rust core).

### Fixed
- **Own-device sync now converges.** The epoch group-keying overhaul left each device minting a
  *random* epoch key per circle, so a user's own devices (iPhone/iPad/Mac) could never open each
  other's events — posts and DMs never synced across devices. Fixed with **own-device epoch-key
  convergence**: when a device receives a key commit it authored itself, both devices deterministically
  adopt the numerically-larger epoch key + circle secret, so buffered events drain and future re-seals
  use the agreed key (`core/haven-ffi/src/lib.rs` `receive_key_commit`). Consistent across iOS/macOS,
  Android (shared `.so`), and desktop (links the crate directly).
- **DM-delete no longer restores old messages.** Deleting a conversation records a local "cleared
  before" **watermark** so re-starting the DM doesn't surface previously-deleted messages that a peer
  (or your other device) still holds. True network deletion is impossible in P2P — the watermark is a
  local clear, documented as such.
- **Missing media settles.** A **media-request throttle** stops absent media from being re-requested
  forever; the per-contact history re-send (the actual flood) is throttled to an occasional cadence.

### Added
- **Per-device transport identity.** Each client instance takes its own per-device transport/relay id
  (so any number of a user's devices can run under one account without colliding on iroh discovery),
  while the account seed stays the identity — the trust anchor and roster signer — never a transport
  address.
- **Messages: recency sorting + conversation pinning.** Conversations sort by most-recent activity;
  pin up to 6 (iMessage-style), with drag-to-rearrange on iOS/macOS. Pins **self-sync across your
  devices** via the account-state CRDT.
- **Group DMs: per-message metadata.** Each incoming message shows the sender's display name, a
  timestamp, and a delivery checkmark.

### Changed
- **Scroll / perf pass.** Image and video-poster decoding moved off the main thread and hot-path
  logging removed from scroll, for smoother feed and message-list scrolling.
- **Android + desktop parity.** The DM delete-watermark, group-DM sender/timestamp/checkmark rows,
  and pinned + recency-sorted messages were ported to the native Android client and the Tauri desktop
  client, alongside the shared own-device sync fix.

### Docs
- Swept README, `docs/ARCHITECTURE.md`, `docs/MULTI-DEVICE.md`, `docs/GROUP-KEYING.md`,
  `docs/ROADMAP.md`, `docs/ANDROID-PARITY.md`, `docs/MEDIA-AND-MUSIC.md`, and `docs/DECISIONS.md` to
  match current reality: macOS ships from the **native `HavenMac`** target (Mac Catalyst dropped
  2026-06-23), group keying (epoch sender-keys) + self-sync are shipped, own-device sync converges,
  and Android now has media chunks, WebRTC calls, notifications, nearby, and the DM parity wave.
