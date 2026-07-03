# Changelog

All notable changes to Haven are recorded here. Haven is in **alpha**; entries are grouped
by dated waves (a batch of work committed together and rolled into the next build). See
[`PROGRESS.md`](PROGRESS.md) for the live build/shipping status and
[`docs/ROADMAP.md`](docs/ROADMAP.md) for milestones.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

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
