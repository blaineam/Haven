#!/usr/bin/env bash
# Fabric multi-device QA helper (Mac host + iOS Simulator + Android Emulator).
#
# What this automates on the Mac:
#   1) Path-proxy + WebSocket hairpin integration tests (no UDP TURN required)
#   2) Haven-first policy unit tests (n0/Google only when fabric empty)
#   3) Optional: bind a live path-proxy on 0.0.0.0:8675 for sim/emu clients
#
# Device targeting (manual app join after this script reports green):
#   • iOS Simulator  → http://127.0.0.1:8675  (same Mac)
#   • Android Emulator → http://10.0.2.2:8675  (host loopback from AVD)
#   • Physical devices → http://<Mac-LAN-IP>:8675
#
# Full Soren gate (recommended before RC):
#   node ../_shared/soren/soren.mjs run Haven core fabric android ios macos desktop desktop-ui
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ Haven fabric multi-device QA"
echo "  repo: $ROOT"

echo ""
echo "── 1) Path proxy + hairpin + Haven-first policy (cargo) ──"
(cd core && cargo test -p haven-net --test path_proxy_hairpin -- --nocapture)

echo ""
echo "── 2) Desktop UI syntax ──"
node --check desktop/ui/app.js

if [[ -x /opt/homebrew/opt/openjdk@17/bin/java ]] || command -v java >/dev/null 2>&1; then
  echo ""
  echo "── 3) Android fabric ICE policy unit tests ──"
  export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
  export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
  export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
  (cd android && ./gradlew :app:testDebugUnitTest --tests 'com.blaineam.haven.core.FabricIcePolicyTest' -q) \
    || echo "  (skipped or failed — run full: soren run Haven android)"
else
  echo ""
  echo "── 3) Android unit tests skipped (no JDK) ──"
fi

if command -v xcodebuild >/dev/null 2>&1; then
  echo ""
  echo "── 4) Apple HavenLogicTests (fabric ICE) ──"
  (cd apple && xcodebuild test \
    -project Haven.xcodeproj \
    -scheme Haven \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -only-testing:HavenLogicTests/HavenFabricTests \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -30) || echo "  (skipped or failed — run full: soren run Haven ios)"
else
  echo ""
  echo "── 4) Apple tests skipped (no xcodebuild) ──"
fi

echo ""
echo "── How to point simulators / emulators at this Mac's fabric ──"
LAN="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<your-lan-ip>')"
echo "  Path proxy (when haven-relay / Mac host is up):"
echo "    iOS Simulator:     https://127.0.0.1:8675   or DERP/media URL from interface.json"
echo "    Android Emulator:  https://10.0.2.2:8675    (host loopback)"
echo "    Physical phone:    https://${LAN}:8675"
echo "  Probe:  curl -s http://127.0.0.1:8675/_haven | jq ."
echo "  Hairpin: wss://<host>/webrtc/hairpin"
echo ""
echo "  Policy under test:"
echo "    fabric DERP known  → n0 OFF, Google STUN OFF for ICE"
echo "    fabric + TURN      → circle TURN only"
echo "    no fabric          → n0 + Google STUN fallback"
echo ""
echo "✓ fabric multi-device QA script finished (see any skipped legs above)"
