# QA — Soren 🦉

Haven's automated QA runs through **Soren**, a pluggable test-suite runner (the
QA counterpart to Rocket — Rocket ships, Soren guards). Soren lives in the shared
tools repo at `_shared/soren/`, not in Haven; Haven plugs in via
[`soren.config.mjs`](../soren.config.mjs) at the repo root.

> *"Nothing gets past the night watch."*

## Run it locally

From the Haven repo root:

```sh
node ../_shared/soren/soren.mjs doctor Haven         # probe toolchain + per-suite readiness
node ../_shared/soren/soren.mjs run    Haven         # run every suite
node ../_shared/soren/soren.mjs run    Haven core    # just the core Rust suite
node ../_shared/soren/soren.mjs run    Haven android # unit + (on-demand emulator) connected
node ../_shared/soren/soren.mjs run    Haven vm-linux  # launch the Linux desktop VM (UTM)
node ../_shared/soren/soren.mjs migrate Haven        # the migration/regression harness only
```

### Local toolchain — what Soren resolves for you

Soren no longer relies on your shell having the Android/VM tools on `PATH`; it
resolves them itself (and `soren doctor Haven` will show each as ✓):

- **JDK 17** — pinned to `/opt/homebrew/opt/openjdk@17` (macOS's `/usr/bin/java`
  is a stub that reports *"Unable to locate a Java Runtime"* — Soren ignores it).
- **Android SDK** — `ANDROID_HOME` defaults to
  `/opt/homebrew/share/android-commandlinetools`; `adb` and `emulator` are taken
  from there and put on the gradle run's `PATH`. Works even when `ANDROID_HOME`
  is unset in your shell.
- **Emulator** — the `android` suite reuses a running emulator if there is one,
  otherwise boots the `haven_phone` AVD headless, waits for `sys.boot_completed`,
  then runs `connectedDebugAndroidTest`. It **leaves the emulator running** for
  faster reruns (set `stopEmulator: true` in the suite to shut it down).
- **UTM** — `utmctl` at `/Applications/UTM.app/Contents/MacOS/utmctl`; the
  `vm-*` suites drive VMs by UUID.
- **iCloud conflict copies** — before every cargo / gradle / xcodebuild run,
  Soren sweeps *every* `"<name> <N>.<ext>"` conflict copy (not just `" 2.*"`),
  including `.rlib` in `target/` and `.dex` in `build/`, aside to `*.soren-dup`
  (reversible — never a delete). This is the #1 build-reliability fix on this
  iCloud-synced tree.

`run`/`ci` exit non-zero on any failure. `ci` also writes `soren-junit.xml` +
`soren-results.json`. If you've linked Soren onto your PATH (`cd _shared/soren &&
npm link`), it's just `soren run Haven`.

## The suites

| suite | type | covers | needs |
|---|---|---|---|
| `core` | cargo | the whole Rust workspace — `haven-p2p`, `haven-ffi` (**incl. the FFI migration harness**), `haven-net`, `haven-relay`, `haven-s3`, `demo` (`cargo test --workspace`) | Rust toolchain (the runner bakes in the Homebrew-rustup PATH fix) |
| `migrate` | cargo | the `haven_ffi` package alone — the upgrade/migration regression harness | Rust toolchain |
| `ios` | xcodebuild-test | the `Haven` scheme's tests (HavenUITests) on an iOS simulator | macOS + Xcode + a simulator |
| `macos` | xcodebuild-test | the native `HavenMac` scheme, macOS destination | macOS + Xcode |
| `android` | gradle | `testDebugUnitTest` always; `connectedDebugAndroidTest` after reusing/booting the `haven_phone` AVD (skipped, never hung, if it can't boot) | JDK 17, Android SDK/NDK, the Rust `.so` from `android/build-rust.sh` |
| `desktop` | cargo | the Tauri Rust side (`desktop/src-tauri`) | Rust + (Linux) the WebKitGTK build deps |
| `desktop-ui` | node-check | `desktop/ui/app.js` syntax gate | node |
| `vm-linux` | utm | **launches** the `haven-linux` UTM VM and confirms it reaches `started` (reuses an already-running VM) | UTM + the VM present |
| `vm-windows` | utm | **launches** the `Windows` UTM VM and confirms `started` | UTM + the VM present |

`soren migrate Haven` runs `migrate` + `core` (both carry the migration harness).
Locally verified: `soren run Haven core` → **182 passed, 0 failed**.

## CI — the release-candidate gate

[`.github/workflows/qa.yml`](../.github/workflows/qa.yml) runs Soren across a
matrix on every **`vX.Y.Z-rc.N`** tag (and manual dispatch): `apple` on a macOS
runner (ios + macos), `core` / `desktop` / `android` on Ubuntu. Each job uploads
its JUnit as an artifact.

### How Soren is obtained in CI (it's in a *separate* repo)

Haven's CI checks out only Haven. Soren lives in `github.com/blaineam/rocket`
(the `_shared` working copy locally). So each qa.yml job does a **second checkout
alongside Haven** under the workspace:

```
$GITHUB_WORKSPACE/Haven      ← this repo        (checkout path: Haven)
$GITHUB_WORKSPACE/_shared    ← the tools repo   (checkout path: _shared)
```

then runs `node ../_shared/soren/soren.mjs ci Haven …` from inside `Haven/` — the
exact `Apps/Haven ↔ Apps/_shared` sibling path used locally. Soren is
zero-dependency pure Node, so there's nothing to install after checkout.

- **Public tools repo** → no token needed.
- **Private tools repo** → `github.token` can't read a second repo, so set a PAT
  as the repo secret **`SHARED_REPO_TOKEN`** (the checkout falls back to it).

*(Alternative considered: vendoring Soren into Haven. Rejected — checkout-alongside
keeps one source of truth. See `_shared/soren/docs/ci.md`.)*

## rc tags → the release flow

Haven ships one product version everywhere; a release is cut by tagging. The
**`-rc.N` suffix** turns a tag into a **release candidate**: full QA + build
verification, but **zero production publishing**. When the board is green, cut the
clean `vX.Y.Z` tag for the official release.

```
  bump MARKETING_VERSION to 1.0.7
        │
        ▼
  git tag v1.0.7-rc.1 && git push --tags     ← QA candidate
        │   qa.yml runs the full Soren matrix
        │   release.yml + android.yml BUILD everything, publish NOTHING to prod
        ▼
  board green?  ── no ──▶ fix, tag v1.0.7-rc.2, repeat
        │ yes
        ▼
  git tag v1.0.7 && git push --tags          ← official cut
            release.yml cuts the GitHub Release; android → Play; MS Store submit
```

### Tag → action matrix

| action | `vX.Y.Z-rc.N` (candidate) | `vX.Y.Z` (official) |
|---|---|---|
| **qa.yml** (Soren matrix) | ✅ runs | ➖ not triggered (rc-only) |
| release.yml **meta gate** | ✅ passes (core X.Y.Z must match MARKETING_VERSION) | ✅ passes |
| release.yml **relay / desktop / flatpak builds** | ✅ build (CI verify) | ✅ build |
| release.yml **MSIX packaging** | ✅ packaged (CI verify, artifact) | ✅ packaged |
| release.yml **Microsoft Store submit** | ❌ **skipped** | ✅ (when Store secrets set) |
| release.yml **public GitHub Release** (`publish` job) | ❌ **skipped** | ✅ cut |
| release.yml **AUR push** | ❌ skipped (needs `publish`) | ✅ (when secret set) |
| android **APK/AAB build** | ✅ build (CI artifact) | ✅ build |
| android **Play upload** | ✅ **internal track only** (production is downgraded→internal) | track per `PLAY_TRACK`/dispatch |
| android **attach to GitHub Release** | ❌ **skipped** | ✅ (until Play public) |
| **App Store submit** (`rocket submit`, manual) | — you don't submit an rc | ✅ when you choose |

The guards are literal `!contains(github.ref, '-rc')` conditions on the
production-publish steps (and a production→internal downgrade in android's track
resolver). Pre-release/internal tracks and all artifact/CI-verify builds stay
intact on rc, so a candidate is a real, installable build for testers — it just
never reaches a production store.

> The App Store has no submit step in these workflows — iOS/macOS submission is a
> deliberate manual `rocket submit` (see `_shared/rocket`). You simply don't run
> it for an rc.

## Windows / Linux desktop — the VM runbook (honest status)

CI covers what a hosted runner can: the desktop **Rust** tests (`desktop` suite)
and the **web-UI** syntax gate (`desktop-ui`) run on Ubuntu in qa.yml, and
release.yml compiles the Windows + Linux installers on every rc (build
verification). What a headless runner **cannot** do is exercise the actual GUI on
real Windows / a real Linux desktop. That is a **manual / semi-automated VM
harness**, not a one-command script — documented here honestly.

**Automatable today**
- `desktop` + `desktop-ui` Soren suites (in CI + locally).
- Installer **build** verification (release.yml: `.msi`/NSIS `.exe`/`.msix`,
  `.deb`/`.rpm`/AppImage, Flatpak) — proves the bundles compile and package.
- **VM launch** via the `vm-linux` / `vm-windows` Soren suites (UTM). `soren run
  Haven vm-linux` runs `utmctl start` on the VM (by UUID), waits until it reports
  `started`, and reports it up — reusing an already-running VM. If UTM or the VM
  is missing, the leg **skips with a clear message; it never hangs.**
- A local smoke suite: add a `cmd`-type Soren suite that runs
  `cargo tauri build` (or a headless launch) against `desktop/src-tauri` on the
  host OS, if you want a gate beyond `cargo test`.

> **Honest status — in-guest VM tests are NOT wired yet.** The `vm-*` legs today
> are **launch-only**: a green `vm-linux` means "the VM booted", *not* "Haven was
> installed and exercised inside it". No guest test agent is set up. The runner
> already supports it: add a `guest: { host, user, cmd }` block to the suite and
> the leg will `ssh` into the guest, run `cmd` (a build/smoke/test), and gate the
> leg's pass/fail on its exit code. Until that guest agent exists, the manual VM
> checklist below is still the real GUI acceptance pass.

**Manual VM steps (per rc, before promoting to `vX.Y.Z`)**
1. **Windows 11 VM** (VMware Fusion/Workstation): download the rc's `desktop-windows`
   CI artifact (the `.msi` or NSIS `-setup.exe`), install, launch Haven, and run
   the smoke checklist — onboarding, pair a device, send/receive a message + a
   media item, a call, quit/relaunch (session persistence).
2. **Linux desktop VM** (e.g. Ubuntu + GNOME, and a SteamOS/Steam Deck image for
   Flatpak): install the rc `.deb`/AppImage (and `haven.flatpak`), run the same
   smoke checklist. Confirm the tray/appindicator and `xdg` MIME handoff.
3. **Relay**: on a Linux VM (or a Pi), drop in the rc `haven-relay-<target>`
   binary and confirm a cross-NAT connection through it.
4. Record pass/fail in the rc's QA notes. Any fail → new `-rc.N`.

**Why it's not fully scripted:** driving a GUI installer + first-run flow across
VMware guests reliably needs per-OS UI automation (WinAppDriver / AutoHotkey on
Windows; `dogtail`/`ydotool` on Linux) plus snapshot management — worth building
incrementally, but today the honest boundary is: **Soren + CI automate the code
and the build; the GUI acceptance pass on Windows/Linux is a human running the
checklist in a VM.** As those UI-automation harnesses land, wrap each as a
`cmd`-type Soren suite so `soren run Haven` grows to cover them too.
