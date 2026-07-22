#!/usr/bin/env bash
# Bidirectional public-identity exchange between iOS Simulator and Android emulator for matrix QA.
# Needed when HELLO cannot dial (iroh addressing missing) but HTTP mailbox still works —
# without mutual addContactBundle, reverse-path envelopes + media never open.
#
# Prereqs: both apps launched at least once so qa-my-bundle.bin exists on each side.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${HAVEN_IOS_UDID:-}"
IOS_BUNDLE="${HAVEN_IOS_BUNDLE:-com.blaineam.kith}"
AND_PKG="${HAVEN_AND_PKG:-com.blaineam.haven}"
AND_SERIAL="${AND_SERIAL:-$(adb devices 2>/dev/null | awk '/device$/{print $1; exit}')}"

if [[ -z "$SIM" ]]; then
  SIM="$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[A-F0-9-]{36}' | head -1 || true)"
fi
[[ -n "$SIM" ]] || { echo "error: no booted iOS simulator" >&2; exit 1; }
[[ -n "$AND_SERIAL" ]] || { echo "error: no Android device" >&2; exit 1; }

DATA="$(xcrun simctl get_app_container "$SIM" "$IOS_BUNDLE" data)"
IOS_B="$DATA/Library/Application Support/qa-my-bundle.bin"
IOS_N="$DATA/Library/Application Support/qa-my-name.txt"
AS="$DATA/Library/Application Support"
mkdir -p "$AS"

# Wait briefly for dumps
for i in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s "$IOS_B" ]] && adb -s "$AND_SERIAL" shell "run-as $AND_PKG test -s files/qa-my-bundle.bin" 2>/dev/null && break
  sleep 1
done
[[ -s "$IOS_B" ]] || { echo "error: iOS qa-my-bundle.bin missing — launch Haven on the sim first" >&2; exit 1; }

NAME="$(cat "$IOS_N" 2>/dev/null || echo SimPeer)"
echo "→ iOS → Android: $(wc -c < "$IOS_B") bytes name=$NAME"
adb -s "$AND_SERIAL" push "$IOS_B" /data/local/tmp/qa-peer-bundle.bin >/dev/null
printf '%s' "$NAME" > /tmp/qa-peer-name.txt
adb -s "$AND_SERIAL" push /tmp/qa-peer-name.txt /data/local/tmp/qa-peer-name.txt >/dev/null
adb -s "$AND_SERIAL" shell "run-as $AND_PKG cp /data/local/tmp/qa-peer-bundle.bin files/qa-peer-bundle.bin"
adb -s "$AND_SERIAL" shell "run-as $AND_PKG cp /data/local/tmp/qa-peer-name.txt files/qa-peer-name.txt"
adb -s "$AND_SERIAL" shell "run-as $AND_PKG sh -c 'rm -f files/haven_mailbox_seen.txt'" 2>/dev/null || true

# Android → iOS
if adb -s "$AND_SERIAL" shell "run-as $AND_PKG test -s files/qa-my-bundle.bin" 2>/dev/null; then
  adb -s "$AND_SERIAL" shell "run-as $AND_PKG cat files/qa-my-bundle.bin" > /tmp/and-qa-my-bundle.bin
  adb -s "$AND_SERIAL" shell "run-as $AND_PKG cat files/qa-my-name.txt" > /tmp/and-qa-my-name.txt 2>/dev/null || echo EmuPeer > /tmp/and-qa-my-name.txt
  cp /tmp/and-qa-my-bundle.bin "$AS/qa-peer-bundle.bin"
  cp /tmp/and-qa-my-name.txt "$AS/qa-peer-name.txt"
  echo "→ Android → iOS: $(wc -c < /tmp/and-qa-my-bundle.bin) bytes name=$(cat /tmp/and-qa-my-name.txt)"
else
  echo "warn: Android qa-my-bundle.bin not ready yet — relaunch Android after this script and re-run"
fi

# Account hexes for media matrix
if adb -s "$AND_SERIAL" shell "run-as $AND_PKG test -f files/node-ticket.txt" 2>/dev/null; then
  adb -s "$AND_SERIAL" shell "run-as $AND_PKG cat files/node-ticket.txt" | tee "$ROOT/build/and-node-ticket.txt" | head -5
fi

# Relaunch both so ingest runs
adb -s "$AND_SERIAL" shell am force-stop "$AND_PKG"
xcrun simctl terminate "$SIM" "$IOS_BUNDLE" 2>/dev/null || true
sleep 1
adb -s "$AND_SERIAL" shell am start -n "$AND_PKG/.MainActivity" >/dev/null
xcrun simctl launch "$SIM" "$IOS_BUNDLE" >/dev/null
sleep 4
echo "Done. Mutual peer bundles staged; apps relaunched for ingest."
echo "Re-run once more if Android dump was missing on first pass."
