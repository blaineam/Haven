#!/bin/bash
# HavenMac post-build: copy a built Haven web client (web-client/dist, made by
# web-client/build.sh) into Contents/Resources/web-client, so this Mac's relay can offer
# "Web access" (RelayHost.webClientDir).
#
# OPTIONAL in every configuration. A build without web-client/dist is a complete app that
# simply has no "Web access" switch — it never fails the build and never ships a stale copy.
#
# Runs before Xcode signs the app, so the files are sealed by the app's signature like any
# other resource. Wired from apple/project.yml → HavenMac.postBuildScripts.
set -euo pipefail

SRC="${HAVEN_WEB_CLIENT_DIST:-${SRCROOT}/../web-client/dist}"
DEST="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}/Contents/Resources/web-client"

echo "=== embed-web-client ==="
echo "  SRC=$SRC"
echo "  DEST=$DEST"

if [ ! -f "$SRC/index.html" ] || [ ! -f "$SRC/pkg/haven_web_bg.wasm" ]; then
  echo "  no web client build at SRC — this app will not offer Web access"
  rm -rf "$DEST"
  exit 0
fi

mkdir -p "$DEST"
# Exact mirror: a file removed from the build must not linger in the app. No extended
# attributes (quarantine, resource forks) — codesign rejects some and they are never wanted.
/usr/bin/rsync -rc --delete --exclude '.DS_Store' "$SRC/" "$DEST/"
/usr/bin/xattr -cr "$DEST" 2>/dev/null || true
echo "  embedded $(find "$DEST" -type f | wc -l | tr -d ' ') files"
