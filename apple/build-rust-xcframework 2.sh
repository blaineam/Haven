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
    generate --library target/debug/libhaven_ffi.dylib --language swift --out-dir "$HERE/Generated" )

echo "▸ Assembling HavenFFI.xcframework…"
rm -rf "$HERE/HavenFFI.xcframework" "$HERE/build/headers"
mkdir -p "$HERE/build/headers"
cp "$HERE/Generated/haven_ffiFFI.h" "$HERE/build/headers/"
cp "$HERE/Generated/haven_ffiFFI.modulemap" "$HERE/build/headers/module.modulemap"
xcodebuild -create-xcframework \
  -library "$CORE/target/aarch64-apple-ios/release/libhaven_ffi.a" -headers "$HERE/build/headers" \
  -library "$CORE/target/aarch64-apple-ios-sim/release/libhaven_ffi.a" -headers "$HERE/build/headers" \
  -library "$CORE/target/aarch64-apple-ios-macabi/release/libhaven_ffi.a" -headers "$HERE/build/headers" \
  -library "$CORE/target/aarch64-apple-darwin/release/libhaven_ffi.a" -headers "$HERE/build/headers" \
  -output "$HERE/HavenFFI.xcframework" >/dev/null

echo "✓ Done. Next:  cd apple && xcodegen generate && open Haven.xcodeproj"
echo "  (device build: set your Team in Signing & Capabilities, then Run on your iPhone)"
