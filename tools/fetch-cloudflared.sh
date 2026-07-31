#!/usr/bin/env sh
# Download pinned cloudflared binaries for packaging (desktop externalBin + Apple Helpers + MSIX).
#
# ── Updating cloudflared ─────────────────────────────────────────────────────
# Bump ONE string only:
#   core/haven-net/src/cfquicktunnel.rs  →  CLOUDFLARED_VERSION
# Then push. You never codesign by hand:
#   • Xcode Cloud re-fetches every run and codesigns via embed-cloudflared.sh
#   • MSIX embeds the exe; Microsoft Store re-signs the package on upload
#
# Usage:
#   tools/fetch-cloudflared.sh                  # current host OS/arch → desktop/src-tauri/binaries/
#   tools/fetch-cloudflared.sh --all            # every store/CLI target we ship
#   tools/fetch-cloudflared.sh --out DIR        # custom output directory
#   tools/fetch-cloudflared.sh --apple-helpers  # OUT=apple/Helpers + plain `cloudflared` name
#   tools/fetch-cloudflared.sh --force          # re-download even if dest exists (CI default)
#
# Official Apache-2.0 builds from Cloudflare's GitHub releases.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
# Single source of truth: the Rust const (override with CLOUDFLARED_VERSION=… or --version).
read_pinned_version() {
  # Matches: pub const CLOUDFLARED_VERSION: &str = "2026.7.2";
  sed -n 's/^pub const CLOUDFLARED_VERSION: &str = "\([^"]*\)";.*/\1/p' \
    "$ROOT/core/haven-net/src/cfquicktunnel.rs" | head -1
}
VERSION="${CLOUDFLARED_VERSION:-$(read_pinned_version)}"
if [ -z "$VERSION" ]; then
  echo "error: could not read CLOUDFLARED_VERSION from cfquicktunnel.rs" >&2
  exit 1
fi
OUT="${OUT:-}"
ALL=0
APPLE_HELPERS=0
FORCE=1   # always re-download by default so a version bump never reuses a stale binary

while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1 ;;
    --apple-helpers) APPLE_HELPERS=1 ;;
    --out) OUT="$2"; shift ;;
    --version) VERSION="$2"; shift ;;
    --force) FORCE=1 ;;
    --no-force) FORCE=0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$OUT" ]; then
  if [ "$APPLE_HELPERS" = 1 ]; then
    OUT="$ROOT/apple/Helpers"
  else
    OUT="$ROOT/desktop/src-tauri/binaries"
  fi
fi
mkdir -p "$OUT"

BASE="https://github.com/cloudflare/cloudflared/releases/download/${VERSION}"

fetch() {
  # fetch <asset> <dest-name> [tgz]
  asset="$1"
  dest_name="$2"
  is_tgz="${3:-}"
  url="${BASE}/${asset}"
  dest="${OUT}/${dest_name}"
  tmp="${dest}.download"
  # Stamp file records which pin produced this dest — skip only when --no-force and stamp matches.
  stamp="${dest}.version"
  if [ "$FORCE" = 0 ] && [ -f "$dest" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$VERSION" ]; then
    echo "· ${dest_name} already at ${VERSION} (skip)"
    return 0
  fi
  echo "▸ ${asset} → ${dest_name} (${VERSION})"
  # RETRY. A single un-retried curl is why Xcode Cloud run #407's macOS archive died: the download
  # blipped, ci_post_clone warned and carried on, and the failure resurfaced twenty minutes later as
  # "apple/Helpers/cloudflared missing" during the embed phase — a symptom two stages away from its
  # cause. --retry-all-errors covers the connection resets and 5xx that a plain --retry ignores.
  attempt=1
  until curl -fsSL --connect-timeout 20 --max-time 300 \
              --retry 5 --retry-delay 3 --retry-all-errors \
              -o "$tmp" "$url"; do
    if [ "$attempt" -ge 3 ]; then
      echo "error: download failed after $attempt attempts: $url" >&2
      rm -f "$tmp"
      return 1
    fi
    attempt=$((attempt + 1))
    echo "  ↻ retry $attempt for ${asset}"
    sleep $((attempt * 5))
  done
  if [ "$is_tgz" = "tgz" ]; then
    # Extract to a private dir so a pre-existing plain `cloudflared` in OUT isn't clobbered mid-run.
    ext="$(mktemp -d "${TMPDIR:-/tmp}/cfd-XXXXXX")"
    tar -xzf "$tmp" -C "$ext"
    if [ -f "$ext/cloudflared" ]; then
      mv -f "$ext/cloudflared" "$dest"
    else
      rm -rf "$ext" "$tmp"
      echo "error: tarball had no cloudflared binary" >&2
      return 1
    fi
    rm -rf "$ext" "$tmp"
  else
    mv -f "$tmp" "$dest"
  fi
  chmod +x "$dest" 2>/dev/null || true
  # Drop download quarantine on macOS so store packaging/codesign don't inherit it.
  xattr -d com.apple.quarantine "$dest" 2>/dev/null || true
  printf '%s\n' "$VERSION" > "$stamp"
}

# Tauri externalBin naming: <name>-<target-triple>[.exe]
# https://v2.tauri.app/develop/resources/#bundling-additional-binaries

if [ "$ALL" = 1 ]; then
  fetch cloudflared-darwin-arm64.tgz  cloudflared-aarch64-apple-darwin tgz
  fetch cloudflared-darwin-amd64.tgz  cloudflared-x86_64-apple-darwin tgz
  fetch cloudflared-windows-amd64.exe cloudflared-x86_64-pc-windows-msvc.exe
  # No official windows-arm64 asset for this pin — arm64 MSIX ships the amd64 helper (WoA x64 emu).
  fetch cloudflared-linux-amd64      cloudflared-x86_64-unknown-linux-gnu || true
  fetch cloudflared-linux-arm64      cloudflared-aarch64-unknown-linux-gnu || true
  # CLI neighbor names (no triple) for haven-relay packaging side-by-side
  fetch cloudflared-linux-amd64      cloudflared-linux-amd64 || true
  fetch cloudflared-darwin-arm64.tgz  cloudflared-darwin-arm64 tgz || true
elif [ "$APPLE_HELPERS" = 1 ]; then
  # HavenMac is arm64-only (EXCLUDED_ARCHS x86_64). Plain name for embed-cloudflared.sh.
  fetch cloudflared-darwin-arm64.tgz cloudflared-aarch64-apple-darwin tgz
  cp -f "$OUT/cloudflared-aarch64-apple-darwin" "$OUT/cloudflared"
  chmod +x "$OUT/cloudflared"
  printf '%s\n' "$VERSION" > "$OUT/cloudflared.version"
else
  OS="$(uname -s 2>/dev/null || echo unknown)"
  ARCH="$(uname -m 2>/dev/null || echo unknown)"
  case "$OS-$ARCH" in
    Darwin-arm64)  fetch cloudflared-darwin-arm64.tgz cloudflared-aarch64-apple-darwin tgz
                   # also plain name for local dev / relay neighbor / Apple Helpers
                   cp -f "$OUT/cloudflared-aarch64-apple-darwin" "$OUT/cloudflared" 2>/dev/null || true
                   ;;
    Darwin-x86_64) fetch cloudflared-darwin-amd64.tgz cloudflared-x86_64-apple-darwin tgz
                   cp -f "$OUT/cloudflared-x86_64-apple-darwin" "$OUT/cloudflared" 2>/dev/null || true
                   ;;
    Linux-x86_64)  fetch cloudflared-linux-amd64 cloudflared-x86_64-unknown-linux-gnu
                   cp -f "$OUT/cloudflared-x86_64-unknown-linux-gnu" "$OUT/cloudflared" 2>/dev/null || true
                   ;;
    Linux-aarch64|Linux-arm64)
                   fetch cloudflared-linux-arm64 cloudflared-aarch64-unknown-linux-gnu
                   cp -f "$OUT/cloudflared-aarch64-unknown-linux-gnu" "$OUT/cloudflared" 2>/dev/null || true
                   ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
                   # Git Bash on the Windows release runner.
                   fetch cloudflared-windows-amd64.exe cloudflared-x86_64-pc-windows-msvc.exe
                   cp -f "$OUT/cloudflared-x86_64-pc-windows-msvc.exe" "$OUT/cloudflared.exe" 2>/dev/null || true
                   ;;
    *) echo "unknown host $OS-$ARCH — use --all or install cloudflared manually" >&2; exit 1 ;;
  esac
fi

echo "✓ cloudflared ${VERSION} ready in ${OUT}"
echo "  No manual signing: XCC codesigns Helpers/; MSIX is Store-re-signed on upload."
