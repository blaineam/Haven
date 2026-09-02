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
| `fabric` | cargo | Path proxy + WebSocket hairpin + Haven-first DERP policy (`haven-net` integration) | Rust |
| `vm-linux` | utm | **launches** the `haven-linux` UTM VM and confirms it reaches `started` (reuses an already-running VM) | UTM + the VM present |
| `vm-windows` | utm | **launches** the `Windows` UTM VM and confirms `started` | UTM + the VM present |
| `e2e` | cmd | **full cross-device E2E with perf gates** — see below | DEBUG builds of all four clients |

## Full cross-device E2E (`soren run Haven e2e`)

`Scripts/qa-e2e-full.mjs` assembles the whole fleet — iOS Simulator + Android
emulator + the isolated **HavenStub** (relay host *and* the "friend" account B)
+ Tauri desktop, the last three linked to the iOS identity (account A) — then
exercises every in-app action and asserts convergence on **every** device:

profile edit · circle create + invite · membership · text/photo/video posts ·
story + caption · file post · music card · DMs both directions (+ own-device
echo) · reactions from two devices · comments — plus the **media-blob gate**:
the post's media must actually be present (not just the event) on every device.

The **call matrix** runs every caller × answerer pair (each platform dials the
stub *and* answers a stub-originated call). Per pair: the callee rings, the ring
**survives early media** — asserted as `ringing == true` *and* `in_call != true`,
both halves, so a callee that never rang cannot pass it for free — accept clears
the ring, the caller goes live on the **ACCEPT** (never on transport), and the
hangup ends the call on every device.

Every step records propagation latency (author → each device) against budgets
(`E2E_BUDGET_TEXT` 30s, `E2E_BUDGET_MEDIA_EVENT` 45s, `E2E_BUDGET_MEDIA_BLOB`
120s), and each run appends to `build/e2e-history.jsonl` — a step that gets
**>2× slower** than the previous run fails the suite even inside budget, so
performance regressions are caught the same day they land.

Safety: the mac leg is **always** `com.blaineam.kith.qa.stub` under
`HOME=/tmp/haven-mac-stub-home`; the desktop leg always uses the `qa-matrix`
data dir. The personal account, container, and daily-driver desktop data root
are never touched, and the script refuses to run otherwise.

Subsets + reuse: `E2E_STEPS=post,dm node Scripts/qa-e2e-full.mjs`,
`E2E_BOOTSTRAP=skip` to reuse a hot fleet, `E2E_KILL=1` to tear down after.

### qa-cmd v2 — the cross-platform QA driver contract

DEBUG builds of all four clients accept a one-shot JSON drop file and answer
with a dump. Paths: iOS/macStub `Application Support/qa-cmd.json` (+
`haven://qa` deep link to poke iOS); Android `/sdcard/Download/qa-cmd.json`
(+ `am start -d haven://qa`); desktop `<data-dir>/qa-cmd.json` (file watcher).

Android scoped storage: adb-pushed files in `/sdcard/Download` are shell-owned,
so the DEBUG build declares `MANAGE_EXTERNAL_STORAGE` (debug manifest overlay
only) and the harness grants it — `adb shell appops set com.blaineam.haven
MANAGE_EXTERNAL_STORAGE allow` (qa-e2e-bootstrap.sh does this on install).
`/data/local/tmp/<name>` is accepted as a fallback for every staged input. The
Android driver also adopts `/sdcard/Download/qa-seed.txt` at startup when the
install has no identity yet (never over an onboarded/seedless one), and dumps
its account + device hexes to `/sdcard/Download/qa-device-hex.txt` for the
stub-authorization step.

```json
{"op":"post|story|dm|react|comment|profile|circle_create|circle_invite|file|music_post|dump|mark_read|link_constraint
      |call|call_accept|call_end|call_speaker|call_route_legacy",
 "body":"…","media":"photo|video","photo_path":"…","video_path":"…","file_path":"…",
 "target_id":"<event id>","emoji":"❤️","dm_to":"<64hex>","name":"…","circle_id":"…",
 "music":{"title":"…","artist":"…"},"caption":"…","level":"normal|low|ultra|auto","on":true}
```

**`link_constraint`** forces the low-data tier (`"level"`), because the satellite path is otherwise
untestable anywhere but a real satellite bearer: `ultra` comes only from
`NWPath.isUltraConstrained` / `TRANSPORT_SATELLITE`, which a simulator and an emulator never report,
and the user preference deliberately cannot escalate to it. Without this the preview tier would ship
unverified on the exact path it exists for. `"auto"` hands control back to the real path monitor.
DEBUG-only on every client, so no release build can be pushed into a state the network is not in.
Desktop accepts it too, and there it is the *only* way in — desktop has no path monitor at all.

**`call_speaker`** (`"on"`, or omit it to toggle) flips the in-call speaker, and **`call_route_legacy`**
(`"on"`) pins Android's routing to its pre-31 fallback. Both exist because in-call audio ROUTING is
the one call control whose effect lands outside the app — in the platform's audio router — so the
app's own `speaker_on` flag cannot see whether it worked: `AudioManager.setCommunicationDevice`
reports failure by *returning false*, not by throwing, and the flag flips either way. The dump
answers with both `call.speaker_on` (asked) and `call.audio_route` (granted, read back from
`getCommunicationDevice()` — `speaker`/`earpiece`/`wired`/`bluetooth`/`usb`/`none`), and they agree
until the routing is broken.

`call_route_legacy` is the `link_constraint` argument applied to an SDK gate. Android's minSdk is 29
so the deprecated-`isSpeakerphoneOn` path genuinely SHIPS, but every Android in the fleet is API 35
and would never take it — without the pin, that branch is covered by the compiler and nothing else.
The e2e call step sweeps speaker on/off through **both** routing paths on both android pairs; the
second pair runs after a full teardown, which is what proves hangup hands audio back to the system
instead of leaving a communication device pinned for the next call. DEBUG-only, like every op here.

> **The emulator has no earpiece.** `haven_phone` reports `audio_devices: "speaker"` and nothing
> else, so on the API 31+ path there is no `TYPE_BUILTIN_EARPIECE` to select and speaker-off
> correctly falls back to `clearCommunicationDevice()` — the route stays on the only device present.
> Asserting `OFF → earpiece` there can never pass, so the sweep reads `call.audio_devices` and
> asserts *the platform default* instead, saying so in the check name. The pre-31 sweep still
> exercises both directions on the same emulator, because `isSpeakerphoneOn` is a framework-tracked
> flag rather than a device selection. **Earpiece routing on API 31+ therefore needs real hardware
> to verify** — measured 2026-09-02, where the fallback went green both ways and the modern
> earpiece leg was the one thing the emulator could not prove.


Every op (and `{"op":"dump"}`) refreshes `qa-dump.json` next to the drop file
(Android: `/sdcard/Download/qa-dump-<pkg>.json`):

```json
{"device":"ios","account_hex":"…","ts_ms":0,
 "posts":[{"id":"…","body":"…","circle":"…","story":false,"caption":null,
           "media_refs":["…"],"media_present":[true],
           "reactions":{"❤️":1},"comments":[{"id":"…","body":"…"}]}],
 "dms":{"<peer-hex>":[{"id":"…","body":"…","media_present":[]}]},
 "profile":{"name":"…"},"circles":[{"id":"…","name":"…","members":["…"]}]}
```

Liveness and timing on the desktop leg: every dump carries `dump_seq` (strictly increasing per
successful write — the orchestrator warns when it sticks, which means the driver, not delivery),
and the driver logs any op or 5 s heartbeat dump slower than the orchestrator's poll to
`tauri.log` **with the phase it went into**:

```
qa-cmd: op 'post' took 812 ms + dump 4210 ms (feed=3900ms dms=110ms meta=40ms diag=120ms write=40ms) — slower than the orchestrator polls
qa-dump: heartbeat dump took 19004 ms (feed=18950ms …) — slower than the orchestrator polls
```

`feed`/`dms`/`diag` wait on the engine state (and prefs), `meta` on prefs, `write` is the file
swap — so a slow `feed` behind a `selfsync: N roster wire(s) took … ms` line is a lock hold to
shorten, not a slow disk. A heartbeat that parks also parks the next command behind it (one
driver thread), so a step that "took 30 s" on desktop should be read against these lines first.
The engine lock names its own long holds on every platform — `engine lock held 1840 ms by
…/haven-ffi/src/lib.rs:7091` (call site of the `lock()`), threshold one second — so a slow `feed`
phase can be matched to the exact engine call that held it.

The desktop leg is a DEBUG build (the QA driver only exists there), but its Rust core and crypto
crates are compiled optimized (`[profile.dev.package.*]` overrides in `desktop/src-tauri/Cargo.toml`):
Android and the Apple apps link a release core, and an unoptimized core made one key-commit
`receive()` hold the engine lock 17–49 s — which is where the desktop's "materially longer
convergence cycle" (the 6× budget multiplier) came from. Keep those overrides when adding a
crypto dependency to the core.

The v1 keys (`post`/`story`/`dm_to`+`dm`/`call_to` without `op`) stay accepted
on iOS for the older matrix scripts.

Two contract points every driver honors:

- **Content ops honor `circle_id`** — `post` / `story` / `file` / `music_post`
  author into the named circle (iOS/Android switch the active circle through the
  UI's own picker path; desktop passes the id to the engine author call). A
  missing or **unknown** id keeps current behavior — the active circle
  (desktop: `default`). `dm` is unaffected (its circle is the DM thread).
- **Active-cadence semantics** — a qa op models a user actively using the app.
  Every recognized op resets the adaptive idle multiplier exactly like the real
  user-activity/foreground hook; every **mutating** op additionally nudges one
  immediate mailbox poll so authored content uploads now. The non-mutating
  `dump` op never forces a poll — receivers converge at their real
  active-cadence poll, keeping measured convergence latency honest.

### Multi-device fabric (Mac + iOS Simulator + Android Emulator)

#### What Soren **does** prove (release gate)

| Suite | Actually exercises |
|---|---|
| `core` / `fabric` / `desktop` | Rust unit + path-proxy/hairpin **integration** (no UI) |
| `android` | JVM unit + **instrumented** tests on AVD (installs *test* APK; may not leave Haven as your launcher app) |
| `ios` | XCUITest on simulator (launches Haven for those tests only) |
| `macos` | **xcodebuild build only** — does **not** launch the Mac app |

The Apple legs of the fleet (the iOS simulator and the HavenStub Mac relay host) are DEBUG
builds, and a DEBUG build **crashes** on any engine call that reaches the main thread
(`EngineTripwire`, see `apple/HavenApp/Engine.swift`). A green e2e run is therefore also the
proof that the SwiftUI layer stayed on its read model — every `HavenSocial` call ran on the
engine actor. A leg that dies with `engine call on main: <function> (line N)` in its log is a
regression of that invariant, never an environmental failure.

**Soren green is not “three devices held a mesh call through a Haven relay.”** Treating it as that is a false positive.

#### Live multi-device smoke (required before claiming device QA)

```sh
# Installs + launches real Haven on emu + sim + Mac, starts path proxy, screenshots:
Scripts/live-multi-device-smoke.sh
# Artifacts under build/live-smoke-*/
```

This script **fails** if Haven is not running on a surface. It still **skips** full mesh call automation (`CALL_E2E` not wired).

Also:

```sh
cargo test -p haven-net --test path_proxy_hairpin
Scripts/fabric-multi-device-qa.sh
node ../_shared/soren/soren.mjs run Haven fabric
```

**Pointing clients at the Mac host’s path proxy:**

| Client | Path-proxy base |
|---|---|
| iOS Simulator | `http://127.0.0.1:8675` |
| Android Emulator | `http://10.0.2.2:8675` |
| Physical device | `http://<Mac-LAN-IP>:8675` |

Probe: `curl -s http://127.0.0.1:8675/_haven`. Hairpin: `wss://…/webrtc/hairpin`.

`soren migrate Haven` runs `migrate` + `core` (both carry the migration harness).
Locally verified: `soren run Haven core` → **182 passed, 0 failed**.

## CI — the release-candidate gate

[`.github/workflows/qa.yml`](../.github/workflows/qa.yml) runs Soren across a
matrix on every **`vX.Y.Z-rc.N`** tag (and manual dispatch): `apple` on a macOS
runner (ios + macos), `core` / `desktop` / `android` on Ubuntu. Each job uploads
its JUnit as an artifact.

### How Soren is obtained in CI (it's in a *separate* repo)

Haven's CI checks out only Haven. Soren lives in `github.com/blaineam/ark`
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
| release.yml **GitHub Release** (`publish` job) | ✅ cut as a **pre-release**, under the rc tag | ✅ cut as the stable release |
| release.yml **AUR push** | ❌ skipped (stable only) | ✅ (when secret set) |
| android **APK/AAB build** | ✅ build (CI artifact) | ✅ build |
| android **Play upload** | ✅ **internal track only** (production is downgraded→internal) | track per `PLAY_TRACK`/dispatch |
| android **attach to GitHub Release** | ✅ attached to the rc pre-release | ✅ (until Play public) |
| **App Store submit** (`rocket submit`, manual) | — you don't submit an rc | ✅ when you choose |

The guards are literal `!contains(github.ref, '-rc')` conditions on the
production-publish steps (and a production→internal downgrade in android's track
resolver). Pre-release/internal tracks and all artifact/CI-verify builds stay
intact on rc, so a candidate is a real, installable build for testers — it just
never reaches a production store.

An rc **does** get a GitHub Release now, because a build that exists only as a CI
artifact is a build nobody can install. It is published under the rc's OWN tag
(`v1.1.4-rc.31`), with `prerelease: true` and `make_latest: false` — so it cannot
overwrite the stable release's assets, and `/releases/latest` (which the website's
download cards read) keeps pointing at the last stable version. AUR stays
stable-only: its PKGBUILDs build *from* the tag, so pointing them at a candidate
would make the package a moving target.

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
