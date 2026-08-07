#!/bin/bash
# HavenMac post-build: copy the pre-fetched cloudflared into Contents/Helpers and codesign
# it with the SAME identity Xcode is using for this build.
#
# Fully automatic on every Archive / Xcode Cloud run — including after a cloudflared version
# bump. You only change CLOUDFLARED_VERSION in core/haven-net/src/cfquicktunnel.rs; never run
# codesign by hand. Xcode Cloud sets EXPANDED_CODE_SIGN_IDENTITY (cloud-managed signing).
#
# Wired from apple/project.yml → HavenMac.postBuildScripts.
set -euo pipefail

HELPER_NAME="cloudflared"
SRC="${SRCROOT}/Helpers/${HELPER_NAME}"
DEST_DIR="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}/Contents/Helpers"
DEST="${DEST_DIR}/${HELPER_NAME}"
ENTS="${SRCROOT}/Helpers/cloudflared.entitlements"

echo "=== embed-cloudflared ==="
echo "  SRC=$SRC"
echo "  DEST=$DEST"
echo "  CONFIG=${CONFIGURATION:-?} CODE_SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED:-?} IDENTITY=${EXPANDED_CODE_SIGN_IDENTITY:-(none)}"

if [ ! -f "$SRC" ]; then
  # Debug/local: optional (falls back to PATH at runtime). Release/archive must ship it.
  if [ "${CONFIGURATION:-}" = "Release" ] || [ "${ACTION:-}" = "install" ]; then
    echo "error: ${SRC} missing. Xcode Cloud should fetch it in ci_post_clone; locally run:"
    echo "  tools/fetch-cloudflared.sh && cp desktop/src-tauri/binaries/cloudflared-aarch64-apple-darwin apple/Helpers/cloudflared"
    exit 1
  fi
  echo "warning: cloudflared not at Helpers/ — Debug build continues (PATH fallback at runtime)"
  exit 0
fi

mkdir -p "$DEST_DIR"
# Preserve exec bit; don't copy resource forks / quarantine xattrs into the bundle.
/bin/cp -fX "$SRC" "$DEST" 2>/dev/null || /bin/cp -f "$SRC" "$DEST"
chmod 755 "$DEST"
# Drop download quarantine so Gatekeeper doesn't treat the helper as untrusted network content.
xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true

if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
  echo "  code signing disabled — left unsigned"
  exit 0
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  # Ad-hoc for local unsigned runs; Xcode Cloud always has a real identity for Archive.
  IDENTITY="-"
  echo "  no EXPANDED_CODE_SIGN_IDENTITY — ad-hoc signing"
fi

CODESIGN_ARGS=(
  --force
  --sign "$IDENTITY"
  --options runtime
  --identifier "com.blaineam.kith.cloudflared"
)
# Timestamp only when we have a real identity (ad-hoc rejects --timestamp).
if [ "$IDENTITY" != "-" ]; then
  CODESIGN_ARGS+=(--timestamp)
fi
if [ -f "$ENTS" ]; then
  CODESIGN_ARGS+=(--entitlements "$ENTS")
fi

/usr/bin/codesign "${CODESIGN_ARGS[@]}" "$DEST"
echo "  signed OK: $(/usr/bin/codesign -dv --verbose=2 "$DEST" 2>&1 | head -5 | tr '\n' ' ')"
echo "=== embed-cloudflared done ==="
