#!/usr/bin/env sh
# Download pinned cloudflared binaries for packaging (desktop externalBin + release assets).
#
# Usage:
#   tools/fetch-cloudflared.sh                  # current host OS/arch → desktop/src-tauri/binaries/
#   tools/fetch-cloudflared.sh --all            # every store/CLI target we ship
#   tools/fetch-cloudflared.sh --out DIR        # custom output directory
#
# Version is pinned here AND in core/haven-net/src/cfquicktunnel.rs (CLOUDFLARED_VERSION) —
# bump both together. Official Apache-2.0 builds from Cloudflare's GitHub releases.
set -eu

VERSION="${CLOUDFLARED_VERSION:-2026.7.2}"
OUT="${OUT:-}"
ALL=0
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1 ;;
    --out) OUT="$2"; shift ;;
    --version) VERSION="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$OUT" ]; then
  OUT="$ROOT/desktop/src-tauri/binaries"
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
  echo "▸ ${asset} → ${dest_name}"
  curl -fsSL -o "$tmp" "$url"
  if [ "$is_tgz" = "tgz" ]; then
    tar -xzf "$tmp" -C "$OUT"
    # tarball extracts as cloudflared; rename to Tauri externalBin triple name
    if [ -f "$OUT/cloudflared" ]; then
      mv -f "$OUT/cloudflared" "$dest"
    fi
    rm -f "$tmp"
  else
    mv -f "$tmp" "$dest"
  fi
  chmod +x "$dest" 2>/dev/null || true
}

# Tauri externalBin naming: <name>-<target-triple>[.exe]
# https://v2.tauri.app/develop/resources/#bundling-additional-binaries

if [ "$ALL" = 1 ]; then
  fetch cloudflared-darwin-arm64.tgz  cloudflared-aarch64-apple-darwin tgz
  fetch cloudflared-darwin-amd64.tgz  cloudflared-x86_64-apple-darwin tgz
  fetch cloudflared-windows-amd64.exe cloudflared-x86_64-pc-windows-msvc.exe
  # Windows on ARM (optional but cheap)
  # no official arm64 windows asset named consistently — skip if missing
  fetch cloudflared-linux-amd64      cloudflared-x86_64-unknown-linux-gnu || true
  fetch cloudflared-linux-arm64      cloudflared-aarch64-unknown-linux-gnu || true
  # CLI neighbor names (no triple) for haven-relay packaging side-by-side
  fetch cloudflared-linux-amd64      cloudflared-linux-amd64 || true
  fetch cloudflared-darwin-arm64.tgz  cloudflared-darwin-arm64 tgz || true
else
  OS="$(uname -s 2>/dev/null || echo unknown)"
  ARCH="$(uname -m 2>/dev/null || echo unknown)"
  case "$OS-$ARCH" in
    Darwin-arm64)  fetch cloudflared-darwin-arm64.tgz cloudflared-aarch64-apple-darwin tgz
                   # also plain name for local dev / relay neighbor
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
    *) echo "unknown host $OS-$ARCH — use --all or install cloudflared manually" >&2; exit 1 ;;
  esac
fi

echo "✓ cloudflared ${VERSION} ready in ${OUT}"
echo "  Sign these with your product identity before App Store / Microsoft Store packaging."
