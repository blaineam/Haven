# Changelog

All notable changes to Haven are recorded here. Haven is in **alpha**; entries are grouped
by dated waves (a batch of work committed together and rolled into the next build). See
[`PROGRESS.md`](PROGRESS.md) for the live build/shipping status and
[`docs/ROADMAP.md`](docs/ROADMAP.md) for milestones.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

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
  use the agreed key (`core/p2pcore-ffi/src/lib.rs` `receive_key_commit`). Consistent across iOS/macOS,
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
