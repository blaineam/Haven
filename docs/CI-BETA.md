# CI / Beta Distribution

How Haven's GitHub Actions produce downloadable installers for **every** platform so you can
link beta-testers to a fresh build. Everything runs on GitHub-hosted runners — no proprietary
services, no recurring cost beyond Apple's $99/yr developer program (used by the separate
Apple/App-Store pipeline — iPhone, iPad, and Mac ship on the App Store, not from CI).

---

## TL;DR — start a beta TODAY (no secrets)

```sh
git tag v0.1.0
git push origin v0.1.0
```

That single tag fans out to every platform job and produces **one GitHub Release** at
`https://github.com/blaineam/haven/releases/tag/v0.1.0` containing:

| Platform | Artifact(s) | Built with NO secrets? |
| --- | --- | --- |
| **Android** | `.apk` / `.aab` — **CI artifact only** (`PUBLISH_ANDROID_TO_GH=false`, Google Play is the channel) | ✅ **debug-signed** beta APK |
| **Windows** | `.msi`, NSIS `.exe` — **CI artifact only** (`PUBLISH_WINDOWS_TO_GH=false`, Microsoft Store is the channel) | ✅ unsigned (SmartScreen warns) |
| **Linux** | `.deb`, `.rpm`, `.AppImage` | ✅ |
| **SteamOS / Steam Deck** | `haven.flatpak` + pinned manifest | ✅ |
| **Relay daemon** | `haven-relay-<target>` + `.deb` | ✅ |

The Windows and Android GUI builds are **no longer attached to the public Release** — both repo
variables `PUBLISH_WINDOWS_TO_GH` / `PUBLISH_ANDROID_TO_GH` are set to `false`, so they come off
as the short-retention `desktop-windows` / `haven-android-apk` CI artifacts and ship to their
stores instead (see [`RELEASING.md`](RELEASING.md#release-channels--what-goes-where)). The Release
carries only the Linux, Flatpak, and relay builds.

Add the signing secrets later (below) and the *same* tag yields fully-signed/notarized builds.

---

## What each workflow does

| Workflow | Triggers | Produces |
| --- | --- | --- |
| `.github/workflows/release.yml` | `v*` tags, `workflow_dispatch` | Relay, Linux desktop, Flatpak → one Release (Windows GUI stripped via `PUBLISH_WINDOWS_TO_GH=false`, kept as the `desktop-windows` CI artifact; macOS ships on the App Store) |
| `.github/workflows/android.yml` | push to `main`, `v*` tags, `workflow_dispatch` | Android `.apk`/`.aab` → `haven-android-apk` CI artifact + Google Play upload (no longer attached to the Release — `PUBLISH_ANDROID_TO_GH=false`) |
| `.github/workflows/desktop.yml` | push/PR touching `desktop/` or `core/` | Windows/Linux installers as CI artifacts (no Release) |
| `.github/workflows/relay-release.yml` | `relay-v*` tags | Relay binaries only (hotfix path) |

On a `v*` tag, `release.yml` (publish job) and `android.yml` both call
`softprops/action-gh-release@v2` against the **same tag**, so all artifacts land in one Release.
softprops updates the existing Release if it already exists, so job ordering doesn't matter.

### Cutting a beta

- **Full release (all platforms):** `git tag vX.Y.Z && git push origin vX.Y.Z`.
  The tag string drives the version — it's stamped into `tauri.conf.json` and the relay crate.
- **Dry run / on-demand:** trigger any workflow from the Actions tab via **Run workflow**
  (`workflow_dispatch`). `release.yml` accepts a `version` input and builds everything but only
  *publishes* a Release on an actual tag.
- **Relay-only hotfix:** `git tag relay-vX.Y.Z && git push origin relay-vX.Y.Z`.
- **Always-fresh Android link:** every push to `main` rebuilds the APK as a CI artifact (below).

### Artifact download URLs

**Release assets** (after a `v*` tag) — stable, public URLs. These now carry only the Linux,
Flatpak, and relay builds; the Windows and Android GUI installers are no longer Release assets
(see the CI-artifact note below):

```
https://github.com/blaineam/haven/releases/download/vX.Y.Z/<file>
https://github.com/blaineam/haven/releases/latest          # human-facing "latest" page
```

e.g. `…/releases/download/v0.1.0/haven_0.1.0_amd64.deb`.

**CI artifacts** (per-run, e.g. a `main` push with no tag) — download from the run's summary page
under **Artifacts**, or via the API/`gh`:

```sh
gh run download --name haven-android-apk     # latest android.yml run's APK
```

Artifact names: `haven-android-apk`, `desktop-windows`, `desktop-linux`,
`flatpak`, `relay-<target>`.

---

## Repository secrets for fully-signed builds

Add these under **Settings → Secrets and variables → Actions → New repository secret**. None are
required for a beta — each platform's job *gates* on its secrets and falls back to an
unsigned/debug build when they're absent.

### Android (release-signed APK)

| Secret | What it is |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Your upload/signing keystore, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore (store) password |
| `ANDROID_KEY_ALIAS` | Key alias inside the keystore |
| `ANDROID_KEY_PASSWORD` | Password for that key |

Create the keystore + encode it:

```sh
keytool -genkey -v -keystore haven-release.keystore \
  -alias haven -keyalg RSA -keysize 2048 -validity 10000
base64 -i haven-release.keystore | pbcopy   # paste into ANDROID_KEYSTORE_BASE64
```

When all four are set, `android.yml` decodes the keystore to a temp file and runs
`assembleRelease`; `android/app/build.gradle.kts` reads `HAVEN_KEYSTORE_FILE` /
`HAVEN_KEYSTORE_PASSWORD` / `HAVEN_KEY_ALIAS` / `HAVEN_KEY_PASSWORD` (the workflow maps the
secrets onto those env vars) to sign. Without them it runs `assembleDebug` (debug-signed).

### macOS

macOS ships on the **App Store** (native `HavenMac` via the `rocket` pipeline). CI builds no
Mac artifacts — the retired Developer-ID `.dmg` leg was removed when 1.0 launched.

### Windows code-signing (optional)

Not wired today — the `.msi`/`.exe` ship unsigned (SmartScreen shows a warning, "More info →
Run anyway"). To add it later, supply an EV/OV code-signing cert and set Tauri's
`bundle.windows.certificateThumbprint` (or a signing-command env) in `tauri.conf.json`; the MS
Store path (MSIX) re-signs anyway — see `docs/WINDOWS-PORT.md`.

---

## Which artifacts build with NO secrets (start beta today)

- **Android** — debug-signed `.apk`, installable on any device with "install unknown apps".
- **Windows** — unsigned `.msi` / `.exe`.
- **Linux** — `.deb` / `.rpm` / `.AppImage`.
- **SteamOS** — `haven.flatpak`.
- **Relay** — all `haven-relay-<target>` binaries + `.deb`s.

i.e. **every** platform produces a usable beta installer with zero configuration. Signing only
upgrades the trust prompts testers see; it's never required to ship a beta link.

---

## Implementation notes

- `android/build-rust.sh` is OS-portable: it detects the host generator library extension
  (`.dylib` on macOS, `.so` on Linux, `.dll` on Windows) via `uname` so the UniFFI binding
  generation works identically on a macOS dev box and a Linux CI runner. macOS behavior is
  unchanged.
- `desktop/src-tauri/tauri.conf.json` lists `app` + `dmg` bundle targets alongside the
  Windows/Linux targets. Tauri's bundler filters targets by platform, so Windows/Linux builds
  ignore the macOS targets and vice-versa.
- The Android workflow builds all four ABIs (`arm64-v8a armeabi-v7a x86_64 x86`) so the universal
  APK runs on every device + emulator.
