# Haven on Linux — desktop GUI + headless relay daemon

Haven runs on Linux in **two capacities**, sharing the same Rust core (`p2pcore` +
`haven-net`) as the iOS, macOS, and Android apps:

1. **Desktop GUI** (`desktop/`, Tauri 2) — a real iroh peer at feature parity with the
   iOS/macOS app: identity, circles, feed, stories, DMs, reactions/comments, in-app camera,
   media, **WebRTC audio/video/group calls + screen share**, music, system tray, native
   notifications, and BYO S3/R2 storage. The same binary also runs **headless as a relay**
   (`--headless`).
2. **Headless relay daemon** (`core/haven-relay`) — a tiny, dependency-free static binary
   (no WebKit, no GUI) that links one of your circles and serves it as an always-on
   connection relay + sealed-media mailbox. **This is the right thing to run on a Raspberry
   Pi or a server.** It only ever moves ciphertext.

> Which one do I want? A laptop/desktop/Steam Deck you use → the **GUI**. A Pi or
> headless box left running to keep your circle reachable → the **relay daemon**.

## Supported distributions

| Distro | GUI | Relay daemon | Recommended install |
|---|---|---|---|
| **Ubuntu** | ✅ x86_64 | ✅ | GUI: `.deb` / AppImage · Relay: `haven-relay` `.deb` or `install.sh` |
| **Debian** | ✅ x86_64 | ✅ | same as Ubuntu |
| **Raspberry Pi OS / Raspbian** | ⚠️ best-effort (arm64) | ✅ **primary role** | Relay: `install.sh` (arm64 / armv7 / armv6) or `.deb` |
| **Arch** | ✅ x86_64 | ✅ | GUI: build from the in-repo PKGBUILD (**not on the AUR yet**) · Relay: binary + systemd |
| **SteamOS / Steam Deck** | ✅ x86_64 | ✅ | GUI: **Flatpak** — sideload `haven.flatpak` from the release (**not on Flathub**) · Relay: binary + systemd user service |

The GUI needs **WebKitGTK** + a glibc userland, so it targets desktop distros. The relay is a
**musl static binary** with no dependencies — it runs anywhere, including 32-bit Pis.

---

## Desktop GUI

### Ubuntu / Debian / Raspberry Pi OS (`.deb`)

```bash
sudo apt install ./Haven_0.1.0_amd64.deb      # or arm64 on a 64-bit Pi
haven-desktop                                  # launch (also in your app menu)
```

The `.deb` declares its runtime deps (`libwebkit2gtk-4.1-0`, `libgtk-3-0`,
`libayatana-appindicator3-1`) and recommends `pipewire` + `xdg-desktop-portal` for camera
and screen share. CI also produces an **AppImage** (no install — `chmod +x` and run) and an
`.rpm`.

### Arch

> **Not published to the AUR yet.** `haven-desktop` does not exist on `aur.archlinux.org` —
> `git clone https://aur.archlinux.org/haven-desktop.git` will fail. The PKGBUILD is
> maintained **in this repo** and nothing in CI publishes it (`.github/workflows/` has no
> AUR step). Build it from the in-repo recipe:

```bash
git clone https://github.com/blaineam/haven.git
cd haven/packaging/aur/haven-desktop && makepkg -si
```

The web UI is static and **embedded into the binary at compile time**, so the build needs no
Node/npm — just Rust + system WebKitGTK.

Prefer not to compile? Use the `.deb`, `.rpm`, or AppImage from the release — the AppImage runs
on Arch as-is. Note CI builds the desktop GUI on `ubuntu-latest` only, so the **prebuilt Linux
GUI artifacts are x86_64 only**; aarch64 Arch/Linux means building from source.

### SteamOS / Steam Deck (Flatpak)

SteamOS has an **immutable root filesystem**, so a `.deb`/AppImage won't persist across
updates — **Flatpak is the supported path**. From Desktop Mode, easiest is the prebuilt
bundle attached to each release:

```bash
# Grab haven.flatpak from the GitHub release, then:
flatpak install --user haven.flatpak
flatpak run com.blaineam.haven
```

Or build it yourself from the **version-pinned manifest** the release publishes (its `.deb`
`sha256` is already filled in):

```bash
flatpak install -y flathub org.gnome.Platform//47 org.gnome.Sdk//47
# com.blaineam.haven.yml is a release asset (the in-repo copy uses a placeholder sha256)
flatpak-builder --user --install --force-clean build-dir com.blaineam.haven.yml
flatpak run com.blaineam.haven
```

Then add it to Game Mode via **"Add a Non-Steam Game."** The Flatpak grants the Camera and
ScreenCast portals (camera + screen share over PipeWire), audio, Wayland/X11, the Secret
Service for the identity seed, and a tray. See `desktop/flatpak/README.md`.

### Build from source (any distro)

```bash
# build deps (Debian/Ubuntu):
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev \
                 libayatana-appindicator3-dev librsvg2-dev patchelf file
cargo install tauri-cli --version '^2'
cd desktop/src-tauri
cargo tauri dev          # run the GUI
cargo tauri build        # → target/release/bundle/{deb,rpm,appimage}/
cargo run -- --headless  # run ONLY the relay
```

---

## Headless relay daemon

### One-line install (Ubuntu / Debian / Raspbian / Arch / SteamOS / Pi)

```bash
curl -fsSL https://wemiller.com/apps/haven/relay/install.sh | sh
```

`install.sh` auto-detects the arch and downloads the matching prebuilt static binary:

| `uname -m` | Target |
|---|---|
| `x86_64` | `x86_64-unknown-linux-musl` |
| `aarch64` / `arm64` (64-bit Pi OS, Arm servers) | `aarch64-unknown-linux-musl` |
| `armv7l` (32-bit Raspbian, Pi 2/3/4) | `armv7-unknown-linux-musleabihf` |
| `armv6l` (Pi Zero / Pi 1) | `arm-unknown-linux-musleabihf` |

Then attach it to a circle (the app shows the link under **You → Advanced → Relay → Add a
relay**):

```bash
haven-relay run --link "haven-relay://circle#...."   # first run; saves the link
haven-relay run                                       # restart later; reuses it
```

### As a `.deb` (Debian/Ubuntu/Raspbian)

```bash
sudo apt install ./haven-relay_0.0.1_amd64.deb   # also arm64 / armhf
# attach to a circle once, then enable the hardened system service:
sudo -u haven-relay HOME=/var/lib/haven-relay haven-relay run --link "<code>"   # Ctrl-C after "saved"
sudo systemctl enable --now haven-relay
journalctl -u haven-relay                          # the relay node id is in the log
```

The `.deb` ships a locked-down systemd **system** service that runs as a dedicated
`haven-relay` user with `ProtectSystem=strict`, `PrivateDevices`, `NoNewPrivileges`, etc.
(`relay/debian/haven-relay.service`).

### From the PKGBUILD (Arch / SteamOS desktop)

> **Not on the AUR yet** — `aur.archlinux.org/haven-relay.git` does not exist. Build from the
> in-repo recipe (or just use the static musl binary + `install.sh` above, which needs no
> compiler):

```bash
git clone https://github.com/blaineam/haven.git
cd haven/packaging/aur/haven-relay && makepkg -si
sudo systemctl enable --now haven-relay
```

### systemd service variants

- **System** (boot, no login) — shipped in the `.deb` / Arch pkg; source at
  `relay/debian/haven-relay.service`.
- **Per-user** (no root, needs `loginctl enable-linger`) — `relay/haven-relay.service`:
  ```bash
  mkdir -p ~/.config/systemd/user && cp relay/haven-relay.service ~/.config/systemd/user/
  loginctl enable-linger "$USER"
  systemctl --user enable --now haven-relay
  ```

---

## Feature parity — Apple API → Linux

The GUI is at parity with iOS/macOS; here is how each Apple-specific capability is realized
(see also [`ANDROID-PARITY.md`](ANDROID-PARITY.md) — the same portable approach):

| iOS/macOS feature | Linux (Tauri / WebKitGTK) |
|---|---|
| Crypto / identity / circles / feed / DMs / stories | **Same `haven_ffi` crate**, linked directly (no FFI hop) — identical engine |
| iroh P2P transport + mesh relay | Same `haven-net` crate; native iroh peer in-process |
| Keychain (seed storage) | OS **Secret Service** via `keyring` (keys never leave the device) |
| In-app camera + 6 filters | `getUserMedia` (V4L2) live preview + filter strip; the selected filter is baked into both photos (canvas → JPEG) and video (recording a filtered `canvas.captureStream()` + mic audio); sealed in Rust before send |
| Photo/video picker | Tauri dialog + XDG portal |
| Voice messages | `MediaRecorder` (Opus/WebM) → sealed `a:` media ref; `<audio>` playback in feed + DMs (container MIME-sniffed server-side) |
| WebRTC audio/video/group calls | `RTCPeerConnection` full-mesh in the WebView; SDP/ICE signaled over the sealed iroh channel — no call server |
| **Screen share** | `getDisplayMedia` → on Wayland/SteamOS routes through `xdg-desktop-portal` ScreenCast (PipeWire); replaces the outgoing video track |
| Secret / screenshot-protected messages | Same `\u{2}`-prefixed wire encoding as iOS (interops byte-for-byte); conceal-until-tap + auto-hide after 5s. **Best-effort only** — webviews can't truly block screenshots like iOS/Android |
| Scheduled messages | Serverless "send later": queued to `scheduled.json`, fired by an in-process timer (and once on launch for anything overdue). Fires while the GUI is open **or** while `haven-desktop --headless` runs on an always-on machine (the relay box doubles as the scheduler) |
| Multi-identity switcher | Roster of identities, each with its own seed (secure store), profile, circles + data dir; switching relaunches the app on the new identity |
| Apple Music on posts | **Portable music ref**: paste a streaming link (deep-links out); local audio = a voice/audio attachment. No Apple Music catalog API on Linux |
| Notifications | `tauri-plugin-notification` (libnotify / XDG) + system tray; **no push server** (honors the zero-recurring-cost mandate) |
| CloudKit favorites/resume | Mailbox-based prefs blob (circle-sealed), same as Android |
| BYO storage | Shared `core/haven-s3` SigV4 client |

### Known limitations on Linux

- **Screenshot-protected secret messages**: Linux/webviews have no reliable cross-compositor
  screenshot block, so secret messages are conceal-on-idle only (unlike iOS's secure field /
  Android's `FLAG_SECURE`). The wire encoding still interops with iOS byte-for-byte.
- **Scheduled messages** fire while the GUI is open, or while `haven-desktop --headless` runs
  on an always-on machine (serverless — no remote server holds the queue). A relay-backed
  timed-release path that works even when all your machines are off is designed in
  [`SCHEDULED-MESSAGES.md`](SCHEDULED-MESSAGES.md) (Option B, cross-platform follow-up).
- **GUI on Raspberry Pi**: builds for arm64 but camera/calls/perf parity on Pi hardware is a
  stretch — a Pi's real role here is the **relay daemon**, which runs great on all Pis.

---

## CI & automated releases

**Cut a release by pushing a tag** — everything is built and published automatically:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

[`.github/workflows/release.yml`](../.github/workflows/release.yml) then builds and attaches
to one GitHub Release:

- **Relay** `haven-relay-<target>` for x86_64 / aarch64 / armv7 / armv6 (musl, via
  `cargo-zigbuild`) + macOS — the exact assets `relay/install.sh` downloads — plus `.deb`s.
- **Desktop** installers: Windows `.msi`/NSIS, Linux `.deb`/`.rpm`/AppImage.
- **SteamOS** `haven.flatpak` **plus a version-pinned `com.blaineam.haven.yml`** (the real
  `.deb` `sha256` is computed and injected at release time, so building the Flatpak from the
  release manifest needs no manual pin).

The tag drives the version (stamped into `tauri.conf.json` + the relay crate before build).

Supporting workflows:

- [`.github/workflows/desktop.yml`](../.github/workflows/desktop.yml) — PR/push CI: tests the
  core + desktop and builds the installers + Flatpak as artifacts (no publish).
- [`.github/workflows/relay-release.yml`](../.github/workflows/relay-release.yml) — a
  **relay-only** path: tag `relay-v*` to ship just a new `haven-relay` without rebuilding the
  desktop app.
