#!/usr/bin/env bash
# Exchange public identity bundles between iOS Simulator and Android emulator for matrix QA.
# Needed when HELLO cannot dial (iroh addressing missing) but HTTP mailbox still works —
# without mutual addContactBundle, reverse-path envelopes fail receive().
#
# Prereqs: both apps launched at least once after the qa-my-bundle dump (iOS) is in tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${HAVEN_IOS_UDID:-}"
IOS_BUNDLE="${HAVEN_IOS_BUNDLE:-com.blaineam.kith}"
AND_PKG="${HAVEN_AND_PKG:-com.blaineam.haven}"

if [[ -z "$SIM" ]]; then
  SIM="$(xcrun simctl list devices booted 2>/dev/null | grep -oE '\([A-F0-9-]{36}\)' | head -1 | tr -d '()')"
fi
[[ -n "$SIM" ]] || { echo "error: no booted iOS simulator" >&2; exit 1; }

DATA="$(xcrun simctl get_app_container "$SIM" "$IOS_BUNDLE" data)"
IOS_B="$DATA/Library/Application Support/qa-my-bundle.bin"
IOS_N="$DATA/Library/Application Support/qa-my-name.txt"
if [[ ! -s "$IOS_B" ]]; then
  echo "error: iOS qa-my-bundle.bin missing — launch Haven on the sim first (post rebuild)" >&2
  exit 1
fi
NAME="$(cat "$IOS_N" 2>/dev/null || echo SimPeer)"
echo "iOS bundle $(wc -c < "$IOS_B") bytes name=$NAME → Android $AND_PKG"

adb push "$IOS_B" /data/local/tmp/qa-peer-bundle.bin >/dev/null
printf '%s' "$NAME" > /tmp/qa-peer-name.txt
adb push /tmp/qa-peer-name.txt /data/local/tmp/qa-peer-name.txt >/dev/null
adb shell "run-as $AND_PKG cp /data/local/tmp/qa-peer-bundle.bin files/qa-peer-bundle.bin"
adb shell "run-as $AND_PKG cp /data/local/tmp/qa-peer-name.txt files/qa-peer-name.txt"
# Clear seen so prior failed receives retry after contact ingest on next start
adb shell "run-as $AND_PKG sh -c 'rm -f files/haven_mailbox_seen.txt'"
adb shell am force-stop "$AND_PKG"
sleep 1
adb shell am start -n "$AND_PKG/.MainActivity" >/dev/null
echo "Android relaunched with peer bundle (will ingest on configure)."
echo "Done. Post from iOS and watch Android feed."
