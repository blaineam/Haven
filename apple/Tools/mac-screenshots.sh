#!/bin/zsh
# mac-screenshots.sh — the macOS App Store screenshot pipeline (window-capture flavor).
#
# Haven's Mac app is a regular windowed app (not a menu bar app), so we don't need full
# screen control: each demo scene is captured as a CLEAN WINDOW PNG (rounded corners +
# alpha via `screencapture -o -l<windowID>`), embedded into the Haven-mac.monkr scene
# (floating window + shadow on the brand gradient), rendered headlessly via Monkr, and
# uploaded to App Store Connect as MAC_OS / APP_DESKTOP.
#
#   1. capture   ./capture_screenshots.sh mac       (HAVEN_DEMO harness, 1440×900pt window
#                                                    → 2880×1800px @2x = the exact ASC canvas)
#   2. render    monkr render Haven-mac.monkr --screenshots apple/screenshots/mac
#   3. upload    _shared/screenshots/asc-screenshots.mjs --platform MAC_OS --display-type APP_DESKTOP
#
# Usage:  ./Tools/mac-screenshots.sh [--no-upload] [--skip-capture] [--allow-in-review]
# Needs:  unlocked+awake display, Screen Recording permission for the terminal,
#         ~/.rocket/config.json ASC creds (or ASC_API_* env), a Monkr checkout.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"           # apple/
REPO_ROOT="${PROJECT_ROOT:h}"            # Haven/
SHARED="$REPO_ROOT/../_shared"
MONKR_DIR="${MONKR_DIR:-$HOME/Documents/scripts/monkr}"
MONKR="$MONKR_DIR/bin/monkr.mjs"
DOC="$REPO_ROOT/docs/appstore-screenshots/Haven-mac.monkr"
RAW="$PROJECT_ROOT/screenshots/mac"
FRAMED="$PROJECT_ROOT/screenshots/mac/framed"

NO_UPLOAD=0; SKIP_CAPTURE=0; EXTRA_UPLOAD_ARGS=()
for a in "$@"; do case "$a" in
  --no-upload) NO_UPLOAD=1 ;;
  --skip-capture) SKIP_CAPTURE=1 ;;
  --allow-in-review) EXTRA_UPLOAD_ARGS+=(--allow-in-review) ;;
esac; done

if [[ "$SKIP_CAPTURE" != 1 ]]; then
  "$SCRIPT_DIR/capture_screenshots.sh" mac
fi
[[ -d "$RAW" ]] || { echo "no raw captures at $RAW" >&2; exit 1 }

echo "==> Rendering framed Mac screenshots via Monkr…"
node "$MONKR" render "$DOC" --out "$FRAMED" --save --format png --scale 1 --screenshots "$RAW"

if [[ "$NO_UPLOAD" = 1 ]]; then
  echo "==> review mode — framed images in $FRAMED (no upload)"
  exit 0
fi

# ASC creds: env wins, else ~/.rocket/config.json.
if [[ -z "${ASC_API_KEY_ID:-}" ]]; then
  export ASC_API_KEY_ID=$(python3 -c "import json;print(json.load(open('$HOME/.rocket/config.json'))['ascKeyId'])")
  export ASC_API_ISSUER_ID=$(python3 -c "import json;print(json.load(open('$HOME/.rocket/config.json'))['ascIssuerId'])")
fi
KEY_PATH="${ASC_API_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8}"

echo "==> Uploading to App Store Connect (MAC_OS / APP_DESKTOP)…"
node "$SHARED/screenshots/asc-screenshots.mjs" \
  --bundle-id com.blaineam.kith --platform MAC_OS --display-type APP_DESKTOP --locale en-US \
  --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" --p8 "$KEY_PATH" \
  "${EXTRA_UPLOAD_ARGS[@]}" "$FRAMED"/*.png
echo "✓ Mac screenshots uploaded"
