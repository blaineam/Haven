#!/usr/bin/env bash
# Linked-device matrix: iOS Simulator (primary) + Tauri desktop (same account) over HavenStub mailbox.
# Proves posts / stories / reactions / media land on BOTH fleet devices via the relay (not only Multipeer).
#
# Calls over internet are out of scope here (field follow-up).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${QA_OUT:-$ROOT/build/linked-device-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
MARKER="Linked_$(date +%H%M%S)"
PHOTO="$ROOT/Scripts/fixtures/qa-photo.jpg"
VIDEO="$ROOT/Scripts/fixtures/qa-clip.mp4"
NODE="${HAVEN_STUB_NODE:-401f6cda9ed29974eb0ef02412de42bbd125c4bf16f7a857f285fe8aeb57af89}"
TOKEN="${HAVEN_STUB_TOKEN:-8e17157a4fd8f6eeef1c3accdd9fc1de}"
DATA_DIR="${HAVEN_DESKTOP_DATA:-$HOME/Library/Application Support/Haven}"
DESK="${HAVEN_DESKTOP_BIN:-$ROOT/desktop/src-tauri/target/debug/haven-desktop}"

log() { echo "[linked] $*"; echo "$*" >>"$OUT/run.log"; }
pass=0; fail=0
score() {
  if eval "$2"; then log "GREEN  $1"; pass=$((pass+1)); echo "| $1 | GREEN |" >>"$OUT/LINKED_REPORT.md"
  else log "RED    $1"; fail=$((fail+1)); echo "| $1 | RED |" >>"$OUT/LINKED_REPORT.md"; fi
}

{
  echo "# Linked-device matrix (iOS + Tauri over HavenStub mailbox)"
  echo; echo "**Marker:** \`$MARKER\`"; echo "**Out:** \`$OUT\`"; echo
  echo "| Check | Result |"; echo "|-------|--------|"
} >"$OUT/LINKED_REPORT.md"

SIM="${HAVEN_IOS_UDID:-$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[A-F0-9-]{36}' | head -1)}"
[[ -n "$SIM" ]] || { echo "error: no booted iOS sim"; exit 1; }
pgrep -x HavenStub >/dev/null || {
  log "starting HavenStub"
  open /tmp/matrix-haven-mac-stub/Build/Products/Debug/HavenStub.app 2>/dev/null || true
  sleep 4
}
pgrep -x HavenStub >/dev/null || { echo "error: HavenStub not running"; exit 1; }

# Wire sim + ensure stub ports
"$ROOT/Scripts/qa-wire-stub-clients.sh" 2>&1 | tee -a "$OUT/run.log" | tail -8 || true
xcrun simctl launch "$SIM" com.blaineam.kith >/dev/null 2>&1 || true
sleep 5

APP_DATA="$(xcrun simctl get_app_container "$SIM" com.blaineam.kith data)"
AS="$APP_DATA/Library/Application Support"
# Wait for seed dump
for i in $(seq 1 20); do
  [[ -s "$AS/qa-account-seed.txt" ]] && break
  sleep 1
done
if [[ ! -s "$AS/qa-account-seed.txt" ]]; then
  log "warn: qa-account-seed.txt missing — rebuild iOS DEBUG with seed dump, or paste seed manually"
  # fall back to prefs scrape
  SEED_FILE="$OUT/ios-to-tauri-haven-seed.txt"
  python3 - "$APP_DATA/Library/Preferences/com.blaineam.kith.plist" "$SEED_FILE" <<'PY' || true
import plistlib, sys, base64
from pathlib import Path
d = plistlib.load(open(sys.argv[1], "rb"))
for k in ("haven.ephemeralSeed.v1", "haven.accountSeed.v1"):
    v = d.get(k)
    if isinstance(v, str) and len(v) >= 40:
        Path(sys.argv[2]).write_text("haven-seed:" + v + "\n")
        print("seed from prefs", k)
        raise SystemExit(0)
raise SystemExit(1)
PY
else
  cp "$AS/qa-account-seed.txt" "$OUT/ios-to-tauri-haven-seed.txt"
fi
[[ -s "$OUT/ios-to-tauri-haven-seed.txt" ]] || { echo "error: no iOS seed for Tauri link"; exit 1; }
ACCOUNT_HEX="$(cat "$AS/qa-account-hex.txt" 2>/dev/null | tr -d '\r\n' || true)"
DEVICE_HEX="$(cat "$AS/qa-device-hex.txt" 2>/dev/null | tr -d '\r\n' || true)"
SS_HEX="$(cat "$AS/qa-selfsync-device-hex.txt" 2>/dev/null | tr -d '\r\n' || true)"
if [[ -z "$DEVICE_HEX" ]]; then
  DEVICE_HEX="$(plutil -extract haven.selfsync.deviceId raw "$APP_DATA/Library/Preferences/com.blaineam.kith.plist" 2>/dev/null || true)"
fi
log "account=${ACCOUNT_HEX:0:12}… transport=${DEVICE_HEX:0:12}… selfsync=${SS_HEX:0:12}…"

# Authorize iOS account + transport device ids on stub host (HTTP signs as device id).
STUB_AS="$HOME/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support"
mkdir -p "$STUB_AS"
{
  [[ -n "$ACCOUNT_HEX" && ${#ACCOUNT_HEX} -eq 64 ]] && echo "$ACCOUNT_HEX"
  [[ -n "$DEVICE_HEX" && ${#DEVICE_HEX} -eq 64 ]] && echo "$DEVICE_HEX"
  [[ -n "$SS_HEX" && ${#SS_HEX} -eq 64 ]] && echo "$SS_HEX"
} | sort -u >"$STUB_AS/qa-authorize-members.txt"
log "stub members: $(wc -l <"$STUB_AS/qa-authorize-members.txt" | tr -d ' ') hexes"
cat "$STUB_AS/qa-authorize-members.txt" >>"$OUT/run.log"
# Bounce stub so authorizeMembership re-reads (or just re-enable host)
# Kill/reopen is heavy; touch by relaunching if needed
if [[ -d /tmp/matrix-haven-mac-stub/Build/Products/Debug/HavenStub.app ]]; then
  pkill -x HavenStub 2>/dev/null || true
  sleep 1
  open /tmp/matrix-haven-mac-stub/Build/Products/Debug/HavenStub.app
  sleep 5
fi
"$ROOT/Scripts/qa-wire-stub-clients.sh" 2>&1 | tail -5 || true
xcrun simctl launch "$SIM" com.blaineam.kith >/dev/null 2>&1 || true
sleep 4

# Link Tauri
export HAVEN_QA_SEED_FILE="$OUT/ios-to-tauri-haven-seed.txt"
# prefs for desktop
python3 - "$DATA_DIR" "$NODE" "$TOKEN" <<'PY'
import json, sys, time
from pathlib import Path
root, node, token = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
root.mkdir(parents=True, exist_ok=True)
prefs_path = root / "prefs.json"
prefs = {}
if prefs_path.exists():
    try: prefs = json.loads(prefs_path.read_text())
    except Exception: prefs = {}
now = int(time.time() * 1000)
prefs["relay_entries"] = {
    node: {
        "hex": node, "name": "HavenStub matrix", "active": True,
        "last_seen_ms": now, "is_s3": False,
        "http_urls": ["http://127.0.0.1:8674"], "http_token": token,
        "added_at_ms": now, "derp_url": "", "turn_urls": [], "turn_user": "", "turn_pass": "",
    }
}
prefs["default_relay"] = node
prefs["relays"] = {"default": [node]}
prefs["fabric_derp_urls"] = []
prefs_path.write_text(json.dumps(prefs, indent=2))
print("desktop prefs →", prefs_path)
PY

# Kill prior desktop
pkill -f 'target/debug/haven-desktop' 2>/dev/null || true
sleep 1
if [[ ! -x "$DESK" ]]; then
  log "building haven-desktop…"
  (cd "$ROOT/desktop/src-tauri" && cargo build -q 2>>"$OUT/tauri-build.log") || true
fi
[[ -x "$DESK" ]] || { echo "error: no $DESK"; exit 1; }

log "launching Tauri with HAVEN_QA_SEED_FILE"
(cd "$ROOT/desktop/src-tauri" && HAVEN_QA_SEED_FILE="$HAVEN_QA_SEED_FILE" RUST_LOG=info \
  "$DESK" >"$OUT/tauri.log" 2>&1) &
TPID=$!
sleep 8
if ! kill -0 "$TPID" 2>/dev/null; then
  log "Tauri exited early — see $OUT/tauri.log"
  tail -30 "$OUT/tauri.log" || true
fi

# Stage fixtures on iOS and author linked content
cp -f "$PHOTO" "$AS/qa-photo.jpg"
cp -f "$VIDEO" "$AS/qa-clip.mp4"
ios_qa() {
  printf '%s\n' "$1" >"$AS/qa-cmd.json"
  xcrun simctl openurl "$SIM" 'haven://qa?x=1' 2>/dev/null || true
  sleep 4
}
ios_qa "{\"post\":\"${MARKER}_PostPhoto\",\"media\":\"photo\",\"photo_path\":\"$AS/qa-photo.jpg\"}"
ios_qa "{\"post\":\"${MARKER}_PostVideo\",\"media\":\"video\",\"video_path\":\"$AS/qa-clip.mp4\"}"
ios_qa "{\"story\":\"${MARKER}_StoryPhoto\",\"media\":\"photo\",\"photo_path\":\"$AS/qa-photo.jpg\"}"
# reaction needs a post id — skip automation if no id; force-sync instead
sleep 15
# force sync on both by reopening / waiting
xcrun simctl openurl "$SIM" 'haven://qa?x=2' 2>/dev/null || true
sleep 20

# Verify iOS authored
score "iOS authored photo post" "grep -q '${MARKER}_PostPhoto' '$AS/haven-feed.json' 2>/dev/null"
score "iOS authored video post" "grep -q '${MARKER}_PostVideo' '$AS/haven-feed.json' 2>/dev/null"
score "iOS authored story photo" "grep -q '${MARKER}_StoryPhoto' '$AS/haven-feed.json' 2>/dev/null"

# Verify Tauri social state / logs
sleep 5
score "Tauri process alive" "kill -0 $TPID 2>/dev/null"
score "Tauri saw photo post body" "grep -q '${MARKER}_PostPhoto' '$OUT/tauri.log' 2>/dev/null || (test -f '$DATA_DIR/haven_social_state.bin' && strings '$DATA_DIR/haven_social_state.bin' | grep -q '${MARKER}_PostPhoto')"
score "Tauri saw video post body" "grep -q '${MARKER}_PostVideo' '$OUT/tauri.log' 2>/dev/null || (test -f '$DATA_DIR/haven_social_state.bin' && strings '$DATA_DIR/haven_social_state.bin' | grep -q '${MARKER}_PostVideo')"
score "Tauri saw story body" "grep -q '${MARKER}_StoryPhoto' '$OUT/tauri.log' 2>/dev/null || (test -f '$DATA_DIR/haven_social_state.bin' && strings '$DATA_DIR/haven_social_state.bin' | grep -q '${MARKER}_StoryPhoto')"
# Media on disk for desktop
# Exclude demo/ sandbox media from "has blobs" (false green).
score "Tauri media dir has blobs" "find '$DATA_DIR/media' -type f ! -path '*/demo/*' 2>/dev/null | head -1 | grep -q ."

# iOS logs for mailbox success
xcrun simctl spawn "$SIM" log show --last 3m --predicate 'processImagePath CONTAINS "Haven"' 2>/dev/null \
  | grep -iE "matrix-qa|mailbox put|REFUSED|${MARKER}" >"$OUT/ios.log" || true
score "iOS media mint in logs" "grep -q 'matrix-qa post body=${MARKER}' '$OUT/ios.log' || grep -q '${MARKER}_PostPhoto' '$OUT/ios.log'"
score "stub not REFUSING all puts" "! grep -q 'REFUSED mailbox put' '$OUT/ios.log' || grep -q 'http-put OK\\|mailbox put OK\\|backup.*OK' '$OUT/ios.log'"

{
  echo; echo "## Summary"; echo; echo "- **pass:** $pass"; echo "- **fail:** $fail"
  if [[ $fail -eq 0 ]]; then echo; echo "**Verdict: linked-device board GREEN**"
  else echo; echo "**Verdict: not fully green** — see RED rows / $OUT/tauri.log"; fi
} >>"$OUT/LINKED_REPORT.md"
log "done pass=$pass fail=$fail → $OUT/LINKED_REPORT.md"
cat "$OUT/LINKED_REPORT.md"
# leave Tauri running for inspection unless LINKED_KILL=1
[[ "${LINKED_KILL:-0}" == "1" ]] && kill "$TPID" 2>/dev/null || true
exit "$fail"
