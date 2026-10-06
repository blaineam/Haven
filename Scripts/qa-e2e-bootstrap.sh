#!/usr/bin/env bash
# Fleet assembly for qa-e2e-full.mjs: isolated HavenStub (relay host + account B),
# iOS sim + Tauri + Android emulator all linked as account A over the stub mailbox.
# Reuses the conventions of qa-linked-device-matrix.sh; never touches the personal
# com.blaineam.kith prod container or the personal desktop data root.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${QA_OUT:-$ROOT/build/e2e-bootstrap-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
NODE="${HAVEN_STUB_NODE:-401f6cda9ed29974eb0ef02412de42bbd125c4bf16f7a857f285fe8aeb57af89}"
TOKEN="${HAVEN_STUB_TOKEN:-8e17157a4fd8f6eeef1c3accdd9fc1de}"
DATA_DIR="${HAVEN_DESKTOP_DATA:-$HOME/Library/Application Support/Haven/qa-matrix}"
# HavenStub's QA files (qa-cmd/qa-dump/qa-account-hex/bundles/authorize list) + hosted relay store.
# A plain directory the harness owns; the stub reaches it through a stub-only sandbox exception.
STUB_QA_DIR="$HOME/Library/Application Support/HavenQA/stub"
DESK="${HAVEN_DESKTOP_BIN:-$ROOT/desktop/src-tauri/target/qa/haven-desktop}"
IOS_BUNDLE="${HAVEN_IOS_BUNDLE:-com.blaineam.kith}"
AND_PKG="${HAVEN_AND_PKG:-com.blaineam.haven}"

log() { echo "[e2e-boot] $*"; }

# ── Host audio preflight. The iOS simulator and the macOS stub use the HOST's default output
#    device. When that device is stuck (seen with a virtual remote-desktop output while its client
#    is disconnected), every audio start blocks ~15s and WebRTC's AURemoteIO::Initialize aborts on
#    the RPC timeout — the call steps crash the iOS app an hour into a run. Fail fast instead.
#    E2E_SKIP_AUDIO_PREFLIGHT=1 to bypass.
if [[ "${E2E_SKIP_AUDIO_PREFLIGHT:-0}" != "1" ]] && command -v afplay >/dev/null 2>&1; then
  afplay -v 0 -t 0.2 /System/Library/Sounds/Tink.aiff >/dev/null 2>&1 & _ap=$!
  for _i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$_ap" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$_ap" 2>/dev/null; then
    kill "$_ap" 2>/dev/null || true
    _dev="$(system_profiler SPAudioDataType 2>/dev/null | grep -B3 'Default Output Device: Yes' | head -1 | sed 's/^ *//; s/:$//')"
    echo "error: host audio output '${_dev:-unknown}' is not playing (afplay hung >5s) — calls would crash the iOS sim."
    echo "       Set System Settings → Sound → Output to a real device, then rerun (E2E_SKIP_AUDIO_PREFLIGHT=1 to bypass)."
    exit 1
  fi
fi

# E2E_PREFRIEND=0 (set by qa-e2e-full.mjs when the `newfriend` step runs): A and B start as
# STRANGERS. No contact bundles are exchanged and A's devices are NOT pre-authorized on B's relay,
# so the step can measure a genuinely fresh friendship through the real invite → accept → approve
# path, including the acceptor's pre-enrollment 403s. The members file is still written; the harness
# authorizes it itself once the step is done, restoring the baseline every later step expects.
PREFRIEND="${E2E_PREFRIEND:-1}"
authorize() {
  if [[ "$PREFRIEND" == "0" ]]; then log "E2E_PREFRIEND=0 — not pre-authorizing $(grep -c . "$1" || true) member(s) (the harness does it after newfriend)"; return 0; fi
  "$ROOT/Scripts/qa-e2e-authorize.sh" "$1"
}


# A HERMETIC FLEET IS THE DEFAULT. Every leg's QA state is wiped: identities re-mint, bundles
# re-exchange, and no stale seen-set, contact, circle or blob from a prior run can leak in.
#
# This used to be opt-in (E2E_FRESH=1) and almost nobody set it, which produced two failures that
# looked like product bugs and were not. The stub accumulated ONE CIRCLE PER RUN — 13 of them, all
# still polled every cycle, so the leg got monotonically slower until it missed its budgets. And
# wiping only SOME legs is worse than wiping none: emptying the relay store while the clients keep
# their feeds leaves every older post rendering "media loading / not available" forever, because the
# bytes those posts point at were served by a relay that has just been emptied underneath them.
#
# Set E2E_FRESH=0 to reuse a hot fleet when iterating locally. Anything else, including unset, wipes.
if [[ "${E2E_FRESH:-1}" != "0" ]]; then
  log "hermetic fleet — wiping QA state on all legs (E2E_FRESH=0 to reuse)"
  # These two pkills are the sharpest edge in this script: the legs are machine-wide singletons, so
  # they end ANY run that is using them, not just leftovers from a previous one. qa-e2e-full.mjs
  # takes build/.e2e-run.lock before it gets here, which is what keeps that from happening — refuse
  # to fire if this script was invoked on its own while a run holds the lock.
  LOCKFILE="$ROOT/build/.e2e-run.lock"
  if [[ -f "$LOCKFILE" ]]; then
    LOCK_PID="$(/usr/bin/sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$LOCKFILE" | head -1)"
    if [[ -n "$LOCK_PID" && "$LOCK_PID" != "${E2E_RUN_PID:-}" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
      log "REFUSING to wipe: run $LOCK_PID owns the fleet (its stub and desktop are live)."
      log "  Wait for it, or delete $LOCKFILE if that process is gone."
      exit 3
    fi
  fi
  pkill -f "HavenStub.app" 2>/dev/null || true
  pkill -f 'target/qa/haven-desktop' 2>/dev/null || true
  sleep 1
  # The stub's QA files + hosted relay store live in the shared QA dir (never its container — macOS
  # App Data protection forbids touching another app's container; see apple/HavenApp/QaFiles.swift).
  # Wipe that here; the stub wipes its OWN container state (feed, media, seen-set, self-sync blob and
  # PREFERENCES — the companion maps live there) on this run's launch via E2E_STUB_RESET=1 below.
  rm -rf "$STUB_QA_DIR" 2>/dev/null || true
  export E2E_STUB_RESET=1
  rm -rf "$DATA_DIR" 2>/dev/null || true
  SIM_FRESH="${HAVEN_IOS_UDID:-$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[A-F0-9-]{36}' | head -1 || true)}"
  if [[ -z "$SIM_FRESH" ]]; then
    log "ERROR: no booted iOS simulator (and no HAVEN_IOS_UDID) — boot one first: xcrun simctl boot <udid>"
    log "       (under pipefail this used to kill the script at the assignment with no message at all)"
    exit 1
  fi
  if [[ -n "$SIM_FRESH" ]]; then
    xcrun simctl terminate "$SIM_FRESH" "$IOS_BUNDLE" 2>/dev/null || true
    xcrun simctl uninstall "$SIM_FRESH" "$IOS_BUNDLE" 2>/dev/null || true
  fi
  if [[ "${E2E_ANDROID:-1}" != "0" ]] && command -v adb >/dev/null 2>&1 && [[ "$(adb get-state 2>/dev/null || true)" == "device" ]]; then
    adb shell pm clear com.blaineam.haven >/dev/null 2>&1 || true
    # The qa channel lives in the app's internal files/qa/ (pm clear already empties it; this is
    # belt-and-braces). The /sdcard/Download/qa-* rm only sweeps files the OLD channel left behind.
    adb shell "run-as $AND_PKG rm -rf files/qa" >/dev/null 2>&1 || true
    adb shell 'rm -f /sdcard/Download/qa-*' >/dev/null 2>&1 || true
  fi
fi

# Bring up the Simulator window. simctl boots HEADLESSLY, so the iOS leg was running the whole time
# with no way to watch it — every other leg has a visible window. Purely cosmetic, but a fleet you
# cannot see is a fleet you cannot sanity-check.
open -a Simulator 2>/dev/null || true

# ── 1. iOS sim: booted + app installed ────────────────────────────────────────
SIM="${HAVEN_IOS_UDID:-$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[A-F0-9-]{36}' | head -1)}"
if [[ -z "$SIM" ]]; then
  SIM=$(xcrun simctl list devices available | grep "iPhone 17 Pro (" | grep -oE '[A-F0-9-]{36}' | head -1)
  [[ -n "$SIM" ]] || { echo "error: no iPhone 17 Pro simulator"; exit 1; }
  log "booting sim $SIM"; xcrun simctl boot "$SIM"; sleep 8
fi
# NB: must be a SIGNED sim build — unsigned has no data-protection keychain, the seed
# never persists, and the QA dumps (which need storedSeed) never appear on a fresh container.
IOS_APP="${HAVEN_IOS_APP:-/tmp/haven-signed-ios-dd/Build/Products/Debug-iphonesimulator/Haven.app}"
# Build it if it's missing or STALE. This step used to install whatever happened to be sitting in
# that DerivedData path — a run could (and did) score a whole suite green against an iOS binary
# built a day before the fix under test, which is worse than not running at all. Same freshness
# rule as the stub: any newer apple/HavenApp or core/ source forces a rebuild.
IOS_BIN="$IOS_APP/Haven"
NEEDS_IOS=0
if [[ ! -x "$IOS_BIN" ]]; then
  NEEDS_IOS=1
else
  while IFS= read -r newer; do [[ -n "$newer" ]] && { NEEDS_IOS=1; break; }; done < <(
    find "$ROOT/apple/HavenApp" "$ROOT/core" -type f \
      \( -name '*.swift' -o -name '*.rs' \) -newer "$IOS_BIN" -print -quit 2>/dev/null
  )
fi
if [[ "$NEEDS_IOS" == 1 ]]; then
  log "building iOS sim app (missing or stale)…"
  # FOUR dirnames, not three: Haven.app -> Debug-iphonesimulator -> Products -> Build -> <dd root>.
  # With three, -derivedDataPath was ".../haven-signed-ios-dd/Build", so xcodebuild nested its own
  # Build/ inside it and the app landed at .../Build/Build/Products/... — a path nothing looks at.
  # The build then "succeeded" every run while the install silently found no app, and the sim kept
  # running whatever binary happened to be installed by hand. A leg that never installs what it just
  # built is worse than a broken leg: it reports on code that is not under test.
  IOS_DD="$(dirname "$(dirname "$(dirname "$(dirname "$IOS_APP")")")")"
  ( cd "$ROOT/apple" && xcodegen generate >/dev/null && xcodebuild \
      -project Haven.xcodeproj -scheme Haven -configuration Debug \
      -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$IOS_DD" \
      DEVELOPMENT_TEAM=8ZVSPZYSVF build ) >"$OUT/ios-build.log" 2>&1 \
    || { echo "error: iOS sim build FAILED — tail of $OUT/ios-build.log:"; tail -25 "$OUT/ios-build.log"; exit 1; }
fi
# Install is FATAL on failure. It used to be `|| true`, so a missing or unusable app produced a
# confusing "failed to launch" three steps later instead of naming the actual problem here.
[[ -d "$IOS_APP" ]] || { echo "error: no iOS app at $IOS_APP after build — see $OUT/ios-build.log"; exit 1; }
xcrun simctl install "$SIM" "$IOS_APP" || { echo "error: simctl install failed for $IOS_APP"; exit 1; }
# The iOS 27 simulator sometimes registers a fresh install with installd but not FrontBoard, so
# every launch fails "Application … is unknown to FrontBoard" and the run dies at "iOS seed dump
# missing". A reboot of the simulator plus a reinstall clears it; do that once automatically.
if ! SIMCTL_CHILD_HAVEN_SKIP_ONBOARDING=1 xcrun simctl launch "$SIM" "$IOS_BUNDLE" >/dev/null 2>&1; then
  log "iOS launch failed (FrontBoard lost the install?) — rebooting the simulator and reinstalling"
  xcrun simctl shutdown "$SIM" >/dev/null 2>&1 || true
  xcrun simctl boot "$SIM" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true
  xcrun simctl install "$SIM" "$IOS_APP" || { echo "error: simctl install failed for $IOS_APP"; exit 1; }
  SIMCTL_CHILD_HAVEN_SKIP_ONBOARDING=1 xcrun simctl launch "$SIM" "$IOS_BUNDLE" >/dev/null 2>&1 \
    || log "WARN: iOS launch still failing after a simulator reboot"
fi

# ── 1b. Stage account A's contact bundle for the stub BEFORE its (only) launch —
# DEBUG builds ingest qa-peer-bundle.bin at startup, and mutual addContactBundle is
# what makes A↔B contacts (circle invites + DMs need it, mailbox auth alone doesn't).
STUB_AS_PRE="$STUB_QA_DIR"
APP_DATA_PRE="$(xcrun simctl get_app_container "$SIM" "$IOS_BUNDLE" data 2>/dev/null || true)"
if [[ -n "$APP_DATA_PRE" && "$PREFRIEND" != "0" ]]; then
  IOS_AS_PRE="$APP_DATA_PRE/Library/Application Support"
  for i in $(seq 1 20); do [[ -s "$IOS_AS_PRE/qa-my-bundle.bin" ]] && break; sleep 1; done
  if [[ -s "$IOS_AS_PRE/qa-my-bundle.bin" ]]; then
    mkdir -p "$STUB_AS_PRE"
    cp "$IOS_AS_PRE/qa-my-bundle.bin" "$STUB_AS_PRE/qa-peer-bundle.bin"
    cp "$IOS_AS_PRE/qa-my-name.txt" "$STUB_AS_PRE/qa-peer-name.txt" 2>/dev/null || printf 'FleetA' >"$STUB_AS_PRE/qa-peer-name.txt"
    log "staged A's bundle for stub ingest"
  else
    log "WARN: iOS qa-my-bundle.bin missing — A↔B contact link will not form"
  fi
fi

# ── 2. Stub relay host (matrix-script conventions; isolated HOME) ─────────────
# Build it if it's missing. The suite used to hard-fail here with "build HavenStub
# first", which meant a transport regression could sit unverified because the QA
# fleet refused to boot. Always rebuild when core/ or the app sources are newer so
# a run can never silently validate a stale binary.
STUB_APP="${MATRIX_DD:-/tmp/matrix-haven-mac-stub}/Build/Products/Debug/HavenStub.app"
STUB_BIN="$STUB_APP/Contents/MacOS/HavenStub"
NEEDS_STUB=0
if [[ ! -x "$STUB_BIN" ]]; then
  NEEDS_STUB=1
else
  while IFS= read -r newer; do [[ -n "$newer" ]] && { NEEDS_STUB=1; break; }; done < <(
    find "$ROOT/apple/HavenApp" "$ROOT/core" -type f \
      \( -name '*.swift' -o -name '*.rs' \) -newer "$STUB_BIN" -print -quit 2>/dev/null
  )
fi
if [[ "$NEEDS_STUB" == 1 ]]; then
  log "building HavenStub (missing or stale)…"
  "$ROOT/Scripts/qa-e2e-build-stub.sh"
fi

"$ROOT/Scripts/qa-e2e-stub.sh" "$OUT"

# The stub's relay node id IS its account node hex (RelayHost shares the node) —
# resolve it live instead of trusting the baked default. The DEBUG seed dump lands in the shared
# QA dir (the stub build resolves its QA files there, not in its sandbox container).
STUB_AS="$STUB_QA_DIR"
for i in $(seq 1 40); do [[ -s "$STUB_AS/qa-account-hex.txt" ]] && break; sleep 1; done
STUB_NODE="$( (cat "$STUB_AS/qa-account-hex.txt" 2>/dev/null || true) | tr -d '\r\n')"
if [[ ${#STUB_NODE} -eq 64 ]]; then
  NODE="$STUB_NODE"
  log "stub node resolved live: ${NODE:0:12}…"
else
  log "WARN: stub qa-account-hex.txt missing — using baked default node id"
fi
export HAVEN_STUB_NODE="$NODE" HAVEN_STUB_TOKEN="$TOKEN"

# ── 3. Wire sim (+ android if present) at the stub ────────────────────────────
# Under E2E_PREFRIEND=0 the iOS leg must NOT know B's relay yet: the newfriend step has it adopt the
# relay from B's invite ticket, which is the only way the pending-enrollment path is exercised.
if [[ "$PREFRIEND" == "0" ]]; then
  log "E2E_PREFRIEND=0 — iOS not wired to the stub relay (adopted from the invite ticket instead)"
else
  HAVEN_IOS_UDID="$SIM" "$ROOT/Scripts/qa-wire-stub-clients.sh" 2>&1 | tail -5 || true
fi
SIMCTL_CHILD_HAVEN_SKIP_ONBOARDING=1 xcrun simctl launch "$SIM" "$IOS_BUNDLE" >/dev/null 2>&1 || true
sleep 5

# ── 4. Seed + authorize A's ids on the stub ───────────────────────────────────
APP_DATA="$(xcrun simctl get_app_container "$SIM" "$IOS_BUNDLE" data)"
AS="$APP_DATA/Library/Application Support"
for i in $(seq 1 20); do [[ -s "$AS/qa-account-seed.txt" ]] && break; sleep 1; done
[[ -s "$AS/qa-account-seed.txt" ]] || { echo "error: iOS seed dump missing (need DEBUG build)"; exit 1; }
SEED_FILE="$OUT/fleet-seed.txt"; cp "$AS/qa-account-seed.txt" "$SEED_FILE"

MEMBERS="$OUT/members.txt"
# NB: (a) the app writes these files WITHOUT a trailing newline — cat-ing several
# glues them into one unmatchable line, so emit one line per file; (b) grep exits 1
# on zero matches — with pipefail that would silently kill the script.
hexline() { [[ -s "$1" ]] && printf '%s\n' "$(tr -d ' \r\n' <"$1")"; }
{ hexline "$AS/qa-account-hex.txt"; hexline "$AS/qa-device-hex.txt"; hexline "$AS/qa-selfsync-device-hex.txt"; } \
  | grep -E '^[0-9a-f]{64}$' | sort -u >"$MEMBERS" || true
[[ -s "$MEMBERS" ]] || { echo "error: no member hexes dumped by the iOS app (DEBUG build required)"; exit 1; }
authorize "$MEMBERS"

# ── 5. Tauri as linked device of A ────────────────────────────────────────────
pkill -f 'target/qa/haven-desktop' 2>/dev/null || true; sleep 1
# Rebuild when missing OR stale — `[[ -x ]] ||` alone silently reran yesterday's binary.
# cargo is incremental, so this is a no-op when nothing changed.
if [[ ! -x "$DESK" ]] || [[ -n "$(find "$ROOT/core" "$ROOT/desktop/src-tauri/src" -type f -name '*.rs' -newer "$DESK" -print -quit 2>/dev/null)" ]]; then
  log "building haven-desktop (missing or stale)…"
  (cd "$ROOT/desktop/src-tauri" && cargo build -q --profile qa --bin haven-desktop) || { echo "error: desktop build FAILED"; exit 1; }
fi
mkdir -p "$DATA_DIR"
python3 - "$DATA_DIR" "$NODE" "$TOKEN" <<'PY'
import json, sys, time
from pathlib import Path
root, node, token = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
root.mkdir(parents=True, exist_ok=True)
p = root / "prefs.json"
prefs = {}
if p.exists():
    try: prefs = json.loads(p.read_text())
    except Exception: prefs = {}
now = int(time.time() * 1000)
prefs["relay_entries"] = {node: {"hex": node, "name": "E2E stub", "active": True,
  "last_seen_ms": now, "is_s3": False, "http_urls": ["http://127.0.0.1:8674"],
  "http_token": token, "added_at_ms": now, "derp_url": "", "turn_urls": [],
  "turn_user": "", "turn_pass": ""}}
prefs["default_relay"] = node
prefs["relays"] = {"default": [node]}
p.write_text(json.dumps(prefs, indent=2))
PY
rm -f "$DATA_DIR/haven_social_state.bin" "$DATA_DIR/mailbox-seen.txt" "$DATA_DIR/selfsync-state.bin" 2>/dev/null || true
# RUST_LOG was pinned to info, which hides the one line that explains a mailbox loss: the
# "receive no-op ... (buffered/dup) — marked seen" path logs at debug!, so an envelope that was
# fetched and then parked was indistinguishable from one never fetched. Override with
# HAVEN_DESKTOP_LOG=debug when chasing content that "never arrives".
# The babysitting subshell must not inherit our stdio: a runner that pipes this script (soren)
# waits for the pipe to CLOSE, and the desktop leg outlives the harness — the gate sat on
# "e2e still running" for 25 minutes after pass/fail was printed (2026-09-01).
(cd "$ROOT/desktop/src-tauri" && HAVEN_QA_SEED_FILE="$SEED_FILE" RUST_LOG="${HAVEN_DESKTOP_LOG:-info}" "$DESK" >"$OUT/tauri.log" 2>&1) >/dev/null 2>&1 </dev/null &
echo $! >"$OUT/tauri.pid"
sleep 10
for i in $(seq 1 30); do [[ -s "$DATA_DIR/qa-device-hex.txt" ]] && break; sleep 1; done
{ cat "$MEMBERS"; hexline "$DATA_DIR/qa-device-hex.txt"; hexline "$DATA_DIR/qa-account-hex.txt"; } \
  | grep -E '^[0-9a-f]{64}$' | sort -u >"$MEMBERS.next" || true
[[ -s "$MEMBERS.next" ]] && mv "$MEMBERS.next" "$MEMBERS"
authorize "$MEMBERS"

# Cold boot (never a quick-boot snapshot: a snapshot can restore a dead network stack) with explicit
# public DNS. The emulator otherwise forwards to the HOST resolver, and on a Mac running Tailscale that
# is MagicDNS (100.100.100.100), which the emulator's user-mode network cannot reach: the AVD then
# boots with "Active default network: none" — mailbox steps still pass over adb reverse while every
# iroh dial, push and call fails, and whole runs scored the host's VPN instead of Haven.
# `-crash-report-mode never`: after ANY emulator crash, the next launch otherwise opens a MODAL
# "send crash report?" Qt dialog before booting — nobody clicks it, qemu sits there forever holding
# the AVD lock, and every later boot dies with "Running multiple emulators with the same AVD"
# (2026-09-29: two runs in a row skipped the android leg that way).
boot_haven_emulator() {
  nohup "${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/emulator/emulator" -avd haven_phone \
    -no-snapshot-load -no-snapshot-save -no-boot-anim -dns-server 1.1.1.1,8.8.8.8 \
    -crash-report-mode never \
    >"$OUT/emulator.log" 2>&1 &
}
# Kill the running emulator and cold-boot it again; sets booted=1 once sys.boot_completed answers.
cold_reboot_haven_emulator() {
  adb emu kill >/dev/null 2>&1 || true
  for i in $(seq 1 30); do [[ "$(adb get-state 2>/dev/null || true)" != "device" ]] && break; sleep 1; done
  boot_haven_emulator
  for i in $(seq 1 160); do [[ "$(adb get-state 2>/dev/null || true)" == "device" ]] && break; sleep 3; done
  booted=0
  for i in $(seq 1 100); do
    [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)" == "1" ]] && { booted=1; break; }
    sleep 3
  done
}
android_has_network() {
  adb shell dumpsys connectivity 2>/dev/null | grep -q "Active default network: [0-9]"
}
wait_android_network() {  # $1 = seconds
  for i in $(seq 1 "$1"); do android_has_network && return 0; sleep 1; done
  return 1
}

# ── 6. Android emulator as linked device of A (best-effort leg) ───────────────
# E2E_ANDROID=0 leaves the emulator alone entirely (a wedged shared emulator — adbd not answering —
# otherwise hangs this script on its first `adb shell`, since these calls carry no timeout).
if [[ "${E2E_ANDROID:-1}" == "0" ]]; then
  log "E2E_ANDROID=0 — android leg skipped (emulator untouched)"
elif command -v adb >/dev/null 2>&1; then
  if [[ "$(adb get-state 2>/dev/null || true)" != "device" ]]; then
    EMU="$(ls "$HOME/.android/avd" 2>/dev/null | grep -m1 haven_phone || true)"
    if [[ -n "$EMU" ]]; then
      log "booting android emulator haven_phone"
      boot_haven_emulator
      # A COLD boot (no snapshot) on a host that is also building the iOS app and the desktop takes
      # 5–6 minutes to even answer adb here. The old 3-minute wait gave up while it was still
      # booting, so two consecutive release-QA runs skipped the android leg — and the emulator that
      # finished booting a minute later sat idle for the whole run. Eight minutes, still bounded.
      for i in $(seq 1 160); do [[ "$(adb get-state 2>/dev/null || true)" == "device" ]] && break; sleep 3; done
    fi
  fi
  if [[ "$(adb get-state 2>/dev/null || true)" == "device" ]]; then
    # adb answers "device" well before Android finishes booting (push then fails with
    # secure_mkdirs) — wait for the real boot flag. The whole leg stays best-effort:
    # any failure degrades to a WARN, never kills the fleet.
    log "waiting for android boot_completed…"
    booted=0
    gone=0
    reborn=0
    for i in $(seq 1 100); do
      [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)" == "1" ]] && { booted=1; break; }
      # The "device" we saw can be an emulator ANOTHER suite is tearing down (the release gate's
      # android step boots haven_phone for its connected tests and kills it after): adb still says
      # "device" for a moment, then the emulator is gone and this loop used to burn its whole 5-minute
      # window polling nothing — gate-4 lost the android leg (call matrix, screenshare) that way.
      # Gone for 15 s → boot our own once and keep waiting on it.
      if [[ "$(adb get-state 2>/dev/null || true)" != "device" ]]; then gone=$((gone + 1)); else gone=0; fi
      if (( gone >= 5 && reborn == 0 )); then
        reborn=1
        log "android emulator vanished while we waited for it to boot — booting a fresh one"
        boot_haven_emulator
        for j in $(seq 1 160); do [[ "$(adb get-state 2>/dev/null || true)" == "device" ]] && break; sleep 3; done
        gone=0
      fi
      sleep 3
    done
    # Still not booted but present: a wedged boot. One cold reboot (bounded) before giving the leg up.
    if [[ "$booted" != "1" && "$(adb get-state 2>/dev/null || true)" == "device" ]]; then
      log "android emulator never reported boot_completed — cold-rebooting it once"
      cold_reboot_haven_emulator
    fi
    # A long-lived emulator can finish "booted" with core system services dead (seen: package
    # manager gone — "Can't find service: package" — after rild/bluetooth aborts). Installs and the
    # MediaStore dump channel then fail while the app itself looks healthy. Cold-reboot it once.
    if [[ "$booted" == "1" ]] && ! adb shell pm path android >/dev/null 2>&1; then
      log "android emulator is booted but its package manager is dead — cold-rebooting it"
      cold_reboot_haven_emulator
    fi
    # A REUSED emulator past E2E_EMU_MAX_UPTIME_S (default 90 min) is cold-rebooted before the run.
    # Emulator 36.6.11's qemu host process aborts in its own gRPC server (__throw_bad_function_call
    # under grpc CallbackWithSuccessTag::StaticRun) 2h49m–6h30m into its life — five crash reports in
    # a week. The 2026-09-30 gate reused a 5h20m-old emulator; it stopped acking network frames
    # during the android satellite lane and died four minutes later, and every android-authored
    # check read "never". A run is ~1 h, so starting under 90 min keeps it clear of that window.
    # E2E_EMU_MAX_UPTIME_S=0 disables the check.
    EMU_MAX_UPTIME_S="${E2E_EMU_MAX_UPTIME_S:-5400}"
    if [[ "$booted" == "1" ]] && (( EMU_MAX_UPTIME_S > 0 )); then
      emu_up="$(adb shell cat /proc/uptime 2>/dev/null | tr -d '\r' | cut -d. -f1 || true)"
      if [[ "$emu_up" =~ ^[0-9]+$ ]] && (( emu_up > EMU_MAX_UPTIME_S )); then
        log "android emulator has been up $((emu_up / 60)) min (> $((EMU_MAX_UPTIME_S / 60))) — cold-rebooting it before the run"
        cold_reboot_haven_emulator
      fi
    fi
    if [[ "$booted" != "1" ]]; then
      log "WARN: android emulator never finished booting — android leg skipped"
    else
    # The AVD must have a REAL network, not just the adb-reverse mailbox lane. airplane_mode_on
    # persists in the AVD's userdata, and a haven_phone left in airplane mode still passes every
    # mailbox step (127.0.0.1:8674 rides adb) while iroh has no route and no DNS: its direct dial
    # to the stub fails "No addressing information available", so android→stub call invites
    # never ring (an idle Apple callee only takes invites over iroh/push, never the __live__ HTTP
    # lane) and the call matrix read as a WebRTC regression. Restore it and say so.
    if [[ "$(adb shell settings get global airplane_mode_on 2>/dev/null | tr -d '\r')" == "1" ]]; then
      log "android emulator was in AIRPLANE MODE — disabling it (iroh/DNS/calls need a real network)"
      adb shell cmd connectivity airplane-mode disable >/dev/null 2>&1 || true
    fi
    adb shell svc wifi enable >/dev/null 2>&1 || true
    adb shell svc data enable >/dev/null 2>&1 || true
    net_ok=0
    wait_android_network 20 && net_ok=1
    if [[ "$net_ok" != "1" ]]; then
      # Recovery 1: bounce wifi (the radio sometimes comes up before the virtual AP).
      log "android emulator has no default network — bouncing wifi"
      adb shell svc wifi disable >/dev/null 2>&1 || true; sleep 2
      adb shell svc wifi enable >/dev/null 2>&1 || true
      wait_android_network 30 && net_ok=1
    fi
    if [[ "$net_ok" != "1" ]]; then
      # Recovery 2: a cold reboot with explicit DNS (a reused emulator may have been started by
      # something else without it).
      log "android emulator still has no network — cold-rebooting it with explicit DNS"
      adb emu kill >/dev/null 2>&1 || true
      for i in $(seq 1 30); do [[ "$(adb get-state 2>/dev/null || true)" != "device" ]] && break; sleep 1; done
      boot_haven_emulator
      for i in $(seq 1 160); do [[ "$(adb get-state 2>/dev/null || true)" == "device" ]] && break; sleep 3; done
      for i in $(seq 1 100); do
        [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)" == "1" ]] && break
        sleep 3
      done
      adb shell cmd connectivity airplane-mode disable >/dev/null 2>&1 || true
      adb shell svc wifi enable >/dev/null 2>&1 || true
      adb shell svc data enable >/dev/null 2>&1 || true
      wait_android_network 45 && net_ok=1
    fi
    [[ "$net_ok" == "1" ]] || log "WARN: android emulator has NO default network — iroh dials and android calls will fail"
    # gradle splits per ABI — universal covers every emulator arch.
    APK="$ROOT/android/app/build/outputs/apk/debug/app-universal-debug.apk"
    [[ -f "$APK" ]] || APK="$ROOT/android/app/build/outputs/apk/debug/app-arm64-v8a-debug.apk"
    # Rebuild when missing or stale (same rule as the iOS/stub/desktop legs) — otherwise the
    # emulator silently validates an old APK. gradle is incremental, so this is cheap when clean.
    if [[ ! -f "$APK" ]] || [[ -n "$(find "$ROOT/android/app/src" "$ROOT/core" -type f \( -name '*.kt' -o -name '*.rs' \) -newer "$APK" -print -quit 2>/dev/null)" ]]; then
      log "building android debug apk (missing or stale)…"
      # Resolve a JDK. There is no system Java on this Mac — gradle dies with "Unable to locate a
      # Java Runtime", and with the output piped that failure surfaced as exit 0, so the emulator
      # quietly kept running a days-old APK while the suite reported on it.
      if [[ -z "${JAVA_HOME:-}" ]] || [[ ! -x "${JAVA_HOME:-}/bin/java" ]]; then
        for cand in /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
                    "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
                    /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home; do
          [[ -x "$cand/bin/java" ]] && { export JAVA_HOME="$cand"; break; }
        done
      fi
      [[ -x "${JAVA_HOME:-}/bin/java" ]] || log "WARN: no JDK found — android build will fail"
      # iCloud Drive leaves "name 2.ext" conflict copies inside build/ (2,734 of them on 2026-10-06);
      # AGP rejects them ("Failed file name validation … ic_launcher_background 2.xml") and the leg
      # then silently ran the PREVIOUS apk. They are regenerable intermediates — drop them first.
      dupes=$(find "$ROOT/android/app/build" -name '* 2*' 2>/dev/null | wc -l | tr -d ' ')
      if [[ "${dupes:-0}" -gt 0 ]]; then
        find "$ROOT/android/app/build" -name '* 2*' -delete 2>/dev/null || true
        log "removed $dupes iCloud conflict copies from android/app/build"
      fi
      (cd "$ROOT/android" && ./gradlew assembleDebug -q) >>"$OUT/android-build.log" 2>&1 \
        || { log "FATAL: android build failed — see $OUT/android-build.log (refusing to score a stale apk)"; tail -15 "$OUT/android-build.log" >&2; exit 1; }
      [[ -f "$ROOT/android/app/build/outputs/apk/debug/app-universal-debug.apk" ]] \
        && APK="$ROOT/android/app/build/outputs/apk/debug/app-universal-debug.apk"
    fi
    if [[ -f "$APK" ]]; then
      # Other Haven builds on this shared emulator (the android-minified suite's
      # com.blaineam.haven.minified + its test APK) register the same haven:// and invite-link
      # filters; any unpinned VIEW then opens a system chooser over Haven and the qa driver — which
      # polls only while Haven is foregrounded — goes silent. Remove them before the fleet starts.
      for other in $(adb shell pm list packages com.blaineam.haven 2>/dev/null | tr -d '\r' | sed 's/^package://'); do
        [[ "$other" == "$AND_PKG" ]] && continue
        if adb uninstall "$other" >/dev/null 2>&1; then
          log "removed $other from the emulator (shares Haven's intent filters)"
        fi
      done
      if ! adb install -r "$APK" >/dev/null 2>&1; then
        # A long-lived emulator's system_server can lose the package service between the boot check
        # and the install ("Can't find service: package" / broken pipe). Cold-reboot once and retry.
        log "apk install failed — cold-rebooting the emulator and retrying once"
        adb emu kill >/dev/null 2>&1 || true
        for i in $(seq 1 30); do [[ "$(adb get-state 2>/dev/null || true)" != "device" ]] && break; sleep 1; done
        boot_haven_emulator
        for i in $(seq 1 160); do [[ "$(adb get-state 2>/dev/null || true)" == "device" ]] && break; sleep 3; done
        for i in $(seq 1 100); do
          [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)" == "1" ]] && break
          sleep 3
        done
        adb shell cmd connectivity airplane-mode disable >/dev/null 2>&1 || true
        adb shell svc wifi enable >/dev/null 2>&1 || true
        wait_android_network 45 || log "WARN: android emulator has NO default network after reboot"
        adb install -r "$APK" >/dev/null 2>&1 || log "WARN: apk install failed"
      fi
      # Compile the freshly installed debug APK ahead of time. A debug install runs interpreted /
      # JIT-only on the emulator; on a loaded host Android spent ~24s verifying and interpreting the
      # app's code before Application.onCreate even ran, so `launch` read "failed to complete
      # startup" and a 33s first feed. Real devices get AOT-compiled installs (baseline profiles /
      # Play), so measure the same thing here. Best-effort, bounded.
      adb shell cmd package compile -m speed -f "$AND_PKG" >/dev/null 2>&1 \
        && log "android apk AOT-compiled (speed)" || log "WARN: android AOT compile failed — launch timing will include interpretation"
      # Start every run with an empty qa channel (the app's internal files/qa/). The channel used
      # to be /sdcard/Download, where a reinstall orphaned MediaProvider's rows (owner UID change)
      # and every dump rename failed ("MediaProvider: Database update failed") — the harness then
      # read frozen dumps while the app was healthy. Sweep any leftovers of that old channel too.
      adb shell "run-as $AND_PKG rm -rf files/qa" >/dev/null 2>&1 || true
      adb shell 'rm -f /sdcard/Download/qa-*' >/dev/null 2>&1 || true
    else
      log "WARN: no debug apk found — android runs whatever is installed"
    fi
    # Seed adoption only happens on a FRESH identity, and it only fires at first boot —
    # so the seed MUST be staged before the app is ever launched. Force-stop + pm clear
    # here (even outside E2E_FRESH) so a stray earlier launch can\'t have minted an
    # identity that would make adoptSeedIfPresent refuse the fleet seed.
    adb shell am force-stop "$AND_PKG" >/dev/null 2>&1 || true
    adb shell pm clear "$AND_PKG" >/dev/null 2>&1 || true
    # pm clear (and a reinstall) REVOKE every runtime permission, and the next launch then opens on
    # a permission dialog instead of the app — a step that taps at fixed coordinates sails straight
    # past it and reports on whatever is underneath. Seen 2026-09-02: after `install -r` the QR
    # scanner's CAMERA grant was gone, the viewfinder never bound, and the tap looked like a no-op.
    # Read the grants off the manifest so this cannot drift as permissions are added; pm grant
    # rejects install-time permissions, hence the per-permission `|| true`.
    for _p in $(grep -oE 'android\.permission\.[A-Z_]+' "$ROOT/android/app/src/main/AndroidManifest.xml" | sort -u); do
      adb shell pm grant "$AND_PKG" "$_p" >/dev/null 2>&1 || true
    done
    adb reverse tcp:8674 tcp:8674 >/dev/null 2>&1 || true
    adb reverse tcp:8675 tcp:8675 >/dev/null 2>&1 || true
    # The qa channel is the app's INTERNAL files/qa/ (docs/QA.md "qa-cmd v2"): a debuggable build
    # lets `run-as` reach it, and no MediaProvider row sits in the path to rot. Writes push to a
    # shell-owned tmp, then run-as-copy into <name>.tmp and mv (atomic — the driver never sees half
    # a file). run-as CAN read /data/local/tmp on this AVD even though the app process cannot.
    and_qa_put() {   # <host file> <name under files/qa>
      local tmp="/data/local/tmp/haven-qa-$$-$2"
      adb push "$1" "$tmp" >/dev/null 2>&1 || return 1
      adb shell "run-as $AND_PKG sh -c 'umask 077 && mkdir -p files/qa && cat $tmp > files/qa/$2.tmp && mv -f files/qa/$2.tmp files/qa/$2'; rc=\$?; rm -f $tmp; exit \$rc" >/dev/null 2>&1
    }
    and_qa_has() { [[ "$(adb shell "run-as $AND_PKG test -f files/qa/$1 && echo y" 2>/dev/null | tr -d '\r')" == "y" ]]; }
    # Hand the fleet seed to the android DEBUG build — staged BEFORE first launch (adopted at boot).
    and_qa_put "$SEED_FILE" qa-seed.txt || log "WARN: run-as seed stage failed — android may run unseeded"
    adb shell am start -n "$AND_PKG/.MainActivity" >/dev/null 2>&1 || true
    sleep 8
    # Wire the stub relay through the qa driver (authoritative; prefs-file surgery
    # raced the app's own rewrites and left the leg silently relay-less).
    printf '{"op":"wire_relay","hex":"%s","urls":["http://10.0.2.2:8674","http://127.0.0.1:8674"],"token":"%s"}' "$NODE" "$TOKEN" >/tmp/and-wire.json
    and_qa_put /tmp/and-wire.json qa-cmd.json || log "WARN: run-as wire_relay stage failed"
    adb shell am start -a android.intent.action.VIEW -d "haven://qa" -p "$AND_PKG" >/dev/null 2>&1 || true
    # Wait for the driver to CONSUME the drop (it deletes it on apply). A cold emulator's first
    # launch can take well over the old fixed 4s to bring the engine up, and the harness's very
    # first {"op":"dump"} then OVERWROTE the unconsumed wire_relay — the leg ran the whole suite
    # with no relay at all (relay_stats [], warm-up "never") while every other leg was fine.
    for i in $(seq 1 60); do
      and_qa_has qa-cmd.json || break
      [[ $((i % 10)) == 0 ]] && adb shell am start -a android.intent.action.VIEW -d "haven://qa" -p "$AND_PKG" >/dev/null 2>&1
      sleep 1
    done
    and_qa_has qa-cmd.json && log "WARN: android never consumed wire_relay — this leg has NO relay"
    sleep 2
    ANDROID_HEXES="$OUT/android-hexes.txt"
    adb exec-out "run-as $AND_PKG cat files/qa/qa-device-hex.txt 2>/dev/null" >"$ANDROID_HEXES" 2>/dev/null || true
    if [[ -s "$ANDROID_HEXES" ]]; then
      { cat "$MEMBERS"; tr -d ' \r' <"$ANDROID_HEXES"; echo; } | grep -E '^[0-9a-f]{64}$' | sort -u >"$MEMBERS.next" || true
      [[ -s "$MEMBERS.next" ]] && mv "$MEMBERS.next" "$MEMBERS"
      authorize "$MEMBERS"
    else
      log "WARN: android device hex not dumped — android puts may be REFUSED"
    fi
    fi
  else
    log "WARN: no android emulator — android leg will be skipped"
  fi
fi

# ── 7. Give iOS the stub's bundle (B → A) and relaunch so it ingests ──────────
if [[ "$PREFRIEND" == "0" ]]; then
  log "E2E_PREFRIEND=0 — A and B left as strangers for the newfriend step"
elif [[ -s "$STUB_AS/qa-my-bundle.bin" ]]; then
  cp "$STUB_AS/qa-my-bundle.bin" "$AS/qa-peer-bundle.bin"
  cp "$STUB_AS/qa-my-name.txt" "$AS/qa-peer-name.txt" 2>/dev/null || printf 'FleetB' >"$AS/qa-peer-name.txt"
  xcrun simctl terminate "$SIM" "$IOS_BUNDLE" 2>/dev/null || true
  sleep 1
  SIMCTL_CHILD_HAVEN_SKIP_ONBOARDING=1 xcrun simctl launch "$SIM" "$IOS_BUNDLE" >/dev/null 2>&1 || true
  sleep 5
  log "staged B's bundle for iOS ingest + relaunched"
else
  log "WARN: stub qa-my-bundle.bin missing — A↔B contact link incomplete"
fi

log "fleet ready — sim=$SIM stub+tauri up, out=$OUT"
