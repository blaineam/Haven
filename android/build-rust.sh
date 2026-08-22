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

# iCloud Drive resolves sync conflicts by dropping "name 2.ext" copies beside the original.
# In jniLibs/ that means a stale "libiroh… 2.so" gets packaged into the APK next to the real
# one — dex/packaging errors at best, a silently stale native lib at worst. Sweep first.
DUPES=$(find "$HERE" \( -name '* [0-9]' -o -name '* [0-9].*' \) \
  -not -path '*/.git/*' -not -path '*/build/*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$DUPES" != "0" ]]; then
  echo "▸ Removing $DUPES iCloud conflict copies…"
  find "$HERE" \( -name '* [0-9]' -o -name '* [0-9].*' \) \
    -not -path '*/.git/*' -not -path '*/build/*' -print0 2>/dev/null | xargs -0 rm -rf
fi

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
# Google Play requires 16 KB memory-page support for everything targeting Android 15+ —
# every packaged .so must carry 16 KB-aligned LOAD segments. NDK r28+ links this way by
# default but r27 (what CI and dev boxes pin) does NOT, so say it explicitly; harmless
# where it's already the default. Play rejects production updates without it.
#
# TARGET-scoped, not plain RUSTFLAGS: the generic variable also reaches HOST build
# scripts (proc-macros, build.rs), and the macOS host linker dies on `-z max-page-size`
# ("ld: unknown options: -z") — measured, it killed portable-atomic's build script.
PAGE16="-C link-arg=-Wl,-z,max-page-size=16384"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="${CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS:-} $PAGE16"
export CARGO_TARGET_X86_64_LINUX_ANDROID_RUSTFLAGS="${CARGO_TARGET_X86_64_LINUX_ANDROID_RUSTFLAGS:-} $PAGE16"
export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_RUSTFLAGS="${CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_RUSTFLAGS:-} $PAGE16"
export CARGO_TARGET_I686_LINUX_ANDROID_RUSTFLAGS="${CARGO_TARGET_I686_LINUX_ANDROID_RUSTFLAGS:-} $PAGE16"   # CI also builds 32-bit x86
( cd "$CORE" && "$CARGO" ndk "${NDK_ARGS[@]}" -o "$JNILIBS" \
    build -p haven_ffi --lib --release )

# Trust nothing: verify the alignment of what was just produced. 0x4000 = 16 KB. A single
# 4 KB-aligned LOAD segment here means Play blocks the release — fail loudly NOW.
case "$(uname -s)" in Darwin*) HOST_TAG="darwin-x86_64" ;; *) HOST_TAG="linux-x86_64" ;; esac
READELF="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG/bin/llvm-readelf"
if [[ -x "$READELF" ]]; then
  for so in "$JNILIBS"/*/libhaven_ffi.so; do
    "$READELF" -l "$so" | python3 -c '
import sys
aligns = [int(l.split()[-1], 16) for l in sys.stdin if l.split() and l.split()[0] == "LOAD"]
sys.exit(0 if aligns and min(aligns) >= 16384 else 1)
' && echo "  ✓ 16 KB-aligned: $so"       || { echo "✗ $so is NOT 16 KB-aligned (Play will refuse the release)" >&2; exit 1; }
  done
else
  echo "⚠ llvm-readelf not found at $READELF — skipping alignment verification" >&2
fi
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
