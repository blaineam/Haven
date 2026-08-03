# Haven — Live Progress

A running log of what's built, what's shipping, and what I'm working on right now.
Updated continuously. (Times in your local day.)

---

## 🆕 Latest wave (built, batched for next upload)
- **Activity rows about a comment open the post again (2026-08-03, 1.3.1, every client)** — a
  reaction or a reply on one of YOUR comments produced an activity row (and a push) whose tap target
  is the *comment's* id. A comment isn't a top-level feed item — it lives inside its parent — so the
  lookup behind every deep link matched nothing and the tap landed on "Post unavailable" for a post
  sitting right there in the feed. All three clients now resolve a comment id up to the post that
  carries it, in the ONE lookup every entry point shares (activity row, notification, story embed,
  pasted link), so rows and pushes already in the wild are fixed too. The linked comment is shown —
  never collapsed behind "show all N comments" — and tinted, because a post with a dozen comments
  doesn't tell you which one they reacted to.
- **Share into Haven from anywhere, and pick who it goes to (2026-08-02, 1.3.0, iPhone + Android)** —
  the share sheet now takes text, links, photos, videos **and files** (PDFs, zips, .docx, audio), and
  asks where they go: a post in one of your circles, a story, or a conversation — a friend or a group
  DM. Files are the new content type. On Apple the ordering is the whole trick: a document shared
  from Files conforms to *both* `public.file-url` and `public.url`, and the URL branch had been
  turning a real attachment into a `file:///…` string nobody could open. On Android ingest moved off
  the main thread and the size is checked before the read, because a shared file can be hundreds of
  megabytes and reading one on the looper is an ANR.

  And **your conversations now appear in the row at the top of every app's share sheet**, where
  Messages, Signal and Slack put theirs — tap one and you skip straight to that thread's composer.
  Apple donates an `INSendMessageIntent` per conversation, Android publishes sharing shortcuts. Both
  carry the name and photo and **never any message content**, both are retracted when the thread is
  deleted or its circle is locked, and there's a switch (Settings ▸ Privacy ▸ Share sheet) that
  erases what was published. A locked circle is never suggested — it hides that it exists, which a
  tile bearing its name in every other app's share sheet would not.

  Android can now **open** a file it receives, too — name, size, Open, Share, and a Download when
  the bytes aren't local yet. It could always receive one and show a tile; that was the end of the
  road. Still open: macOS has no share extension (it needs its own target) and desktop has no OS
  share sheet to register into.
- **An rc now means something (2026-08-02, 1.3.0, release process)** — the tag decides the Play
  track. `v1.3.0-rc.1` reaches testers only (Play internal + closed testing; Apple's testers are
  already served by Xcode Cloud off the push) and can't reach production even if a repo variable or
  a manual input asks for it. Plain `v1.3.0` ships straight to Play production. Promoting is
  tagging the same commit without the suffix, so testers used the exact build that ships. The App
  Store submission stays a deliberate by-hand step — an App Store version can't be reused, rewound
  or un-submitted, so it isn't something a tag should trigger.
- **"Media was put back" woke people who never asked (2026-07-31, 1.2.2, all platforms)** — reported
  as a couple of overnight notifications for media the user had not requested, with the fair question
  "is that actually fixed already, or a stale one from a broken build?" Neither: 1.2.1 silenced this
  on ANDROID ONLY (the commit is `fix(android): …`; its sole Apple change was the version number), so
  iPhone, Mac and desktop had been announcing automatic repair the whole time. The held-but-unreadable
  sweep asks a post's author to re-seal media it cannot decrypt — automatically, no user involved —
  and wrote that ask to the same store the "Notify me when it's back" button uses, so the answering
  frame could not tell plumbing from a person and notified for both. Manual asks are a separate,
  persisted subset now, and only they are announced; the fetch stays silent, which is the part that
  matters. Two more fell out of it: the "We'll tell you when it's back" label read the shared set on
  all three platforms (promising a notification that by design never comes, and hiding the button
  that would earn one), and Android's manual set was in-memory, so a real ask lost its notification
  across a restart — with authors routinely offline for days, that is the ordinary case.
- **The hosting Mac froze every twenty seconds, and it was one missing keyword (2026-07-30, 1.2.1
  re-cut, Apple)** — reported as "beachballs every 20ish seconds in a DM, recovers after 10–15s".
  Sampling the shipping build put 56% of a 15-second window on the main thread inside one
  main-actor task, in a loop of `open` / `fsetattrlist` / `clock_gettime` / `close` — which is
  `touch_now` in `blobstore.rs`, the mailbox liveness stamp, one file per key. `RelayHost`'s local
  store accessors were all made `nonisolated` in an earlier pass for exactly this reason;
  `localTouch` was missed, and it is the one handed the biggest batch (`touchHeldKeys` passes every
  mailbox key the device has ever ingested for a circle — ~12,000 on this machine). The caller
  looked innocent: `backfillMailbox` wraps the sweep in `Task.detached`, but `SharedStore` is
  `@MainActor`, so awaiting it hops right back to main and runs the loop there. Now `nonisolated`
  like its siblings, with both call sites doing the batch off-main. The app's own log named the
  scale: `poll OWN relay default: 12032 keys, 200 new (+4748 next poll)`. Also added the missing
  speaker chip to the DM video viewer.
- **Android felt like a port, not an Android app (2026-07-30, 1.2.1 re-cut, Android only)** — five
  tester reports that were all the same kind of problem: the client not respecting the platform it
  runs on. The **Circle title bar** measured the circle name before anything else, so a long name
  squeezed the connection chip until "Connected" wrapped one letter-pair per line and the bar grew
  to five lines with the add-friend button off-screen (reproduced on an emulator at a raised
  display size). The **DM composer** spent five fixed 40dp icon slots before measuring the text
  field, leaving about 80dp to type in; they're one `+` menu now, matching iOS. **System back**
  closed the app from anywhere, because Haven navigates by state and the platform had nothing to
  pop — it now leaves a conversation, a Settings sub-section, a sheet, a call, or a non-Circle tab,
  and only exits from Circle. An **invite link** took two taps to reach the right screen: the
  activity was `standard` launch mode, so a link spawned a second one alongside the first and two
  live compositions raced to consume the single pending link from a process-wide inbox — the app is
  `singleTask` now and the link is passed down as an argument instead of read from a global. And
  the **Circle feed could come up empty** until you switched tabs and back, because `init()` runs
  after the first composition and never invalidated the `remember` that had already cached the
  empty pre-init read. Nothing in `core/` moved. Also fixed the Android unit suite, which had not
  compiled since hangup frames started naming their session in 1.1.5.
- **The call fallback only ever worked Apple↔Apple (2026-07-26, 1.1.5 b366, Android + desktop)** —
  auditing what Apple had that the others didn't turned up the real reason cross-platform calls
  ring, get accepted and never connect. `/webrtc/hairpin` is the media path when ICE cannot pair
  two hard NATs, which on mobile carriers is the ordinary case. Android's hairpin was a COMMENT:
  `FabricIcePolicy` and `CallManager` both promised "path-proxy WebSocket hairpin for media" and no
  such code existed, so an Android leg with failed ICE had nothing. Desktop's existed but sent and
  expected BARE PCM while Apple frames every packet `[type][seq][ptsMs]` — Apple dropped desktop's
  frames as malformed, desktop played Apple's headers as audio. Both fixed: Android gets the full
  bridge (AudioRecord/AudioTrack 16 kHz mono with platform AEC, MediaCodec H.264 with GPU rotation
  through WebRTC's own EglRenderer, jitter buffer, ICE-failure trigger that comes up alongside ICE
  and tears down when it recovers), desktop gets the shared framing. Also from the same audit:
  "where this is stored" ported to Android and desktop, disappearing messages finally settable on
  desktop (the engine always took `retention_secs`; the UI passed a hard-coded `None`), and the
  active-speaker highlight ported with Apple's exact threshold and debounce.
- **Answering a call could kill the app; posts took minutes to show (2026-07-26, 1.1.5
  b366, all clients)** — 1.1.4 was pulled from App Store Connect and the Microsoft Store
  before general release; this is the pass that makes it shippable. The crash: `WebRTCCall`'s
  constructor `fatalError`'d when `RTCPeerConnectionFactory` handed back no peer connection,
  and the factory returns nil when it REJECTS THE CONFIGURATION — which is not ours to
  control, since `iceServers` is built from whatever `turn:` URLs the circle's relay
  advertises. One unparseable entry invalidated the list, and the accept path
  (`startMesh` → `connectPeerIfNeeded` → the constructor) terminated the process at the
  exact moment of picking up, reproducibly from a caller on another platform in another
  circle. Construction now degrades — circle config, then plain STUN, then host-only — and a
  real refusal is a failed call, not a dead app. Desktop was also still running the OLD ICE
  policy (empty server list whenever a fabric exists = host candidates only), which cannot
  complete a call between two home NATs; it now matches Apple/Android.
  The latency: the mailbox poll shared its idle back-off with the contact fan-out, and that
  back-off measures INTERACTION, not attention — 30 seconds of reading without tapping put an
  iPhone on ×4 (45s → 3 min), then ×10 (7.5 min), which is exactly "it takes a few minutes
  after a relay has a copy before it loads". The two have nothing in common cost-wise: the
  fan-out is hello+roster sealed to every contact (the thing that cooked phones, unchanged
  here); the poll is one LIST of your own mailbox. The poll is now capped at 2× base while
  the app is on screen, on both iOS and Android.
  Also in this wave: a compressed video that attached to nothing visible (both composer trays
  required a decoded bitmap and had no final `else`); "Media still loading…" narrating a photo
  already sharp on screen; DM threads re-scrolling on every change to the active CIRCLE's feed
  and anchoring short of the bottom; notification-tap requests wedged by clearing a
  `@Published` from inside its own `willSet`; and the story cloud badge finally opening the
  which-relays-hold-this sheet.
- **Two online peers no longer need a relay in common (2026-07-25, 1.1.4 b365, core +
  all clients)** — a contact holds your ACCOUNT id (that is what an invite/QR carries)
  but has to dial your DEVICE ids, and both ways of learning those — your signed roster,
  an invite `?d=` hint — need a route to already exist. So two peers with no shared relay
  had no route at all, even with both devices online and iroh perfectly able to hole-punch:
  the friend whose app "refuses to find any of the relays I have enabled", whose DM never
  arrived. Haven now publishes the account → device-id mapping in the public pkarr
  directory under the ACCOUNT key (`haven-net/src/accountdiscovery.rs`, base64url, ≤5
  devices to fit pkarr's 245-byte user-data cap) and resolves it lazily for exactly the
  members it cannot otherwise reach — no roster, no hint — with a 10-minute per-account
  retry floor. Published on node start and after a fabric rebind; a HIT triggers an
  immediate tight sync + relay re-announce, because the relay list the far end is missing
  travels in the sealed frame-19 announce. Security posture unchanged: the record is a
  signed packet so only that account can write it, and it is still only a DIAL HINT —
  content stays sealed to the circle epoch key and inbound frames stay gated on the signed
  roster, so a stale or hostile record costs one wasted connect and nothing more. Live
  round-trip test against the real n0 pkarr servers (`--test account_discovery --ignored`).
- **Deleted relays are recoverable; both-dialing calls connect (2026-07-25, 1.1.4 b365,
  all clients)** — "Delete now" was the one action with no way back (it drops the entry,
  every circle association and the default pick, and a relay is a 64-character node id);
  deletions are archived 30 days and Restore puts the relay back in the circles it served.
  Calls: iOS's glare fix ported — two people who called each other at the same moment both
  sat on ringback and neither call connected. Also: the Android media overlay trusts the
  filesystem so a stale flag can't park a spinner on finished media, and the desktop
  activity panel paginates instead of building a DOM node per row.
- **The receiver-side history-blast storm — b349 "still beachballing" + hot iPhone
  (2026-07-23, 1.1.4 b350, core + Apple)** — two live `sample`s of the beachballing Mac
  (b349, 4.6 GB RSS seven minutes after launch) split the freeze in half: (1) the main
  thread 100%-pegged re-running LinkScanner/NSDataDetector + URL-strip `range(of:)`
  splices per message per frame under FeedView.body, and (2) the main actor parked in
  `__psynch_mutexwait` on the engine mutex while one background EngineGate batch ran
  100%-duty crypto — the periodic full-history re-blast being decrypted BY THE RECEIVER
  just to prove every envelope a duplicate. The b344 gen-cache had only fixed the
  sender's half; receivers (Mac + iPhone + every peer) kept paying full-history unseals
  every cycle, forever, growing with history — the standing all-devices heat. Fixes:
  `receive()` hash-skips re-delivered key-commit/epoch-event bytes BEFORE the engine
  lock (deterministic sealing makes outer bytes proof; session-scoped, cleared on
  leave/purge, MLS/roster tags exempt — they may park and need re-delivery;
  regression-tested incl. the two MLS flows that caught the first over-broad version);
  senders skip blasting circles whose gen hasn't moved for that target (mailbox upload
  deduped from per-envelope-per-target to per-generation); `LinkScanner.urls`/
  `stripping` memoized on body text (NSCache); sealed call/media frame opens (types
  30/31/32 burst in media sweeps) moved off the main actor through EngineGate.
  Android/desktop inherit the receive() skip through the shared core.
  a `sample` of the frozen Mac app showed the main thread ~89% blocked on the engine
  lock while one background FFI call churned huge buffers, and the unified log showed
  the smoking gun: dozens of `push /notify ok` + `fabric rebind scheduled` a second and
  `re-open N circle(s) after key commit` repeating forever. Root cause: since
  device-signed commits, a contact's devices each mint a random key for the same
  (account, epoch); both competing commits live in the mailbox forever, and the engine
  adopted whichever it saw last — every re-offered duplicate "changed state", wiped the
  circle's seen-set, and re-ingested the whole mailbox, every poll. Epoch-key slots now
  converge deterministically (larger key wins, matching the writer side), losers are
  retained so their content still opens, duplicates are reported no-ops, and state-blob
  imports converge the same way (first-wins imports were another way linked devices
  drifted apart). Apple dampers: seen-wipes ≤1/circle/10 min, mailbox syncSelf pushes
  ≤3/circle/pass (the per-envelope firehose was cooking the iPhone), fabric rebind is
  schedule-once. Regression-tested in core; Android/desktop pick the fix up through the
  shared core. Xcode Cloud #347 → TestFlight; Play rc.24 → internal + closed.
- **Self-sync + hello lane resurrection (2026-07-23, core + Apple)** — live-fleet
  diagnosis found the self-sync-over-relay lane DEAD everywhere (three stacked causes)
  and circle invites dying in unclaimable hello slots; the root of "my linked devices
  each show different things". Relay now authorizes `haven/self/<acct>/**` on BOTH
  transports for the account's own fleet (account id or any device in its stored
  account-signed devroster; LIST stays per-account — F3 intact, nothing new disclosed);
  Apple self-sync climbs the uploadEvent ladder (own hosted relay local store → signed
  HTTP → iroh) and counts HTTP-interface-only relays as transports. Hellos are now
  addressed by ACCOUNT hex (device ids stay dial targets), claimed only by their real
  owner (account or current transport device id — never mark-seen'd away by whoever
  polled first), skipped at fetch when addressed to others, deduped per (relay, key) so
  late-adopted relays still get them, plus a one-shot seen repair. Also: rebuilt QA
  stubs no longer spam macOS keychain-approval dialogs (stub keychain work confined to
  the data-protection keychain under its `…qa.stub` access group; production behavior
  unchanged). NEEDS: NAS relay redeploy to serve the new self-sync gate; Android +
  desktop get the same client-side hello/self-sync addressing in their parity pass.
- **The "everything wave" (2026-07-22 night)** — nine-front fix pass, all platforms:
  (1) *Heat round two*: unchanged self-sync states stop re-sealing/re-uploading every
  2 min, hello uploads dedupe, history re-seals stretch with idle + cache, media
  retries back off to 6h persisted, BG refresh is a slim mailbox pull, live-call
  timer only exists in calls, relay **delta-LIST** (digest → 204) kills the idle
  full-key-list radio cost on every platform. (2) *Push→content gap*: NSE fetches the
  announced envelope + thumbnails before showing the banner (relay directory mirrored
  into the app group), alert pushes wake the app (`content-available`), app-open
  consumes push hints first; Android/desktop prefetch before notifying. (3) *Deep
  links everywhere*: banners carry exact post ids (incl. fresh posts via new
  `last_authored_event_id` FFI), Android/desktop notification taps finally deep-link,
  story route added, blank-sheet circle taps fixed. (4) **In-app Activity list** on
  all four platforms (bell + unread badge, tap-to-jump, read-state synced via
  `setting:activitySeenAt`), derived from synced data by one new core `activity()`
  FFI. (5) *Media rides with posts*: priority upload lane + author "media landed"
  announce + photo micro-thumbs upload-first + resumable chunked restores + honest
  placeholder states. (6) *Linked-device convergence*: Android mark-seen-at-fetch bug
  (the divergence root cause) fixed + one-shot repair, `__hello__`/`__relay__`/
  `__live__` routing parity on Android/desktop, avatar + pinned-DM LWW ported,
  desktop retention CRDT key mismatch fixed, own-device catch-up round-robins ALL
  circles, push-wake leg added to Android/desktop. (7) *Crash*: Bonjour retire-pool
  hardening (static, outlives owner). (8) *Copy*: every dense settings/relay/device
  explainer rewritten to one line on all platforms + Learn-more docs links; desktop
  master-key factual error fixed. (9) *QA*: full cross-device E2E suite
  (`soren run Haven e2e`) with propagation-latency perf gates + regression ledger,
  qa-cmd v2 driver contract on all four clients. NEEDS: `cd push && wrangler deploy`
  (content-available + the pending VoIP wave), TestFlight via Xcode Cloud, final
  v1.1.4 tag for relay/desktop release, NAS relay rebuild.
- **Background call ringing fixed (iOS→iOS)**: four defects in the PushKit→CallKit path —
  registry created only in `.onAppear` (a background VoIP launch never renders a view → the
  wake push had nowhere to land), ONE voip-token slot per account on the worker (any linked
  device's launch stole ringing from the others), the real invite/SDP frames were dropped
  against the push-placeholder session (answering from the lock screen produced a dead call),
  and `/call` did nothing at all without a voip token (now falls back to a loud time-sensitive
  alert; both paths expire in ~45s so late doorbells can't ghost-ring). NEEDS: `cd push &&
  wrangler deploy` + shipping the app to both parties.
- **Repeated notifications fixed (all platforms)**: dedupe store now persisted everywhere
  (in-memory-only before — every relaunch re-notified the newest message per circle; the cap
  wiped the WHOLE set), and banners only fire when the newest inbound item is < 10 min old, so
  history backfill / key commits / epoch-churn re-seals can't resurface old messages.
- **Relay mailbox garbage collection (all platforms + CLI relay)**: the ~6,700 legacy
  duplicate envelopes per mature circle (random-seal era + stale-epoch copies) finally age
  OUT of the relays instead of being re-LISTed on every 30s poll (~700 KB a pop) and
  re-circulated forever by mesh sync. New `TOUCH` verb (iroh + HTTP): each member batch-
  refreshes the refs it can deterministically re-seal, daily, on every relay (misses are
  re-PUT — refresh doubles as repair); every relay host sweeps `haven/mailbox/**` entries
  idle > 30 days (media/self-sync never swept; 48h first-enable grace); and mesh sync is
  age-preserving (new `AGES` verb — skips expired entries, back-dates pulls) so a GC'd entry
  can't ping-pong back between siblings. A member can only keep entries alive, never delete.
  See `docs/RELAY-AND-DEPLOY.md` "Mailbox garbage collection".
- **Own-device sync + zombie relays — root-caused and fixed (all platforms)**: the account
  roster had the Mac's own device id STUCK in `revoked` (grow-only revocation union meant
  re-authorization could never propagate, and iOS/Android self-registered before state import so
  the imported roster clobbered it every launch) — that's why iPhone posts stopped reaching the
  Mac directly and why every launch rotated every circle epoch (my_epoch 76 on an 88-event
  circle). Newer-version roster verdicts now win revocation disagreements; registration runs
  after import. And deleted/deactivated relays only reactivate on an announce from the relay's
  OWNER (authenticated sealed-announce sender) — third-party echoes of relays you deleted (but
  which still run somewhere, e.g. old docker containers) no longer resurrect them. Posts also
  upload their epoch key commit alongside, so relay-only peers can always open fresh-epoch
  events.
- **30-second cold start on the circle feed — root-caused and fixed (all platforms, verified live
  on the Mac with real data)**: the mailbox ingestion cursor was in-memory only, so every cold
  start re-downloaded + re-verified the ENTIRE relay mailbox (~6,700 entries for 88 events); and
  the mailbox grew unbounded because every backfill re-sealed history into fresh random bytes →
  a brand-new content-addressed entry per event per run. Cursor is now persisted on all four
  platforms; event envelopes seal **deterministically** (plaintext-keyed salt + derived nonce, no
  wire change) so re-seals dedupe; key commits are cached (and persisted) per recipient-set; the
  full-history backfill is throttled to daily and off the main actor; `iroh-trace.log` capped at
  16MB (was 370MB). Verified: relaunch went from "6714 keys, 6714 new" to "6715 keys, 0 new".
- **CLI self-installs auto-start**: `haven-relay service install` wires up reboot-survival on
  the current OS itself (systemd user unit / launchd agent / Windows Scheduled Task; crontab
  `@reboot` fallback) — `service uninstall` reverses it. No more hand-editing unit files.
- **Desktop logo now matches iOS/Android**: regenerated the whole Tauri icon set (.png/.ico/
  .icns + Store logos) from the real `apple/.../icon_1024.png`, so the constellation glyph is
  pixel-identical across iPhone, Android, Windows, and Linux.
- **Tor honesty**: removed the "there's an opt-in onion/Tor mode" claim from the site + docs.
  Haven is iroh/QUIC (UDP); Tor's SOCKS can't carry UDP, so real onion routing needs a TCP
  transport — it is **not** built. The research spike (`docs/TOR.md`) has since concluded
  **don't recommend**, and the docs now say evaluated-and-declined rather than "planned".
  IP privacy is relay-mediated (peers never see each other's IP) + run-behind-your-own-VPN
  or a self-hosted relay/discovery node.
- **Relays survive reboot, everywhere**: Windows gets a one-line `install.ps1` that downloads
  `haven-relay.exe` (x86-64 + Arm64) **and registers a logon Scheduled Task** so it relaunches
  on reboot; macOS (launchd) + Linux (systemd) already did. The desktop app added an **"Always-on
  relay"** toggle (launch-on-login via `tauri-plugin-autostart` + auto-host-on-launch) so any
  official client is a reboot-surviving relay with no terminal. CI now builds the Windows relay
  `.exe`. Site/README corrected: **storage is only a Haven relay or your own S3 bucket** (dropped
  iCloud/Drive/Dropbox/NAS copy), and the "keys never leave the device" line is now honest about
  Apple's E2E iCloud-Keychain sync. Designed **relay-mesh self-replication** (RELAY-AND-DEPLOY.md).
- **Relay mesh — self-replicating mailboxes**: relays now replicate among themselves. Each
  pulls any sealed blob a sibling holds that it lacks (~30s anti-entropy, content-addressed →
  conflict-free set-union), so a relay can **join or leave freely** and the mailbox self-heals —
  far more resilient. `haven-net` `BlobServer::sync_pull_from` (pure `keys_to_pull` unit-tested +
  caps), `haven-relay --peer`/JSON `peers`, and `RelayServerHandle::sync_from` so the **in-app**
  relay auto-meshes every adopted sibling (any official client = a full mesh node). Security
  review of the anti-entropy still pending before production reliance.
- **Relay redundancy + graceful fallback**: a circle can now have **multiple relays**. Posts
  and sealed media are mirrored to *every* relay (idempotent, content-addressed) and reads fan
  out across all of them, so delivery survives any single relay dying. A failed relay drops into
  **exponential backoff** (5s→5m) and is skipped until it recovers; members auto-pool each
  other's relays. Per-relay health is unit-tested; the desktop Relay view shows each relay's
  reachability with add/remove. Layers under existing direct-P2P + BYO-S3 fallback.
- **Desktop iOS-parity wave** (code + 26 Rust unit tests, ready to device-test): the
  Tauri client gained **in-app camera** (live preview + 6 filters baked into photos + video
  capture), **voice messages** (sealed `a:` audio refs + inline `<audio>`), **secret /
  screenshot-protected messages** (same `\u{2}` wire marker as iOS — interops byte-for-byte;
  concealed in previews/notifications), **scheduled "send later" messages** (serverless queue
  + in-process timer; `haven-desktop --headless` now also runs the scheduler so sends fire with
  the GUI closed on an always-on box — relay-backed timed-release for fully-offline senders is
  designed in `docs/SCHEDULED-MESSAGES.md`), and a **multi-identity switcher** (per-identity seed + data dir; switch
  relaunches). Plus a visual/motion rewrite that makes the desktop UI *feel* like the iOS app
  (glass surfaces, masonry feed, spring motion, double-tap-❤️, light/dark) and music-picker /
  circle-management / video-mute wiring.
- **Linux, first-class**: the Tauri desktop client + the headless `haven-relay` daemon now
  target **Ubuntu, Debian, Raspberry Pi OS, Arch, and SteamOS/Steam Deck**. GUI ships as
  `.deb`/`.rpm`/AppImage, an **AUR** package (Arch), and a **Flatpak** (Steam Deck, via
  Discover); the relay cross-builds as a musl static binary for x86_64/aarch64/**armv7/armv6**
  (every Raspberry Pi) with a hardened systemd **system** service + `.deb`/AUR. New
  `relay-release` CI publishes the `haven-relay-<target>` assets the installer downloads, and
  the desktop CI now also bundles the Flatpak. Added **screen share** to desktop calls
  (`getDisplayMedia` → mesh `replaceTrack`, via the Wayland ScreenCast portal). See
  [`docs/LINUX.md`](docs/LINUX.md).
- **Group calls**: WebRTC calls went from 1:1 to **full-mesh group** (audio+video, E2EE
  DTLS-SRTP), every participant opening one peer connection to every other; signaling
  (SDP/ICE/invite/accept/hangup) still rides the sealed iroh channel — no call server.
- **VoIP PushKit**: calls ring even from a fully-killed/locked device (CallKit on
  iOS/Catalyst, in-app ringing on native macOS); echo cancellation on by default.
- **Screen share**: macOS via ScreenCaptureKit; iOS via a **ReplayKit broadcast
  extension** (`HavenBroadcast`) piping frames through App Group `group.com.blaineam.kith`.
- **Multi-identity switcher**: keep a roster of every identity you've used and jump
  between them, each with its **own per-identity profile** (name/photo/emoji/bio/link,
  namespaced by node-id). iCloud-Keychain backup/restore of identity history; transfer
  code + QR move-to-device.
- **Invisible Mac relay**: the in-app relay runs in-process (FFI); on macOS, closing the
  window keeps it relaying with **no dock icon** (accessory activation policy).
- **Pre-signed S3 mailbox**: members fetch via scoped pre-signed URLs and never hold the
  bucket credentials.
- **Native-macOS port started**: native-macOS FFI slice (`aarch64-apple-darwin`) added to
  the xcframework and a `HavenMac` target stood up (Phase 0; Catalyst still ships) — see
  `docs/MACOS-NATIVE-PORT.md`. A **native Android** client is also underway in `android/`.
- **Windows/Linux desktop** (`desktop/`): a **Tauri 2** client — the Rust backend links the
  core *directly* (no UniFFI), the WebView2 UI is the GUI, and the **same binary runs headless
  as the circle relay** (`--headless`), like the invisible Mac relay. Backend compiles + unit
  & integration tests pass; the headless relay is verified end-to-end. Covers identity/profile/
  circles/feed/stories/DMs/QR-handshake/media-attach/relay-host, **WebRTC audio·video·group
  calls** (full mesh in the WebView, signaling on the sealed channel), **native notifications +
  system tray**, and a **BYO S3/R2/B2 bucket** mailbox via a new shared `core/haven-s3` SigV4
  client (SigV4 unit-tested vs the AWS vector). **CI** builds Windows (.msi/.exe) + Linux
  (.deb/.AppImage). Live cross-device test + MSIX/Store packaging are next. See `docs/WINDOWS-PORT.md`.

## 🚦 Shipping status

- **Live on TestFlight:** build 26
- **Built + committed, batched for next upload (one binary):** build 27
  - 🐛 Crash-on-open fix (panic contained at the Swift-callback boundary)
  - 🎞️ Real media optimization — 1080p video, ≤2560px photos (the toggle was cosmetic before; this is what fixes videos not sending)
  - 📦 Chunked media transfer (512KB sealed chunks → large videos send, flat memory)
  - 🔇 Silent mode · ❤️ double-tap heart · 🔈 tap-to-mute · 👀 see-who-reacted · 🕑 relative timestamps
  - Honest connection status on the You page
- ⏳ Holding uploads ~24h (hit Apple's daily upload limit) — everything below rolls into the same single build.

## ✅ Proven working (device-to-device, user + mom)
Post-quantum E2E identity · invite QR + scanner + verified handshake · **two-way messaging over internet AND nearby Bluetooth/Wi-Fi mesh** · encrypted media · persistence · circle management · retention · Apple Music · scroll-driven playback.

---

## ✅ Multi-circle — DONE (committed, tested)
- [x] Engine: `HavenSocial` holds multiple circles (each its own group / event-log / seen-set)
- [x] Persistence: per-circle state on disk + legacy-format migration
- [x] Wire protocol: Hello/Event carry a circle id; received events route to the right circle
- [x] FeedStore + UI: circle switcher in the feed title, per-circle feed, create circle
- [x] Circle propagation: a Hello for an unknown circle auto-creates it (verified sender), so it forms on their side
- [x] CircleView: add existing contacts to a circle / leave a circle

---

## ✅ Mesh relay (#13) — DONE
Relay frame (type 9): an internet-connected nearby phone forwards a sealed frame it can't read toward its destination (cleartext routing header, E2E payload), re-floods nearby (ttl-bounded), msg-id dedup. Posts + handshakes originate relays.

## ✅ Direct messages (#9) — DONE
A DM = a private 2-person circle (reuses the whole E2E + delivery + mesh stack).
Messages list, contact picker, chat-bubble thread; DMs hidden from the feed switcher.

## ✅ Stories (#10) — DONE
`story` flag on posts (24h retention auto-expiry); stories tray (rings) at the top of the feed; full-screen viewer with progress bars + tap nav.

## ✅ Video mute + trim (#3) — DONE
Attached video chips get a Trim (system editor) + Mute-audio (strip audio track) menu.

## ✅ Notifications (#6) — DONE
Local-only, no server/third party. BGAppRefreshTask wakes → syncs → local notification for anything new; live inbound notifies directly (deduped, foreground-suppressed).

## ✅ Calls, sync & stories overhaul (DONE, builds green)
- **WebRTC calls** (replaces audio-over-iroh): `WebRTCCall` (PeerConnection, DTLS-SRTP E2EE
  media), signaling (SDP + ICE) over the existing sealed channel, STUN for NAT, CallKit UI,
  Metal video views. Audio + video, 1:1. (Device-verify; Catalyst-safe — WebRTC has a
  catalyst slice, call code `#if`'d out.)
- **Push-inline sync** — small sealed events ride *in* the push (`ev`); the NSE stashes them
  in the shared Keychain and the app ingests on next sync — no mailbox round-trip, relay stays
  zero-knowledge. Mailbox is the backstop for media + APNs-coalesced catch-up.
- **Multi-device** — the relay now keeps **multiple device tokens per identity** (was one), so
  every linked device gets pushes; authored events self-sync via a silent push to your own
  devices. "Link a new device" surfaces the transfer-code/QR. (Worker needs redeploy.)
- **Story camera overhaul**: portrait lock, caption controls above the keyboard, pinch-zoom +
  reposition media (framing travels in the spec), per-line highlight + glow/shadow/neon caption
  styles, **multi-clip capture** (90s cap, segment progress bars, review → trash / capture-more
  / share-all), **dual-camera PiP** (front+back via AVCaptureMultiCamSession, chosen corner).

## ✅ This session — profile, circles, links, polish (DONE, builds green)
A batch of UX + privacy features (app + NSE compile clean for the simulator):
- **Profile business card**: name + bio + link, signed & shared E2E (`my_signed_profile`
  now carries a JSON card; `verify_profile_card`, backward-tolerant of legacy name-only).
- **You tab redesign**: it's your profile + posts now; Settings live behind a ⚙️ gear.
  Blocked people moved out of Advanced into regular Settings.
- **Per-circle privacy**: Spotlight indexing and a **Face ID lock** are per-circle (was a
  single global Spotlight toggle). A locked circle is hidden from Spotlight and its push
  notifications are redacted (the NSE reads the locked set from the shared Keychain).
- **Circle settings view** (⚙️ in the circle): rename the circle, privacy toggles, leave.
- **Discover circle members** not in your My Circle, with an Add button; **remove from a
  circle without blocking** (distinct from Block).
- **Links**: post/comment/bio links render as tappable text + native Open Graph preview
  cards, opening an **in-app browser** (address bar, back/forward, reload, open-in-Safari,
  share, close).
- **Link a new device** section (shares the identity via the transfer-code/QR; local
  device-to-device sync is the remaining M2b piece).
- **Polish**: tapping any post toggles global mute (removed the toolbar mute button + the
  Silent-mode setting); compose fields no longer clip multi-line text (rounded rect, not a
  capsule); the now-playing equalizer bars animate when playback starts after the view
  exists (DM song chip); a successful send clears a stale "last send error"; **last seen**
  times persist across launches and update on inbound DMs.

## ✅ Notification Service Extension (#51) — DONE (device-test pending)
Reliable, decrypted push without giving any server our content. The blind Cloudflare relay
forwards a per-recipient **sealed** banner (`e`); the new `HavenNotificationService` extension
opens it on-device — even on the lock screen — via a seed-only FFI (`open_sealed_with_seed`),
reading the master seed from a **shared Keychain access group** (the authoritative seed item
never moves; we mirror a read-only copy). Worker switched from a throttled silent wake to an
**alert + mutable-content** push (no duplicate local banner). Builds green (app + extension,
simulator); live APNs decryption verifies on a physical device + signed extension profile.

## ✅ macOS — DONE (Mac Catalyst)
Same engine + SwiftUI app builds + runs on macOS (Apple Silicon). Added the macabi Rust slice; guarded the one iOS-only API. Mac Catalyst build green.

## ✅ Modern story camera — DONE
Instagram-style: live camera (tap=photo, hold=video, flip, library), then a composer to add a **song** + an easy **caption**, then Share to story. Viewer plays the song while watching.

## ❌ Web client — ABANDONED (native-only)
A browser can't be an iroh peer (no raw UDP / hole-punching), so a web client only works as a
thin client of a *publicly-hosted* relay — not worth it. Dropped 2026-06-22. `web/` is now a
clean **invite-landing / app-promo** page only (opens `haven://` invites in the native app);
the WASM client + `web/engine/` were removed. Android will come as a **native** UniFFI client.

## ✅ Shared circle store (#12) — DONE
seal_bytes/open_bytes group primitive + a real SigV4 S3 client + "Volunteer as tribute": a member keeps a circle-sealed (host can't read) copy of media in their bucket and re-serves it P2P to anyone missing it. No cred sharing.

## ✅ P2P voice calls (#11) — DONE (device-test pending)
CallKit UI + invite/accept/hangup signaling + 16 kHz audio, all over the existing P2P transport — no call server. Call button in DM threads + in-call overlay. Live audio quality needs on-device testing (no mic/CallKit in the simulator); video is the follow-on.

---

## 🎉 The whole backlog is done
Multi-circle · Mesh relay · Direct messages · Stories + modern camera (song + caption) · Video trim/mute · Notifications (blind APNs relay + on-device NSE decrypt) · macOS (Mac Catalyst; native port started) · Shared "volunteer" store + pre-signed mailbox · P2P voice + video + **group** calls + screen share · Multi-identity switcher · Invisible Mac relay.

(The web client was abandoned — a browser can't be an iroh peer; `web/` is now just an invite-landing page.)

Everything builds (iOS + Mac Catalyst), Rust + UI tests green, all committed + pushed.
**Next:** device-test the new features (esp. calls + camera), then batch-upload to App Store Connect once the daily limit resets.

---

## 👀 How to watch progress
- **This file** on GitHub — updated as each box above is checked.
- **Commit feed** — github.com/blaineam/haven — every piece is a pushed commit with a clear message.
- **Task board** in your Claude app — live status of each item.
