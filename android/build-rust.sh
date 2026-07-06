#!/usr/bin/env bash
# Build the Rust core (`haven_ffi`) into per-ABI .so libraries and regenerate the
# UniFFI Kotlin bindings — the Android counterpart of apple/build-rust-xcframework.sh.
#
# Run this before ./gradlew assembleDebug whenever core/ changes.
#
# Requires: rustup (with android targets), cargo-ndk, an Android NDK, and a JDK.
# It uses rustup's cargo explicitly via $CARGO so it never depends on the default
# (Homebrew) toolchain that can't cross-compile.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$HERE/../core"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
RUSTUP="${RUSTUP:-$HOME/.cargo/bin/rustup}"
# Force rustup's rustc (parity with apple/build-rust-xcframework.sh). A Homebrew `rust`
# install puts /opt/homebrew/bin/rustc ahead of ~/.cargo/bin in PATH and cargo picks it up —
# but Homebrew rust has no Android std, so every cross-compile dies with
# "error[E0463]: can't find crate for `std`" even though rustup's targets ARE installed.
export RUSTC="${RUSTC:-$HOME/.cargo/bin/rustc}"

# --- Locate the Android SDK + NDK -------------------------------------------------
ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}}"
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  # Pick the highest installed NDK.
  ANDROID_NDK_HOME="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "$ANDROID_NDK_HOME" ]]; then
  echo "✗ No Android NDK found. Set ANDROID_NDK_HOME or install one with sdkmanager 'ndk;27.1.12297006'." >&2
  exit 1
fi
export ANDROID_NDK_HOME ANDROID_HOME
echo "▸ NDK: $ANDROID_NDK_HOME"

# Which ABIs to build. Override with: ABIS="arm64-v8a" ./build-rust.sh  (faster dev loop)
ABIS="${ABIS:-arm64-v8a x86_64}"
echo "▸ ABIs: $ABIS"

echo "▸ Ensuring Android Rust targets…"
"$RUSTUP" target add aarch64-linux-android x86_64-linux-android \
  armv7-linux-androideabi i686-linux-android >/dev/null

JNILIBS="$HERE/app/src/main/jniLibs"
NDK_ARGS=()
for abi in $ABIS; do NDK_ARGS+=( -t "$abi" ); done

echo "▸ Building haven_ffi (release) for: $ABIS …"
( cd "$CORE" && "$CARGO" ndk "${NDK_ARGS[@]}" -o "$JNILIBS" \
    build -p haven_ffi --lib --release )
# cargo-ndk with -o lays the .so out under jniLibs/<abi>/libhaven_ffi.so directly.

echo "▸ Generating Kotlin bindings…"
( cd "$CORE" && "$CARGO" build -q -p haven_ffi --lib )   # host lib for the generator
GEN="$HERE/app/src/main/java"
rm -rf "$GEN/uniffi"
# The host cdylib extension is OS-dependent: .dylib on macOS, .so on Linux, .dll on Windows.
# Detect it so this script (the single source of truth) is portable across dev + CI runners.
case "$(uname -s)" in
  Darwin*)            HOST_LIB_EXT="dylib" ;;
  Linux*)             HOST_LIB_EXT="so" ;;
  MINGW*|MSYS*|CYGWIN*) HOST_LIB_EXT="dll" ;;
  *)                  HOST_LIB_EXT="so" ;;
esac
HOST_LIB="target/debug/libhaven_ffi.$HOST_LIB_EXT"
echo "▸ Host generator library: $HOST_LIB"
( cd "$CORE" && "$CARGO" run -q -p haven_ffi --bin uniffi-bindgen -- \
    generate --library "$HOST_LIB" --language kotlin --out-dir "$GEN" --no-format )

echo "✓ Done."
echo "  .so → app/src/main/jniLibs/<abi>/libhaven_ffi.so"
echo "  kt  → app/src/main/java/uniffi/haven_ffi/haven_ffi.kt"
echo "  Next: (cd $HERE && ./gradlew assembleDebug)"
