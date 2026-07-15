#!/usr/bin/env bash
#
# Haven Android — Play Store screenshots from the gated, PII-free demo mode, framed with Monkr.
#
# Drives the app's launch-extra demo flags (DemoSeed.kt) on a connected device/emulator — NO real
# contacts, circles, posts, or DMs are read or written:
#   --ez haven_demo true     seed the synthetic dataset (fictional people, gradient "photos")
#   --es haven_scene <scene>  auto-present a hero scene: feed | story | messages | thread | you
# then frames each capture in Monkr's Pixel 7 Pro device frame and writes Play-ready PNGs into
# fastlane/metadata/android/en-US/images/phoneScreenshots/ (the structure `fastlane supply` / the
# Play Console both consume).
#
# Usage: ./Tools/capture_screenshots.sh [deviceSerial]   (defaults to the first attached device)
# Requires: a DEBUG build installed (demo mode is BuildConfig.DEBUG-gated), adb, and Monkr.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # android/
ADB="${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}"
# Pick a device, but NEVER silently: with the phone + tablet AVDs both booted this used to take
# whichever adb listed first and say nothing. That shot the tablet — which had a different build
# and sat on onboarding — and the Play screenshots came out of the wrong device entirely.
# Pass a serial ($1) to choose; otherwise a single attached device is fine and several is an error.
if [ -n "${1:-}" ]; then
  DEV="$1"
else
  _devs=$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}')
  _n=$(printf '%s\n' "$_devs" | grep -c . || true)
  if [ "$_n" -gt 1 ]; then
    echo "several devices attached — name one (they are not interchangeable):" >&2
    printf '  %s\n' $_devs >&2
    echo "usage: $0 <serial>" >&2
    exit 1
  fi
  DEV="$_devs"
fi
PKG="com.blaineam.haven"
MONKR="${MONKR:-$HOME/Documents/scripts/monkr/bin/monkr.mjs}"
RAW="$ROOT/app/build/play-screenshots/raw"
OUT="$ROOT/fastlane/metadata/android/en-US/images/phoneScreenshots"

[ -n "$DEV" ] || { echo "no device — connect a phone or boot an emulator"; exit 1; }
mkdir -p "$RAW" "$OUT"
echo "device: $DEV"

# tab | output basename (Play orders screenshots alphabetically). Android acts on `haven_tab`
# (circle|messages|you); `haven_scene` deep-links aren't wired there, so we shoot the three tabs.
scenes=( "circle|01-feed" "messages|02-messages" "you|03-you" )
for entry in "${scenes[@]}"; do
  tab="${entry%%|*}"; name="${entry##*|}"
  echo "==> $tab"
  "$ADB" -s "$DEV" shell am force-stop "$PKG" >/dev/null 2>&1
  "$ADB" -s "$DEV" shell am start -n "$PKG/.MainActivity" --ez haven_demo true --es haven_tab "$tab" >/dev/null 2>&1
  sleep 17   # the async demo seeder needs the node ready before posts/stories populate
  "$ADB" -s "$DEV" exec-out screencap -p > "$RAW/$name.png"
done
"$ADB" -s "$DEV" shell am force-stop "$PKG" >/dev/null 2>&1

# Play screenshots: use the full-bleed raw captures (always valid, crisp). They're the cleanest set
# unless the capture device's aspect matches the Pixel frame.
cp "$RAW"/*.png "$OUT"/
echo "✓ Play screenshots (full-bleed) → $OUT"

# Also render Monkr Pixel-7-Pro-framed versions into framed/ — these look best when captured on a
# Pixel-class device/emulator (matching the frame's tall aspect); a 16:9 phone letterboxes in them.
node "$MONKR" render --device pixel-7-pro --out "$OUT/../framed" --screenshots "$RAW" >/dev/null 2>&1 \
  && echo "✓ Monkr-framed (for Pixel-aspect sources) → $OUT/../framed"
