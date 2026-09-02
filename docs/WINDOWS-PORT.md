# Windows (and Linux) desktop port — Tauri 2

**Goal:** ship Haven on Windows as a real native client at **feature parity with iOS** —
a GUI app *and* a headless relay, exactly like the macOS target is meant to be — built on
the **same Rust core** the iPhone and Android apps use.

**Stack:** [Tauri 2](https://tauri.app) (Rust backend + WebView2 frontend). Chosen because:

- The backend is Rust, so it links the shared core (`haven_ffi`, which re-exports
  `haven-p2p` + `haven-net`) **directly as a crate — no UniFFI hop**. The iroh peer runs in
  the native process, not the browser, so the "a browser can't be an iroh peer" problem
  that killed the web client (see [`WEB-PARITY.md`](WEB-PARITY.md)) does **not** apply here.
- WebView2 (Edge/Chromium) gives camera (`getUserMedia`), WebRTC, `<video>`/`<audio>`, and
  an in-app browser for free — the media-heavy parity features that would fight a
  pure-native or immediate-mode GUI.
- One binary doubles as the **headless relay/mailbox** (`--headless`), like the invisible
  Mac relay.
- Packages to **MSIX/MSI/NSIS** for the Microsoft Store (free app, zero-recurring
  distribution mandate), and gives a Linux build (AppImage/deb) nearly for free later.

> The Rust core is platform-agnostic; nothing in `core/` changes for Windows. This is a
> **UI + platform-glue** project, the same shape as the Android port.

## Layout

```
desktop/
  src-tauri/            Rust backend (the "FeedStore"/"HavenNet" equivalent)
    src/
      main.rs           entry; --headless → relay, else GUI
      lib.rs            Tauri builder + run_headless()
      wire.rs           byte-exact port of the Wire protocol (interop with iOS/Android)
      engine.rs         port of Android HavenNet.kt: HavenSocial + HavenNode, handshake,
                        persistence, mailbox poll, relay hosting, media chunks
      store.rs          seed in the OS secure store (Credential Manager / Keychain /
                        Secret Service) + prefs.json + state blob
      localmedia.rs     content-addressed, sealed-at-rest media store
      commands.rs       the invoke() surface the WebView calls
    tauri.conf.json     window + bundle (msi/nsis) config
    icons/              brand icon set (make_icons.py)
  ui/                   static WebView2 frontend (no bundler)
    index.html  styles.css  app.js
    vendor/             qrcode.js (QR show) + jsQR.js (camera scan)
```

## Build / run (dev, on any OS)

```bash
# one-time
cargo install tauri-cli --version '^2'

cd desktop/src-tauri
cargo tauri dev          # launches the GUI (native WebView)
cargo run -- --headless  # runs ONLY the relay, prints a relay node id to share
```

`cargo tauri dev` works on macOS/Linux too (native WebView), so the whole UI + core
integration is developed and verified locally, then cross-built for Windows.

## Build (artifacts)

- **CI:** [`.github/workflows/desktop.yml`](../.github/workflows/desktop.yml) runs the
  core + desktop unit tests, then builds on `windows-latest` (.msi + NSIS .exe) and
  `ubuntu-latest` (.deb + .AppImage) and uploads them as artifacts.
- **On Windows:** `cargo tauri build` → `.msi` + NSIS `.exe` in `target/release/bundle/`.
- **Cross from macOS/Linux:** `cargo tauri build --target x86_64-pc-windows-msvc` via
  [`cargo-xwin`], or the Windows CI runner.

### Microsoft Store (MSIX)

> **This is automated — don't do it by hand, and do NOT buy a code-signing certificate for it.**
> An earlier version of this section told you to wrap the MSIX with `makeappx` and sign it with a
> paid publisher cert. That is wrong and would cost money for nothing.
> **See [`STORE-AUTOPUBLISH.md`](STORE-AUTOPUBLISH.md) for the real flow.**

What actually happens today, in [`.github/workflows/release.yml`](../.github/workflows/release.yml):

1. Tauri builds the MSI/NSIS `.exe` (`release.yml:200-207`).
2. CI packages the `.msix` itself with `makeappx` from `desktop/msix/AppxManifest.xml.in`
   (`release.yml:212-241`) — **unsigned**. There is no `signtool` call anywhere in CI, by design:
   **the Microsoft Store re-signs the package on ingestion**, so no publisher cert is needed.
3. CI submits it with `msstore publish` via the MSStore CLI (`release.yml:243-250`).

Both the packaging and publish steps are **gated on Store secrets being present** and are
`continue-on-error`, so with no secrets configured they simply skip. The 8 required secrets are
listed in `STORE-AUTOPUBLISH.md`.

**Current state: the Microsoft Store is the channel.** The Windows app is **live on the
[Microsoft Store](https://apps.microsoft.com/store/detail/9NKTFH1MF4LM)**. The GUI installers are **no longer attached to GitHub
Releases** — `PUBLISH_WINDOWS_TO_GH` is set to `false`, so `release.yml`'s publish job strips the
`.msi`/`.msix`/`setup.exe`. The only direct build is the short-retention `desktop-windows` CI
artifact (used for the Store submission and manual testing). The Windows relay `.exe` — a self-host
CLI, not the Store app — still ships on the Release.

## Parity table (iOS → Windows/Tauri)

| iOS feature | Windows approach | Status |
|---|---|---|
| Crypto / identity / circles / feed reducer | Same `haven_ffi` crate, linked directly | **Done** — identical engine |
| iroh P2P transport + mesh relay | Same `haven-net` crate (native) | **Done** |
| Wire protocol (Hello/Event/MediaReq/Chunk/Relay/Call) | `wire.rs` + `callwire.rs`, byte-exact | **Done** |
| Keychain key storage | OS secure store via `keyring` (Credential Manager) | **Done** |
| Persistence + multi-circle + DMs | `engine.rs` + `store.rs` | **Done** |
| Posts / comments / reactions / edit / unsend | commands + feed reducer | **Done** |
| Stories (24h) | story flag + viewer | **Done** |
| QR invite show + camera scan + verified handshake | `qrcode.js` + `jsQR` + WebView camera | **Done** |
| Photo/video attach + inline render | HTML file pick → downscale → sealed local store → `data:` URL | **Done** (image downscale in JS; video transcode TODO) |
| Circle relay / mailbox (host + adopt) + offline delivery | `RelayServerHandle` in-process + `RelayClient`; `--headless` | **Done** |
| Cross-device media bytes (frame 3/5 chunks) | ported in `engine.rs`; covered by an in-crate round-trip test | **Done** (live device-test pending) |
| Local notifications + tray | `tauri-plugin-notification` (native toast) + system tray (show / host relay / quit) | **Done** |
| Apple Music | portable track refs + deep-link (no inline catalog playback) | **Redesign** — same as Android |
| Audio/video/group calls (WebRTC) | `callwire.rs` frames 10–18/21 in Rust; WebView2 `RTCPeerConnection` full mesh in `app.js`; signaling over the sealed iroh channel | **Done** (live device-test pending) |
| Screen share | WebRTC `getDisplayMedia` (reuses the mesh) | **Done** — `desktop/ui/app.js:2709-2733` (Wayland/SteamOS via the xdg-desktop-portal) |
| Sensitive content blur | core exposes `flag_sensitive`/`sensitive_refs`; desktop **consumes** the flag — `sensitive_refs` is wired through `desktop/src-tauri/src/commands.rs:364` and fetched at `desktop/ui/app.js:1817`, with the tap-to-reveal cover at `:1822` — but never **authors** one | **Partial** — the blur works: a photo an iPhone flags sensitive renders blurred on desktop. There is still no classifier, so desktop can never originate a flag (only Apple's on-device SCA does) |
| Profile avatar | settable in the UI, stored in local prefs — **never published to peers** | **Broken/local-only** — `desktop/src-tauri/src/engine.rs:1398` passes `String::new()` instead of `profile.avatar` into the signed profile card, so contacts never see your desktop-set photo. (The code comment there claims this "matches Android"; it does not — `android/.../HavenNet.kt:1105` passes `profile.avatarB64`.) |
| S3 BYO-bucket | `core/haven-s3` — one shared SigV4 client (AWS/R2/B2/MinIO), wired into the engine's mailbox | **Done** (SigV4 unit-tested vs AWS vector; live bucket test pending) |
| Nearby offline mesh | no desktop equivalent of MultipeerConnectivity; later via local mDNS/BLE | **Deferred** |
| Push (APNs/FCM) | n/a — desktop stays running; headless relay covers offline | **n/a** |

## Done so far

- ✅ Compiles + unit/integration tests green (wire, callwire, SigV4 vector, two-party round-trip).
- ✅ Headless relay verified end-to-end (identity → OS keychain → iroh node → relay link).
- ✅ WebRTC calls: `callwire.rs` + full-mesh `RTCPeerConnection` in `app.js`, signaling on the sealed channel.
- ✅ Native notifications + system tray (show / host relay / quit).
- ✅ Shared SigV4 S3 mailbox in `core/haven-s3`, wired into the engine.
- ✅ CI builds Windows (.msi/.exe) + Linux (.deb/.AppImage) artifacts.

## Remaining milestones (recommended order)

1. **Publish the avatar** — one-line fix at `desktop/src-tauri/src/engine.rs:1398` (pass
   `profile.avatar`, not `String::new()`), and delete the incorrect "matches Android" comment.
2. **Render the sensitive-content blur** from federated `sensitive_refs` (no classifier needed —
   Apple peers already federate the flag; desktop just ignores it today).
3. **Verify the Windows install path on real hardware.** ⚠️ **Untested** — the `.msi`/`.exe` are
   built by CI and have never been run through an install on a real Windows machine (the available
   VM can't build installers). Treat Windows as beta until someone installs it.
4. **Live cross-device interop test**: Windows ↔ iPhone ↔ Android — text post, DM, media bytes, and a call over iroh.
5. **Microsoft Store submission** — packaging + publish are already automated in `release.yml`; this
   is blocked only on creating the 4 Azure AD secrets (see `STORE-AUTOPUBLISH.md`). No cert needed.
6. **Video transcode** on attach (images already downscale in JS).

## Notes / gotchas

- `windows_subsystem = "windows"` is intentionally **not** set yet so `--headless` can
  print to the console on Windows; the Store/GUI build will attach-console conditionally.
- The seed lives in the OS secure store; `load_seed()` distinguishes *no entry* (new
  device) from a locked/error read so a transient failure never clobbers an identity
  (same rule as the iOS Keychain locked-read fix).
- Media refs are `sha256(plaintext)` and stored **sealed at rest** — byte-compatible with
  iOS `MediaStore` / Android `LocalMedia`, so the cross-device chunk fetch interops.

[`cargo-xwin`]: https://github.com/rust-cross/cargo-xwin
