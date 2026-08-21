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
DESK="${HAVEN_DESKTOP_BIN:-$ROOT/desktop/src-tauri/target/debug/haven-desktop}"
IOS_BUNDLE="${HAVEN_IOS_BUNDLE:-com.blaineam.kith}"
AND_PKG="${HAVEN_AND_PKG:-com.blaineam.haven}"

log() { echo "[e2e-boot] $*"; }


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
  pkill -f "HavenStub.app" 2>/dev/null || true
  pkill -f 'target/debug/haven-desktop' 2>/dev/null || true
  sleep 1
  rm -rf "$HOME/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support"/{haven-relay-store,haven-media,haven-feed.json,haven-mailbox-seen.txt,haven-selfsync.bin,qa-*} 2>/dev/null || true
  rm -rf "$DATA_DIR" 2>/dev/null || true
  SIM_FRESH="${HAVEN_IOS_UDID:-$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[A-F0-9-]{36}' | head -1)}"
  if [[ -n "$SIM_FRESH" ]]; then
    xcrun simctl terminate "$SIM_FRESH" "$IOS_BUNDLE" 2>/dev/null || true
    xcrun simctl uninstall "$SIM_FRESH" "$IOS_BUNDLE" 2>/dev/null || true
  fi
  if command -v adb >/dev/null 2>&1 && [[ "$(adb get-state 2>/dev/null || true)" == "device" ]]; then
    adb shell pm clear com.blaineam.haven >/dev/null 2>&1 || true
    adb shell rm -f /sdcard/Download/qa-seed.txt /sdcard/Download/qa-device-hex.txt "/sdcard/Download/qa-dump-$AND_PKG.json" 2>/dev/null || true
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
SIMCTL_CHILD_HAVEN_SKIP_ONBOARDING=1 xcrun simctl launch "$SIM" "$IOS_BUNDLE" >/dev/null 2>&1 || true

# ── 1b. Stage account A's contact bundle for the stub BEFORE its (only) launch —
# DEBUG builds ingest qa-peer-bundle.bin at startup, and mutual addContactBundle is
# what makes A↔B contacts (circle invites + DMs need it, mailbox auth alone doesn't).
STUB_AS_PRE="$HOME/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support"
APP_DATA_PRE="$(xcrun simctl get_app_container "$SIM" "$IOS_BUNDLE" data 2>/dev/null || true)"
if [[ -n "$APP_DATA_PRE" ]]; then
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
# resolve it live instead of trusting the baked default. The stub is SANDBOXED, so
# despite HOME=/tmp it writes to its container; the DEBUG seed dump lands there.
STUB_AS="$HOME/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support"
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
HAVEN_IOS_UDID="$SIM" "$ROOT/Scripts/qa-wire-stub-clients.sh" 2>&1 | tail -5 || true
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
"$ROOT/Scripts/qa-e2e-authorize.sh" "$MEMBERS"

# ── 5. Tauri as linked device of A ────────────────────────────────────────────
pkill -f 'target/debug/haven-desktop' 2>/dev/null || true; sleep 1
# Rebuild when missing OR stale — `[[ -x ]] ||` alone silently reran yesterday's binary.
# cargo is incremental, so this is a no-op when nothing changed.
if [[ ! -x "$DESK" ]] || [[ -n "$(find "$ROOT/core" "$ROOT/desktop/src-tauri/src" -type f -name '*.rs' -newer "$DESK" -print -quit 2>/dev/null)" ]]; then
  log "building haven-desktop (missing or stale)…"
  (cd "$ROOT/desktop/src-tauri" && cargo build -q) || { echo "error: desktop build FAILED"; exit 1; }
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
(cd "$ROOT/desktop/src-tauri" && HAVEN_QA_SEED_FILE="$SEED_FILE" RUST_LOG="${HAVEN_DESKTOP_LOG:-info}" "$DESK" >"$OUT/tauri.log" 2>&1) &
echo $! >"$OUT/tauri.pid"
sleep 10
for i in $(seq 1 30); do [[ -s "$DATA_DIR/qa-device-hex.txt" ]] && break; sleep 1; done
{ cat "$MEMBERS"; hexline "$DATA_DIR/qa-device-hex.txt"; hexline "$DATA_DIR/qa-account-hex.txt"; } \
  | grep -E '^[0-9a-f]{64}$' | sort -u >"$MEMBERS.next" || true
[[ -s "$MEMBERS.next" ]] && mv "$MEMBERS.next" "$MEMBERS"
"$ROOT/Scripts/qa-e2e-authorize.sh" "$MEMBERS"

# ── 6. Android emulator as linked device of A (best-effort leg) ───────────────
if command -v adb >/dev/null 2>&1; then
  if [[ "$(adb get-state 2>/dev/null || true)" != "device" ]]; then
    EMU="$(ls "$HOME/.android/avd" 2>/dev/null | grep -m1 haven_phone || true)"
    if [[ -n "$EMU" ]]; then
      log "booting android emulator haven_phone"
      nohup "${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/emulator/emulator" -avd haven_phone -no-snapshot-save -no-boot-anim >"$OUT/emulator.log" 2>&1 &
      for i in $(seq 1 60); do [[ "$(adb get-state 2>/dev/null || true)" == "device" ]] && break; sleep 3; done
    fi
  fi
  if [[ "$(adb get-state 2>/dev/null || true)" == "device" ]]; then
    # adb answers "device" well before Android finishes booting (push then fails with
    # secure_mkdirs) — wait for the real boot flag. The whole leg stays best-effort:
    # any failure degrades to a WARN, never kills the fleet.
    log "waiting for android boot_completed…"
    booted=0
    for i in $(seq 1 60); do
      [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)" == "1" ]] && { booted=1; break; }
      sleep 3
    done
    if [[ "$booted" != "1" ]]; then
      log "WARN: android emulator never finished booting — android leg skipped"
    else
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
      (cd "$ROOT/android" && ./gradlew assembleDebug -q) >>"$OUT/android-build.log" 2>&1 \
        || log "WARN: android build failed — see $OUT/android-build.log"
      [[ -f "$ROOT/android/app/build/outputs/apk/debug/app-universal-debug.apk" ]] \
        && APK="$ROOT/android/app/build/outputs/apk/debug/app-universal-debug.apk"
    fi
    if [[ -f "$APK" ]]; then
      adb install -r "$APK" >/dev/null 2>&1 || log "WARN: apk install failed"
    else
      log "WARN: no debug apk found — android runs whatever is installed"
    fi
    # Seed adoption only happens on a FRESH identity, and it only fires at first boot —
    # so the seed MUST be staged before the app is ever launched. Force-stop + pm clear
    # here (even outside E2E_FRESH) so a stray earlier launch can\'t have minted an
    # identity that would make adoptSeedIfPresent refuse the fleet seed.
    adb shell am force-stop "$AND_PKG" >/dev/null 2>&1 || true
    adb shell pm clear "$AND_PKG" >/dev/null 2>&1 || true
    adb shell appops set "$AND_PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
    # Scoped storage (API 30+): adb-pushed files in /sdcard/Download are shell-owned — grant the
    # DEBUG build's All-Files access so QaDriver can read qa-seed.txt / qa-cmd.json / fixtures.
    adb shell appops set "$AND_PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
    adb reverse tcp:8674 tcp:8674 >/dev/null 2>&1 || true
    adb reverse tcp:8675 tcp:8675 >/dev/null 2>&1 || true
    # hand the fleet seed to the android DEBUG build
    # Stage the seed where the app can actually read it at first boot: its OWN filesDir via
    # run-as (a debuggable app can always read filesDir; /sdcard needs a not-yet-live grant and
    # SELinux blocks /data/local/tmp). Push to a shell-owned tmp, then run-as-copy it in.
    adb push "$SEED_FILE" /data/local/tmp/qa-seed.txt >/dev/null 2>&1 || true
    adb shell "run-as $AND_PKG sh -c 'mkdir -p files && cat /data/local/tmp/qa-seed.txt > files/qa-seed.txt'" 2>/dev/null \
      || log "WARN: run-as seed stage failed — android may run unseeded"
    adb push "$SEED_FILE" /sdcard/Download/qa-seed.txt >/dev/null 2>&1 || true
    adb shell am start -n "$AND_PKG/.MainActivity" >/dev/null 2>&1 || true
    sleep 8
    # Wire the stub relay through the qa driver (authoritative; prefs-file surgery
    # raced the app's own rewrites and left the leg silently relay-less).
    printf '{"op":"wire_relay","hex":"%s","urls":["http://10.0.2.2:8674","http://127.0.0.1:8674"],"token":"%s"}' "$NODE" "$TOKEN" >/tmp/and-wire.json
    adb push /tmp/and-wire.json /sdcard/Download/qa-cmd.json >/dev/null 2>&1 || true
    adb shell am start -a android.intent.action.VIEW -d "haven://qa" >/dev/null 2>&1 || true
    sleep 4
    ANDROID_HEXES="$OUT/android-hexes.txt"
    adb pull /sdcard/Download/qa-device-hex.txt "$ANDROID_HEXES" >/dev/null 2>&1 || true
    if [[ -s "$ANDROID_HEXES" ]]; then
      { cat "$MEMBERS"; tr -d ' \r' <"$ANDROID_HEXES"; echo; } | grep -E '^[0-9a-f]{64}$' | sort -u >"$MEMBERS.next" || true
      [[ -s "$MEMBERS.next" ]] && mv "$MEMBERS.next" "$MEMBERS"
      "$ROOT/Scripts/qa-e2e-authorize.sh" "$MEMBERS"
    else
      log "WARN: android device hex not dumped — android puts may be REFUSED"
    fi
    fi
  else
    log "WARN: no android emulator — android leg will be skipped"
  fi
fi

# ── 7. Give iOS the stub's bundle (B → A) and relaunch so it ingests ──────────
if [[ -s "$STUB_AS/qa-my-bundle.bin" ]]; then
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
