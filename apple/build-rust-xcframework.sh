#!/usr/bin/env bash
# Build the Rust core (`haven_ffi`) into HavenFFI.xcframework and regenerate the
# Swift bindings. Run this before `xcodegen generate` / opening the Xcode project.
#
# Requires rustup with the iOS targets (this script adds them if missing). It uses
# rustup's cargo explicitly via $CARGO so it never depends on your default toolchain.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$HERE/../core"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
RUSTUP="${RUSTUP:-$HOME/.cargo/bin/rustup}"
# Force rustup's rustc. A Homebrew `rust` install puts /opt/homebrew/bin/rustc ahead of
# ~/.cargo/bin in PATH, and cargo would otherwise pick it up — but Homebrew rust has no iOS
# std, so the cross-compile fails with "can't find crate for `core`". Exporting RUSTC pins it.
export RUSTC="${RUSTC:-$HOME/.cargo/bin/rustc}"

# This repo lives in iCloud Drive, which resolves sync conflicts by leaving "name 2.ext"
# copies next to the original. Inside the xcframework and Generated/ those duplicates are
# poison: xcodegen globs Generated/*.swift, so a stale "haven_ffi 2.swift" compiles
# alongside the real one and every FFI type collides. Sweep before we build anything.
DUPES=$(find "$HERE/.." \( -name '* [0-9]' -o -name '* [0-9].*' \) \
  -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/target/*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$DUPES" != "0" ]]; then
  echo "▸ Removing $DUPES iCloud conflict copies…"
  find "$HERE/.." \( -name '* [0-9]' -o -name '* [0-9].*' \) \
    -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/target/*' -print0 2>/dev/null | xargs -0 rm -rf
fi

# BUILD OUTSIDE iCLOUD DRIVE.
#
# This repo lives in iCloud Drive, and cargo's target/ is the worst possible thing to put there:
# hundreds of megabytes of short-lived binaries, rewritten constantly. iCloud syncs them mid-write
# and hands back bytes that are subtly not what cargo wrote — which surfaces as PROC-MACRO DYLIBS
# THAT WILL NOT LOAD:
#
#   error: dlopen(.../libdarling_macro-….dylib): mis-aligned LINKEDIT string pool, fileOffset=0x29399C
#   error[E0463]: can't find crate for `time_macros`
#
# Both mean the same thing — the file on disk is corrupt — and the second says so badly enough to
# send you hunting a toolchain problem that isn't there. Deleting the individual artifact "fixes" it
# until the next sync mangles a different one, so the whole build is intermittently broken in a way
# that looks like a different bug every time.
#
# CARGO_TARGET_DIR moves the whole lot to a cache directory macOS already excludes from sync and
# from backups. Nothing in the repo needs target/ to be next to the source. Honours a value the
# caller already set (CI sets its own).
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/Library/Caches/haven-cargo-target}"
TARGET="$CARGO_TARGET_DIR"
mkdir -p "$TARGET"

# LINK THE RUST BUILD WITH A RELEASED XCODE, NOT THE BETA.
#
# Xcode-beta's linker (ld-27037) emits proc-macro dylibs that dyld will not load:
#
#   error: dlopen(.../libserde_derive-….dylib): mis-aligned LINKEDIT string pool, fileOffset=0x2C2CD4
#
# rustc loads proc macros into ITSELF to run them, so a dylib dyld rejects means the crate that
# needs it cannot compile at all — and rustc reports most of them as the far less obvious
# `error[E0463]: can't find crate for `time_macros``, which reads like a missing dependency and
# sends you hunting a toolchain that is fine. It is deterministic (serialising with
# CARGO_BUILD_JOBS=1 changes nothing) and it takes out serde_derive, darling_macro, zeroize_derive
# and friends — i.e. most of the tree.
#
# Only the RUST build is pinned. The app itself still builds against whatever Xcode is selected,
# which is the beta for the current SDK — so this does not quietly downgrade what ships.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  echo "▸ Linking Rust with released Xcode ($DEVELOPER_DIR) — the beta's ld emits unloadable proc-macro dylibs"
fi

echo "▸ Ensuring Apple targets (iOS device + sim + Mac Catalyst + native macOS)…"
# aarch64-apple-darwin = native macOS (Apple Silicon). Used by the native-macOS port (see
# docs/MACOS-NATIVE-PORT.md); harmless for the Catalyst build.
"$RUSTUP" target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-ios-macabi aarch64-apple-darwin >/dev/null

# Pin the same minimum-OS as the apps (project.yml: iOS 17.0, macOS 14.0). Without these the Rust
# objects default to a higher min version than the app links against → "built for newer version than
# being linked" link warnings on every build.
export IPHONEOS_DEPLOYMENT_TARGET="17.0"
export MACOSX_DEPLOYMENT_TARGET="14.0"
echo "▸ Building static libs (device + simulator + Mac Catalyst + native macOS)…"
( cd "$CORE" && "$CARGO" build -p haven_ffi --lib --release --target aarch64-apple-ios )
( cd "$CORE" && "$CARGO" build -p haven_ffi --lib --release --target aarch64-apple-ios-sim )
( cd "$CORE" && "$CARGO" build -p haven_ffi --lib --release --target aarch64-apple-ios-macabi )
( cd "$CORE" && "$CARGO" build -p haven_ffi --lib --release --target aarch64-apple-darwin )

echo "▸ Generating Swift bindings…"
( cd "$CORE" && "$CARGO" build -q -p haven_ffi --lib )   # host dylib for the generator
rm -rf "$HERE/Generated"; mkdir -p "$HERE/Generated"
( cd "$CORE" && "$CARGO" run -q -p haven_ffi --bin uniffi-bindgen -- \
    generate --library "$TARGET/debug/libhaven_ffi.dylib" --language swift --out-dir "$HERE/Generated" )

echo "▸ Assembling HavenFFI.xcframework…"
rm -rf "$HERE/HavenFFI.xcframework" "$HERE/build/headers"
mkdir -p "$HERE/build/headers"
cp "$HERE/Generated/haven_ffiFFI.h" "$HERE/build/headers/"
cp "$HERE/Generated/haven_ffiFFI.modulemap" "$HERE/build/headers/module.modulemap"
xcodebuild -create-xcframework \
  -library "$TARGET/aarch64-apple-ios/release/libhaven_ffi.a" -headers "$HERE/build/headers" \
  -library "$TARGET/aarch64-apple-ios-sim/release/libhaven_ffi.a" -headers "$HERE/build/headers" \
  -library "$TARGET/aarch64-apple-ios-macabi/release/libhaven_ffi.a" -headers "$HERE/build/headers" \
  -library "$TARGET/aarch64-apple-darwin/release/libhaven_ffi.a" -headers "$HERE/build/headers" \
  -output "$HERE/HavenFFI.xcframework" >/dev/null

echo "✓ Done. Next:  cd apple && xcodegen generate && open Haven.xcodeproj"
echo "  (device build: set your Team in Signing & Capabilities, then Run on your iPhone)"
