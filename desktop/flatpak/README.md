# Haven Flatpak (SteamOS / Steam Deck + any Flatpak distro)

SteamOS ships an **immutable root filesystem**, so `.deb`/AppImage installs don't stick across
updates. Flatpak is the supported path on the Steam Deck — installable from **Desktop Mode →
Discover**, or the terminal.

## Install (Steam Deck Desktop Mode)

```bash
# 1. GNOME runtime (ships WebKitGTK, which the Tauri WebView needs)
flatpak install -y flathub org.gnome.Platform//51 org.gnome.Sdk//51

# 2. Build + install Haven from the manifest (uses the .deb CI publishes)
flatpak-builder --user --install --force-clean build-dir com.blaineam.haven.yml

# 3. Run (or launch "Haven" from the app grid; add it to Steam via "Add a Non-Steam Game")
flatpak run com.blaineam.haven
```

Update the manifest's `url`/`sha256` to the release `.deb` you want, then rebuild.

## Permissions

The `finish-args` grant network (iroh P2P), Wayland/X11 + DRI, PulseAudio, the **Camera** and
**ScreenCast** portals (camera + screen share over PipeWire), the **Secret Service** (the
identity seed — keys never leave the device), a tray, and `~/.local/share/haven` persistence.

## Flathub submission (later)

Flathub requires building **from source** with crates vendored offline. Generate a
`cargo-sources.json` with [`flatpak-cargo-generator`](https://github.com/flatpak/flatpak-builder-tools/tree/master/cargo)
against `desktop/src-tauri/Cargo.lock`, swap the `simple` module for a `cargo` build that
points `frontendDist` at the in-tree static `ui/`, and add it as a source. The static UI means
**no Node toolchain** is needed in the sandbox.
