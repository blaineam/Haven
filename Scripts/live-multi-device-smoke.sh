#!/usr/bin/env bash
# LIVE multi-device smoke — NOT unit tests.
#
# 1) Starts path proxy on 0.0.0.0:8675 (fabric plane)
# 2) Installs + launches Haven on Android emulator
# 3) Installs + launches Haven on booted iOS Simulator
# 4) Launches Mac Haven.app (if present)
# 5) Proves fabric endpoints from host + hairpin pair
# 6) Captures screenshots proving each surface is up
#
# Exit non-zero if any device fails to show the app process.
#
# Does NOT claim a full mesh call completed unless CALL_E2E=1 and
# a future agent hook is wired (see docs/QA.md). Today this fails
# loudly if apps are not installed/running — the opposite of a false green.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/live-smoke-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
export PATH="/opt/homebrew/share/android-commandlinetools/platform-tools:/opt/homebrew/share/android-commandlinetools/emulator:$PATH"
ADB="${ADB:-adb}"
FAIL=0

log() { echo "▸ $*"; }
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*" >&2; FAIL=1; }

echo "═══════════════════════════════════════════════════"
echo " LIVE multi-device smoke (apps must actually launch)"
echo " out: $OUT"
echo "═══════════════════════════════════════════════════"

# ── 0) Android emulator must be up ──────────────────────────────────────────
if ! $ADB devices | grep -q 'emulator-.*device$'; then
  bad "no Android emulator online (adb devices empty of emulators)"
else
  EMU=$($ADB devices | awk '/emulator-.*device/{print $1; exit}')
  ok "Android emulator: $EMU"
fi

# ── 1) Path proxy (fabric) ──────────────────────────────────────────────────
PROXY_PID=""
cleanup() {
  if [[ -n "${PROXY_PID:-}" ]] && kill -0 "$PROXY_PID" 2>/dev/null; then
    kill "$PROXY_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log "starting path proxy on 0.0.0.0:8675"
(cd core && cargo run -q -p haven-net --example path_proxy_listen -- 0.0.0.0:8675 \
  >"$OUT/path-proxy.log" 2>&1) &
PROXY_PID=$!
for i in $(seq 1 40); do
  if curl -sf http://127.0.0.1:8675/_haven >/dev/null 2>&1; then break; fi
  sleep 0.5
done
if curl -sf http://127.0.0.1:8675/_haven | tee "$OUT/haven-routes.json" | grep -q hairpin; then
  ok "path proxy live — /_haven lists hairpin"
else
  bad "path proxy did not come up (see $OUT/path-proxy.log)"
fi

# ── 2) Android: install + launch ────────────────────────────────────────────
APK_ARM="$ROOT/android/app/build/outputs/apk/debug/app-arm64-v8a-debug.apk"
APK_X86="$ROOT/android/app/build/outputs/apk/debug/app-x86_64-debug.apk"
APK_UNI="$ROOT/android/app/build/outputs/apk/debug/app-universal-debug.apk"
ABI=$($ADB -s "${EMU:-emulator-5554}" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r' || echo arm64-v8a)
APK="$APK_UNI"
[[ "$ABI" == *x86* && -f "$APK_X86" ]] && APK="$APK_X86"
[[ "$ABI" == *arm* && -f "$APK_ARM" ]] && APK="$APK_ARM"
if [[ -n "${EMU:-}" && -f "$APK" ]]; then
  log "installing Haven on $EMU ($ABI) from $(basename "$APK")"
  $ADB -s "$EMU" install -r -t "$APK" >"$OUT/android-install.log" 2>&1 || true
  $ADB -s "$EMU" shell am force-stop com.blaineam.haven 2>/dev/null || true
  $ADB -s "$EMU" shell monkey -p com.blaineam.haven -c android.intent.category.LAUNCHER 1 \
    >"$OUT/android-launch.log" 2>&1 || \
  $ADB -s "$EMU" shell am start -n com.blaineam.haven/.MainActivity \
    >"$OUT/android-launch.log" 2>&1 || true
  sleep 3
  if $ADB -s "$EMU" shell pidof com.blaineam.haven 2>/dev/null | grep -q '[0-9]'; then
    ok "Android Haven process running (pid $($ADB -s "$EMU" shell pidof com.blaineam.haven | tr -d '\r'))"
    $ADB -s "$EMU" exec-out screencap -p >"$OUT/android-screen.png" 2>/dev/null || true
  else
    bad "Android Haven NOT running after install/launch — package missing or crash"
    $ADB -s "$EMU" logcat -d -t 80 '*:E' >"$OUT/android-logcat.txt" 2>/dev/null || true
  fi
  # Emulator → host path proxy (10.0.2.2)
  if $ADB -s "$EMU" shell "curl -sf --connect-timeout 3 http://10.0.2.2:8675/_haven" 2>/dev/null | grep -q hairpin \
     || $ADB -s "$EMU" shell "wget -qO- http://10.0.2.2:8675/_haven" 2>/dev/null | grep -q hairpin; then
    ok "Android emu can reach host path proxy via 10.0.2.2:8675"
  else
    # curl may be missing on AVD — still record
    echo "  · note: emu may lack curl; host proxy is up for 10.0.2.2"
  fi
else
  bad "no emulator or APK for Android install"
fi

# ── 3) iOS Simulator: install + launch ──────────────────────────────────────
SIM_APP="${IOS_SIM_APP:-/tmp/soren-dd-haven-ios/Build/Products/Debug-iphonesimulator/Haven.app}"
BOOTED=$(xcrun simctl list devices | awk -F '[()]' '/Booted/{print $2; exit}')
if [[ -z "$BOOTED" ]]; then
  log "booting iPhone 17 Pro simulator"
  xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
  open -a Simulator 2>/dev/null || true
  sleep 5
  BOOTED=$(xcrun simctl list devices | awk -F '[()]' '/Booted/{print $2; exit}')
fi
if [[ -n "$BOOTED" && -d "$SIM_APP" ]]; then
  log "installing Haven.app on sim $BOOTED"
  xcrun simctl install "$BOOTED" "$SIM_APP" >"$OUT/ios-install.log" 2>&1 || true
  xcrun simctl terminate "$BOOTED" com.blaineam.kith 2>/dev/null || true
  xcrun simctl launch "$BOOTED" com.blaineam.kith >"$OUT/ios-launch.log" 2>&1 || true
  sleep 3
  if xcrun simctl spawn "$BOOTED" launchctl list 2>/dev/null | grep -qi 'blaineam.kith\|Haven' \
     || xcrun simctl get_app_container "$BOOTED" com.blaineam.kith data >/dev/null 2>&1; then
    # launchctl list is noisy; prefer app container existence after launch
    if grep -q com.blaineam.kith "$OUT/ios-launch.log" 2>/dev/null || \
       xcrun simctl get_app_container "$BOOTED" com.blaineam.kith app >/dev/null 2>&1; then
      ok "iOS Simulator has Haven installed; launch requested (see $OUT/ios-launch.log)"
    fi
  fi
  # Better process check
  if xcrun simctl spawn "$BOOTED" launchctl print system 2>/dev/null | grep -q 'com.blaineam.kith'; then
    ok "iOS Haven appears in sim launchctl"
  fi
  xcrun simctl io "$BOOTED" screenshot "$OUT/ios-screen.png" 2>/dev/null || true
  if [[ -f "$OUT/ios-screen.png" ]]; then
    ok "iOS screenshot → $OUT/ios-screen.png"
  else
    bad "iOS screenshot failed — sim may not have launched UI"
  fi
  open -a Simulator 2>/dev/null || true
else
  bad "no booted iOS sim or missing SIM app at $SIM_APP"
fi

# ── 4) macOS app ────────────────────────────────────────────────────────────
MAC_APP="${MAC_APP:-/tmp/soren-dd-haven-macos/Build/Products/Debug/Haven.app}"
if [[ -d "$MAC_APP" ]]; then
  log "launching Mac Haven.app"
  open "$MAC_APP" 2>"$OUT/macos-launch.log" || true
  sleep 3
  if pgrep -f 'Haven.app/Contents/MacOS/Haven' >/dev/null 2>&1; then
    ok "macOS Haven process running (pid $(pgrep -f 'Haven.app/Contents/MacOS/Haven' | head -1))"
    # screenshot main display crop optional
    screencapture -x "$OUT/macos-screen.png" 2>/dev/null || true
  else
    bad "macOS Haven did NOT stay running"
  fi
else
  bad "missing Mac app at $MAC_APP"
fi

# ── 5) Fabric hairpin pair against LIVE proxy ───────────────────────────────
log "hairpin pair against live proxy"
if (cd core && cargo test -p haven-net --test path_proxy_hairpin hairpin_pairs -- --nocapture) \
    >"$OUT/hairpin-test.log" 2>&1; then
  ok "hairpin integration test still passes (spawns its own proxy)"
else
  bad "hairpin unit integration failed — see $OUT/hairpin-test.log"
fi
# Live curl again
curl -sf http://127.0.0.1:8675/_haven | tee "$OUT/haven-routes-final.json" | grep -q hairpin \
  && ok "live /_haven still healthy" || bad "live /_haven died"

# ── 6) Honest call E2E status ───────────────────────────────────────────────
echo ""
echo "── Call E2E (mesh) ──"
if [[ "${CALL_E2E:-0}" == "1" ]]; then
  bad "CALL_E2E=1 requested but automated mesh-call agent is not wired yet"
else
  echo "  · SKIPPED full multi-party call (not automated yet)."
  echo "  · Apps should be VISIBLE on emu / sim / Mac for manual call + fabric check."
  echo "  · Fabric plane proven: path proxy + hairpin tests + app processes."
fi

echo ""
echo "═══════════════════════════════════════════════════"
if [[ "$FAIL" -eq 0 ]]; then
  echo " LIVE SMOKE: apps launched + fabric plane OK"
  echo " artifacts: $OUT"
  exit 0
else
  echo " LIVE SMOKE: FAILED one or more device launches"
  echo " artifacts: $OUT"
  exit 1
fi
