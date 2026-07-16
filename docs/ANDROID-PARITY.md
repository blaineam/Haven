# Android Parity Plan

How each Haven capability reaches the Android app, and at what parity. Targets the user's old
device: **Android 10/11 (API 29/30)**, so every choice below is checked against API 29.

## Implementation status (in progress — native `android/`)

The native client is underway in `android/` (Jetpack Compose + Material 3, minSdk 29), sharing
the Rust core via UniFFI Kotlin bindings (`android/build-rust.sh` mirrors the Apple xcframework
script). Verified on a physical **Nokia 6.1 (Android 15)**.

- ✅ **Done:** toolchain + Rust→Kotlin FFI; theme/nav/onboarding; identity in the Android
  Keystore; QR invite show/scan + MITM-guarded handshake; circle feed + composer; reactions +
  comments; DMs (deterministic `dm:` circle); profile editing; settings (retention, block list,
  start over); stories (tray + viewer); **cross-device media chunks (type-3/5 MediaReq/Chunk) +
  the offline mailbox** (relay + S3-as-relay config); **WebRTC audio/video calls** with the
  system call UI via Telecom/`ConnectionService`; **notifications** (WorkManager `SyncWorker` +
  `NotificationManager`); **Nearby** transport; and the **DM parity + own-device sync** wave —
  delete-watermark, group-DM sender/timestamp/checkmark rows, pinned + recency-sorted messages
  (`DmPins`), device roster, and self-sync (sync-light).
- 🧪 **Tests:** byte-exact wire-format unit tests + an on-device instrumented suite (handshake,
  post/DM exchange, persistence, sealed-media round-trip, story flag).
- ✅ **Since shipped** (this list previously said these were remaining — they landed 2026-06-23):
  **in-app browser** for links (Chrome Custom Tabs + system fallback, `ui/LinkText.kt:22-26`) and
  the **music redesign** (`MusicSearch.kt`, iTunes Search API — no account/SDK — wired into the
  composer and feed). Key storage is also real: the 32-byte seed lives in
  `EncryptedSharedPreferences` under an Android-Keystore `MasterKey` (`core/HavenCore.kt:85-97`),
  not plain prefs.
- 🚧 **Actually remaining** (verified against code 2026-07-15):
  - **Sensitive-content blur is not wired.** The FFI exposes `flagSensitive`/`sensitiveRefs`, but
    no Android code calls either — so media an Apple peer flags via SCA renders **unblurred** on
    Android. Android needs no classifier for this; it only needs to honor the federated flag.
  - **No EXIF/GPS strip on video.** Photos are safe (`LocalMedia.kt:344-393` re-encodes from a
    decoded bitmap, dropping all EXIF incl. GPS), but `readVideoBytes` (`LocalMedia.kt:330-337`)
    reads the picked video's raw bytes with no transcode — **original GPS metadata ships**.
  - **Music: local-file attach missing.** The doc's design has two halves (local file → full;
    streaming → deep-link). Only the deep-link half exists; there's no local-audio-file attach.
  - **No Wear OS companion** (iOS has `HavenWatch`; nothing equivalent under `android/`).
  - **No active-speaker highlight** in calls — needs audio-level plumbing on `CallManager`
    (`ui/CallUI.kt:322-323`). Cosmetic.
  - Broader cross-platform field testing and on-device polish.

> **Build gotcha (do not skip):** the Android Rust `.so` + UniFFI bindings are gitignored and are
> **not** rebuilt by `assembleDebug`. Run `android/build-rust.sh` after **any** `core/` change or
> a locally-built APK ships a stale core (this broke cross-platform decrypt after the epoch group-
> keying / own-device changes). CI rebuilds the core itself, so CI is fine.

Direct P2P over iroh works when both peers are online + handshaked; posts, DMs, reactions,
comments, and media bytes flow peer-to-peer, with the relay/S3 mailbox as the offline backstop.

---

The original plan (still the map for the rest):

## The big lever: the core is already portable

The entire trust + data layer is Rust in `core/haven-p2p`, exposed through `haven-ffi`
(crate `haven_ffi`) with **UniFFI**, which generates **Kotlin bindings from the same
`.udl`/proc-macros that generate Swift**. So everything below the UI ports with *zero
reimplementation* — only a Gradle/NDK build of the same crate:

- Identity, hybrid-PQ keys (Ed25519+ML-DSA, X25519+ML-KEM-768), sealing/opening
- Circles, roster, contact bundles, invite links, verification
- Feed/event model: posts, stories, edits, reactions, comments, DMs, media refs, music refs
- Mailbox envelope seal/open, circle-sealed media

`haven-net` (iroh QUIC transport) is also pure Rust and **compiles for Android** (iroh
supports `aarch64-linux-android`). The MLS/networking work we do for iOS is reused as-is.

**Consequence:** Android is overwhelmingly a *UI + platform-glue* project, not a
re-architecture. The parity table is really "which platform API replaces which Apple API."

## Parity table

| iOS feature | Android approach (API 29+) | Parity |
|---|---|---|
| Crypto / identity / circles / feed | Same `haven_ffi` crate via UniFFI Kotlin | **Full** — identical engine |
| iroh P2P transport + mesh relay | Same `haven-net` crate, `aarch64/armv7-linux-android` | **Full** |
| Nearby offline transport (MultipeerConnectivity) | **Nearby Connections API** (`P2P_CLUSTER`), BLE+Wi-Fi | **Full-ish** — different API, same role; needs the iroh-or-nearby ladder reimplemented in Kotlin |
| S3 mailbox / BYO-storage / shared relay | Plain HTTPS + SigV4 — port `S3Client.swift` to Kotlin (OkHttp + HMAC), or do SigV4 in Rust and expose via FFI (preferred — one impl) | **Full** |
| Keychain (key storage) | **Android Keystore** + EncryptedSharedPreferences; same "keys never leave device" rule | **Full** |
| Local notifications + background fetch | **WorkManager** periodic sync + `NotificationManager`; no server, same as iOS | **Full** (Android bg is actually *more* permissive) |
| Camera + story capture | **CameraX** (preview/capture/video) | **Full** — CameraX is modern + clean |
| Photos export / picker | **MediaStore** + Photo Picker (API 30 `ACTION_PICK_IMAGES` fallback to `GET_CONTENT` on 29) | **Full** |
| Video trim / mute before posting | **Media3/ExoPlayer Transformer** (trim, mute) | **Full** |
| Screenshot-protected secret messages | `WINDOW_FLAG_SECURE` on the reveal view | **Full** (cleaner than the iOS secure-field hack) |
| Audio voice messages | `MediaRecorder` (AAC/m4a) + `MediaPlayer` | **Full** |
| **Apple Music** song attach + playback | ⚠️ **No equivalent.** Android has no universal "play this catalog track" API. Options: (a) attach a **local audio file** the user picks; (b) deep-link a track id to **YouTube Music/Spotify** (shows, doesn't auto-play inline); (c) MediaStore local library playback only | **Redesign** — share a portable music *reference* model: local file → full; streaming → deep-link only |
| Audio/video P2P calls | Audio via `AudioRecord`/`AudioTrack`; video via CameraX frames → same wire frame type 15; **Telecom/ConnectionService** for the system call UI (replaces CallKit) | **Full** (more setup than CallKit) |
| CloudKit favorites/resume sync | ⚠️ **No equivalent.** Use the existing **mailbox** (circle-sealed per-user prefs blob) instead of a platform cloud — actually *more* aligned with the no-server ethos | **Redesign → arguably better** |
| Liquid Glass / SwiftUI styling | **Jetpack Compose** + Material 3; rebuild the visual language (brand gradient, masonry, story ring) | **Full** (reimplement UI, not logic) |
| Widgets (ES-style) | **Glance** (Compose for App Widgets) — if we want them | **Full** |
| Push | **Superseded.** iOS shipped a blind APNs relay (self-hosted Cloudflare Worker, `push/worker.js`; sealed payload, NSE decrypts on-device — see `NOTIFICATIONS.md`). Android deliberately did **not** follow with FCM: it uses an opt-in foreground `ConnectionService` that keeps the iroh node alive for real-time local notifications (`core/ConnectionService.kt:17-20` — *"no FCM, no Google, no push server"*), plus a 15-min `WorkManager` `SyncWorker` poll as the fallback | **Done, different by design** — no Google dependency |

## Recommended build order (when we start)

1. **Cargo-NDK build of `haven_ffi` + `haven-net`** → `.so` per ABI + UniFFI Kotlin bindings. Prove `self_test()` + a seal/open round-trip in a bare Compose app. *(toolchain already installed this session: android targets, cargo-ndk, NDK — only the JDK-17 pin remains, current JDK 26 is too new for AGP.)*
2. **Identity + circles + invite link** (paste a Haven link, add a contact, verify). No UI polish.
3. **Mailbox transport in Rust** — do SigV4 + put/get/list *in the core* and expose via FFI, so iOS and Android share one implementation (retires the per-platform `S3Client`).
4. **Feed** (posts + media via CameraX/MediaStore) over the mailbox. First real cross-platform post (iPhone ↔ Android).
5. **DMs + stories + reactions/comments.**
6. **Calls** (audio first, then the type-15 video path) via Telecom.
7. **Music redesign** — portable reference model (local-file full; streaming deep-link).
8. **Nearby offline** (Nearby Connections) + notifications (WorkManager).

## Parity summary

- **Full parity, no redesign:** crypto, circles, feed, DMs, stories, transport, mailbox, camera,
  media, calls (incl. mesh group + screen share), secret messages, notifications, nearby, key
  storage, scheduled messages, avatar publish, in-app browser. (~90% of the app.)
- **Redesigned (and healthier for it):** Apple Music → portable music refs (deep-link half done,
  local-file half missing); CloudKit → mailbox-based prefs sync; push → foreground service +
  WorkManager instead of FCM.
- **Real gaps:** sensitive-content blur not wired; no EXIF/GPS strip on video; no Wear OS app.
  See "Actually remaining" above.

The single most valuable cross-platform investment is **moving the mailbox/S3 transport
into the Rust core** (step 3): it gives iOS and Android the *same* networking from one
implementation. (The web client was abandoned — see [`WEB-PARITY.md`](WEB-PARITY.md) — so
this is now an iOS↔Android concern only.)
