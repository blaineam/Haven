#!/usr/bin/env bash
# Start (or restart) the isolated HavenStub relay host for QA fleets.
# Extracted from qa-linked-device-matrix.sh so every suite shares one bootstrap.
set -euo pipefail
OUT="${1:-/tmp/haven-e2e-stub-out}"; mkdir -p "$OUT"
APP="${HAVEN_STUB_APP:-/tmp/matrix-haven-mac-stub/Build/Products/Debug/HavenStub.app}"

log() { echo "[stub] $*"; }

free_ports() {
  for port in 8674 8675; do
    for pid in $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true); do
      name=$(ps -p "$pid" -o comm= 2>/dev/null || true)
      # Never kill the user's real Haven by accident unless it squats the QA ports:
      # matrix clients would otherwise hit the wrong host and get REFUSED forever.
      if [[ "$name" == *"HavenStub"* || "$name" == *"cloudflared"* || "$name" == *"Haven"* ]]; then
        log "freeing :$port (pid=$pid name=$name)"; kill "$pid" 2>/dev/null || true
      fi
    done
  done
  for pid in $(pgrep -f 'matrix-haven-mac-stub.*cloudflared' 2>/dev/null || true); do
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
}

[[ -d "$APP" ]] || { echo "error: missing $APP — build HavenStub first (see docs/QA.md)"; exit 1; }
pkill -x HavenStub 2>/dev/null || true
sleep 1
free_ports
mkdir -p /tmp/haven-mac-stub-home/Library/Application\ Support /tmp/haven-mac-stub-tmp
# The stub is SANDBOXED: UserDefaults live in its container prefs, not the /tmp HOME.
# Write both (the /tmp copy covers a hypothetical non-sandboxed build). Pre-seeding
# the relay token keeps a fresh container on the fixed token every client default
# expects (RelayHost mints a random one only when the key is empty).
for PREFS in \
  "$HOME/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Preferences/com.blaineam.kith.qa.stub" \
  "/tmp/haven-mac-stub-home/Library/Preferences/com.blaineam.kith.qa.stub"; do
  mkdir -p "$(dirname "$PREFS")"
  defaults write "$PREFS" "haven.relay.host.enabled" -bool true 2>/dev/null || true
  defaults write "$PREFS" "haven.relay.httpToken" -string "${HAVEN_STUB_TOKEN:-8e17157a4fd8f6eeef1c3accdd9fc1de}" 2>/dev/null || true
done
nohup env HOME=/tmp/haven-mac-stub-home HAVEN_SKIP_ONBOARDING=1 TMPDIR=/tmp/haven-mac-stub-tmp \
  "$APP/Contents/MacOS/HavenStub" >"$OUT/stub-stdout.log" 2>&1 &
echo $! >"$OUT/stub.pid"
sleep 6
if ! pgrep -x HavenStub >/dev/null; then
  log "isolated HOME launch failed — trying open(1)"
  open "$APP" 2>/dev/null || true
  sleep 5
fi
pgrep -x HavenStub >/dev/null || { echo "error: HavenStub not running"; tail -40 "$OUT/stub-stdout.log" 2>/dev/null; exit 1; }
for i in $(seq 1 12); do
  lsof -nP -iTCP:8674 -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 1
done
lsof -nP -iTCP:8674 -sTCP:LISTEN >/dev/null 2>&1 || { echo "error: :8674 not listening"; exit 1; }
log "stub up pid=$(pgrep -x HavenStub | head -1)"
