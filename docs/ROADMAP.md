# Roadmap

**Last verified against the code: 2026-07-15.** Every "shipped" claim below was checked against
an implementation, not against another doc. Where a claim couldn't be verified either way it is
marked **UNVERIFIED** rather than asserted.

## Where things actually stand

| Surface | State |
|---|---|
| **iOS + iPadOS** | **1.0.4 live on the App Store.** 1.0.5 (build 189) in review — feed blur backdrop + carousel, web post links, relay nudge, call fixes |
| **macOS** | **1.0.4 live on the App Store** (native `HavenMac`, not Catalyst). 1.0.5 in review |
| **Apple Watch** | Shipped, embedded in the iOS app (`com.blaineam.kith.watchkitapp`) |
| **Android** | Signed AAB on the Play **internal** track. Closed testing not yet public |
| **Windows** | Real `.msi` / NSIS `.exe` on GitHub Releases (`v0.1.0-beta.40`). ⚠️ **install path untested on real hardware.** Not in the Microsoft Store |
| **Linux** | `.deb` / `.rpm` / AppImage / sideloadable `haven.flatpak` on GitHub Releases (x86_64). **Not on the AUR. Not on Flathub** |
| **`haven-relay` daemon** | Static musl binaries for x86_64 / aarch64 / armv7 / armv6 (Pi), plus macOS + Windows |
| **Web** | Invite-landing / promo page only — the client was abandoned (M6) |
| **tvOS** | Does not exist and is not planned |

Version skew check: Apple `1.0.5`/`189` (`apple/project.yml:115-116`); desktop + Android ship
from tag `v0.1.0-beta.40`; core crates are all `0.0.1` and unversioned. That's intentional, not drift.

---

## Is v1 feature-complete?

**Functionally, essentially yes.** Everything in the product thesis — circles, feed, DMs, stories,
media, music, mesh calls, screen share, nearby, relay, notifications, multi-device, scheduled
messages — is built and shipping on the Apple platforms, which is where v1 actually launches.

**But there are real gaps, and two are security-relevant.** None of them block an Apple v1; they
block *claiming parity*, and they block some of what the docs promise. In priority order:

### Outstanding — security-relevant

1. **Revocation is not adversary-proof.** A linked device holds a **copy of the account master
   seed** (that's what `haven-seed:` move-to-device transfers), and the engine runs under that
   copied seed rather than a per-device key. Revoking marks a device revoked; it does **not**
   invalidate the seed it already holds. Since device lists merge higher-version-wins
   (`core/p2pcore/src/device.rs`), an attacker with the seed can sign a fresh higher-version list
   and **re-add itself**. The finalizing "seed-drop" is explicitly still to build
   (`apple/HavenApp/DeviceRoster.swift:11-12`, `:52-54`). Revocation works against a *lost* device,
   not a *compromised* one. → This is D16 Phase 2's real remaining work. See `MULTI-DEVICE.md`.
2. **Periodic epoch rotation is not wired.** `rotate_circle` exists in core
   (`core/p2pcore-ffi/src/lib.rs:1518`) and is called by **no client** — only a unit test
   (`:2921`). Rotation therefore only ever happens on removal/block/device-roster change. In a
   circle with no membership churn the epoch **never advances**, `prune_epoch_keys` never fires,
   and one seed compromise decrypts that circle's whole history. Bounded forward secrecy is real
   only for circles with churn. → Wire a timer on each platform. See `GROUP-KEYING.md`.
3. **Video EXIF/GPS gaps.** Photos are stripped on iOS + Android. Video is not: iOS's **default**
   auto-optimize path never sets `export.metadata` (`apple/HavenApp/Media.swift:552-588`) while the
   *non-default* "share original" path does (`:364`); Android ships raw video bytes with no strip
   (`core/LocalMedia.kt:330-337`). The iOS side is a one-liner. See `MEDIA-AND-MUSIC.md`.
   *(The iOS default-path leak is inferred from the `AVAssetExportSession` contract — **UNVERIFIED**
   on device; confirm by inspecting an exported file's metadata.)*

### Outstanding — parity / correctness

4. **Desktop avatar never reaches peers.** You can set one; it stays local.
   `desktop/src-tauri/src/engine.rs:1398` passes `String::new()` into the signed profile card
   instead of `profile.avatar`. The comment there claims this "matches Android" — it does not
   (`android/.../HavenNet.kt:1105` passes `profile.avatarB64`). One-line fix.
5. **Sensitive-content blur is Apple-only.** The analyzer ships on Apple
   (`apple/HavenApp/SensitiveContent.swift`) and federates a `SensitiveFlag` to the circle so peers
   can blur without running it — but **Android and desktop ignore the flag entirely** and render
   flagged media unblurred. Neither needs a classifier; both need to honor the flag. There is also
   **no per-circle toggle** anywhere (it follows the system setting).
6. **Windows install path untested.** CI builds the installers; nobody has installed one on real
   Windows (the available VM can't build them). Treat Windows as beta until someone does.
   **UNVERIFIED** by construction.
7. **In-band chunk size is inconsistent**: 32 KB on iOS/Android, 512 KB on desktop
   (`desktop/src-tauri/src/engine.rs:141`). Interoperable, but unintentional.
8. **macOS native-view backfill**: camera / in-call video / dual-camera are honest
   `isSupported == false` placeholders on macOS (`apple/HavenApp/DualCamera.swift:262-278`).
   Gated, not broken — but a real gap on a shipping platform.
9. **"Start relay at login" is a no-op on native macOS** — `RelayHost.swift:255-267` is gated
   inside `#if targetEnvironment(macCatalyst)`, and Catalyst was dropped.
10. **Music: local-file attach missing on Android.** The portable-reference design has two halves
    (local file → full; streaming → deep-link). Only deep-link exists.
11. **No Wear OS companion** (iOS has one).
12. **No active-speaker highlight** in Android calls (`ui/CallUI.kt:322-323`). Cosmetic.

### Deliberately not doing (do not "fix" these)

- **China**: permanent no.
- **FRA**: off deliberately.
- **Web client**: abandoned 2026-06-22 (M6) — a browser can't be an iroh peer.
- **Tor / onion mode**: evaluated and declined (`TOR.md`) — Tor is TCP-only, so it can't carry
  iroh's QUIC/UDP data plane or WebRTC calls. VPN or a self-hosted relay/discovery node is the
  supported way to hide your IP.
- **Mac Catalyst**: dropped 2026-06-23 for the native `HavenMac` target.
- **FCM on Android**: rejected on purpose — foreground `ConnectionService` + `WorkManager` instead,
  so there's no Google dependency.
- **Quota / blind-token / subscription work**: deleted per D15.

---

## Shipped

### ✅ Cryptographic spine (M1a / M1c)
Hybrid-PQ identity and key establishment: X25519 + ML-KEM-768 → HKDF → AES-256-GCM; signatures
Ed25519 + ML-DSA-65 (both halves must verify). Reach-me links (`haven://` + `https://`) with
parse/verify/MITM-check. `identity.rs`, `crypto.rs`, `link.rs`.

### ✅ Networking spine (M1b)
iroh 1.0: real QUIC, dial-by-address, discovery. `haven-net` `Node` exchanges sealed envelopes.
Async FFI drives it from every client.

### ✅ Social engine (M2)
`p2pcore::social`: circles, posts, stories, messages, comments, reactions, edit, unsend, DMs,
media + music refs — sealed E2E to all members (fresh content key + per-member hybrid-KEM wrap),
hybrid-signed, with a `build_feed` reducer enforcing author-authorized edit/unsend. Contact
approval + blocking; per-circle privacy (Spotlight + Face ID lock). Messages UX: recency sort,
pinning (≤6, self-syncing), DM-delete watermark, group-DM sender rows.

> **Not MLS.** This is multi-recipient PKE (`core/p2pcore/src/social.rs:14-16`). There is no
> `mls-rs` dependency and no MLS code in the tree — it appears only in comments about future work.
> Consequence: **no per-message forward secrecy, no post-compromise security.** Group keying is
> sender-keys + epochs (`GROUP-KEYING.md`); removal/block rotation gives **cryptographic
> revocation**, which is real and tested. MLS hardening remains a future phase, gated on a
> PQ-capable ciphersuite (D3).

### ✅ Group keying (epochs)
Epoch keys distributed via the hybrid KEM; removal/block/device-roster change rotates
(`p2pcore-ffi/src/lib.rs:1128`, `:1521`, `:2516`, `:2540`); last 4 epochs retained
(`prune_epoch_keys`). Adding a member does **not** rotate — and doesn't need to: a joiner gets the
current epoch, so earlier epochs stay unreadable without rotating anything. *(Periodic rotation:
see Outstanding #2.)*

### ✅ Multi-device (M2b, D16 Phases 1–3)
Multi-identity switcher + per-identity profiles; move-to-device via `haven-seed:` code/QR;
iCloud-Keychain backup/restore of identity history; multi-token push. **Phase 1** device-credential
trust layer (`p2pcore::device`). **Phase 3** `AccountState` CRDT convergence engine
(`p2pcore::selfsync`) — wired end to end on iOS/iPadOS, macOS, Android, and desktop — plus
own-device event convergence (per-device transport ids + epoch-key convergence). **Phase 2** FFI
export done; enrollment QR/verify flow + UI ship. *(Phase 2's remaining seed-drop: Outstanding #1.
Phase 4 personal forwarder + Phase 5 MLS hardening: not started.)*

### ✅ Apple apps (M3)
iOS/iPadOS + native macOS SwiftUI on the Rust core via a UniFFI XCFramework. **Live on the App
Store at 1.0.4.** Secure Enclave key storage is **done** — every on-device seed copy is
ECIES-wrapped to a non-extractable P-256 Enclave key (`apple/Shared/SecureEnclaveBox.swift`, wired
at `AccountStore.swift:201`), so a raw Keychain dump yields nothing.

### ✅ Apple Watch
Standalone watchOS target embedded in the iOS app, a **thin WCSession client** — links neither
HavenFFI nor WebRTC (`apple/project.yml:319-345`). Recent DM threads / circle posts, quick replies,
tap-to-react, mirrored notifications, offline queueing via `transferUserInfo`. Scoped per D13.

### ✅ Nearby transport (M4)
MultipeerConnectivity (Bluetooth + local Wi-Fi) on Apple; Nearby Connections on Android. Posts,
DMs, and handshakes flow off-internet. **Mesh relay** (frame 9): an internet-connected nearby phone
forwards a sealed frame it can't read, ttl-bounded with msg-id dedup. *(No desktop equivalent —
deferred.)*

### ✅ Offline delivery & large files (M5)
Store-and-forward mailbox: circle-sealed blobs to an S3-compatible bucket, pre-signed-URL model
(`PresignStore`) so members never hold bucket credentials; per-circle mailbox config (frame 14).
Chunked media (see `MEDIA-AND-MUSIC.md` for the real sizes) with flat memory; auto-optimize vs.
lossless toggle. Shared SigV4 client in `core/haven-s3` — one implementation for all platforms.

### ✅ `haven-relay` (M5b)
Single static Rust binary composing `haven-net` + `p2pcore`. Connection relay (forwards mesh-relay
frames, non-key-holder, RAM-only bounded de-dup — proven by `relay_forward.rs`) **and** media
store-and-forward (`rclone serve s3` on loopback + S3-over-iroh tunnel — proven by `s3_tunnel.rs`).
Relay links carry public routing data only. An in-app `RelayHost` runs it in-process; the Mac runs
it as an invisible background relay. Packaged for macOS launchd + Linux systemd.

> **Membership authorization** (post-audit): a circle's mailbox is served only to that circle's
> members, checked against the connecting peer's verified node id
> (`core/haven-net/src/blobstore.rs:537`, `:687-709`, `:742-748`). This closed a real enumeration
> hole — and it means a relay **does** see `IP ↔ node id` for peers it serves. That's an
> unavoidable consequence of authorizing at all, documented honestly in `THREAT-MODEL.md`. The
> relay holds no key and sees no content.

### ✅ Media, music, calls (M7)
In-app camera (photos+video) with 9 filters + Kodak Gold; Apple Music attach (MusicKit entitlement
granted; real catalog + library picker) with muted-video / audio-crossfade coordination. **Calls:
WebRTC 1:1 and full-mesh group (audio+video, E2EE DTLS-SRTP), signaling over the sealed iroh
channel — on all four surfaces** (iOS, macOS, Android, desktop). VoIP PushKit ring-from-killed,
CallKit on iOS, Telecom/ConnectionService on Android. **Screen share on all four** (macOS
ScreenCaptureKit, iOS ReplayKit, Android MediaProjection, desktop `getDisplayMedia`).

### ✅ Scheduled messages (D17)
**Built and shipping on all three clients** — this was long marked "designed only", and that was
wrong. `desktop/src-tauri/src/scheduled.rs` (5 unit tests) + a headless always-on firer
(`lib.rs:422-455`); `apple/HavenApp/ScheduledStore.swift` (30s timer, encrypted at rest, picker
UI); `android/.../core/ScheduledStore.kt`. *(Only the relay timed-release variant — "Option B" in
`SCHEDULED-MESSAGES.md` — is genuinely unbuilt.)*

### ✅ Notifications
Blind APNs relay: a self-hosted Cloudflare Worker (`push/worker.js`) holds `nodeId → token` in KV
and forwards **sealed** payloads it never reads; the Notification Service Extension
(`apple/HavenNotificationService/`) decrypts on-device and falls back to a generic banner. Push
notifications and registrations are both signed. Android uses a foreground `ConnectionService` for
real-time delivery plus a 15-minute `WorkManager` poll — **no FCM, no Google**.

### ✅ Windows / Linux desktop (M8)
Tauri 2; the Rust backend links the core directly — a real iroh peer, not a web client. Feed,
circles, DMs, stories, camera, media, WebRTC mesh calls + screen share, tray, notifications, BYO
storage, plus a headless relay in the same binary (`--headless`). Installers ship from
`release.yml`. **MSIX packaging + Store submission are already automated** and gated on secrets —
no code-signing certificate is needed, because the Store re-signs (`STORE-AUTOPUBLISH.md`).
*(Gaps: Outstanding #4, #6, #7.)*

### ✅ Android (M8)
Native UniFFI → Kotlin/JNI (Jetpack Compose + Material 3, minSdk 29). Identity in an
Android-Keystore-backed `EncryptedSharedPreferences` (`core/HavenCore.kt:85-97`), circles, feed,
DMs, reactions/comments, stories, QR handshake, cross-device media chunks + mailbox, WebRTC mesh
calls + screen share, notifications, nearby, scheduled messages, avatar publish, in-app browser,
music search, DM parity + own-device sync. See `ANDROID-PARITY.md`. *(Gaps: Outstanding #3, #5,
#10, #11, #12.)*

### ✅ Launch surface (M9 / M10)
Marketing page live at https://wemiller.com/apps/haven/. TestFlight pipeline via rocket
(`.local-ci.conf` → `rocket build Haven`). Export compliance answered —
`ITSAppUsesNonExemptEncryption = NO`, no ASC declaration needed (`EXPORT-COMPLIANCE.md`). App Store
screenshots shipped (`docs/appstore-screenshots/`). CHANGELOG + docs + README kept current on every
push.

---

## Not started

- **MLS hardening** (`mls-rs` + a hybrid-PQ ciphersuite) — per-message forward secrecy and
  post-compromise secrecy. Gated on a PQ ciphersuite (D3). This is the single largest outstanding
  *cryptographic* item, and every doc above is now honest about not having it.
- **D16 Phase 4**: live device-to-device delivery + always-on personal store-and-forward (ordered
  backlog cache).
- **OpenTofu modules** for one-command relay deploy (AWS / GCP / Azure / Hetzner / Fly / DO / R2 /
  Oracle / bare VPS). Confirmed absent — no `.tf` anywhere in the repo.
- **Relay self-registration to discovery**; true two-machine field run.
- **AUR + Flathub publication.** PKGBUILDs exist in-repo (`packaging/aur/`); nothing in CI
  publishes them, and there is no Flathub submission step. See `LINUX.md`.
- **Microsoft Store listing** — blocked only on creating the 4 Azure AD secrets.
- **Group-gossip cache** for the fallback chain.
- ~~**Xcode Cloud CI**~~ — **shipped.** The `Main` workflow archives iOS + macOS and distributes to
  TestFlight (`apple/ci_scripts/ci_post_clone.sh` builds the xcframework; a root shim execs it).
  Scoped to `apple/`, `core/`, `ci_scripts/` so unrelated pushes don't burn compute.

  Both paths are valid, and which one you need depends on the build machine's OS:
  - **Local rocket CI works by design** on an official OS release, and is the faster loop.
  - **Xcode Cloud is required while the build Mac runs a BETA OS.** Apple rejects locally-archived
    binaries with ITMS-90301 ("not currently accepting applications built with this version of the
    OS") — that's what stopped 1.0.5 on 2026-07-15 (macOS 27.0 beta), and build 191 shipped through
    Xcode Cloud instead. Note 187 shipped from the same beta Mac two days earlier: Apple tightened
    acceptance in between, so this is a moving line, not a fixed rule.

## Toolchain (this machine)

Rust (rustup) + Apple targets (iOS device/sim, `aarch64-apple-darwin`), `uniffi-bindgen`, cargo,
Xcode, XcodeGen, swift, Android NDK + `cargo-ndk` + JDK 17 pin.

> **Android build gotcha:** the Rust `.so` + UniFFI bindings are gitignored and are **not** rebuilt
> by `assembleDebug`. Run `android/build-rust.sh` after **any** `core/` change, or a locally-built
> APK ships a stale core. CI rebuilds the core itself.
</content>
