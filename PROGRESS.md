# Haven — Live Progress

A running log of what's built, what's shipping, and what I'm working on right now.
Updated continuously. (Times in your local day.)

---

## 🆕 Latest wave (built, batched for next upload)
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
