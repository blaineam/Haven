#!/usr/bin/env bash
#
# Haven on the iPhone Duo — COVER panel (1398x2034) + INNER panel (2853x2007 landscape) for the
# APP_IPHONE_DUO store slot. Same scenes, same HAVEN_* demo environment, same warm-up as
# Tools/capture_screenshots.sh; each scene is captured ONLY on the panel DUO_PLAN assigns it.
#
# PRECONDITION: two booted iPhone Duo simulators, one folded (cover live), one unfolded (inner live).
# The fold cannot be scripted; this script never boots, reboots or shuts a Duo sim down (that would
# drop the posture). See _shared/screenshots/capture-lib.sh (cap_duo_*).
#
# Why this does NOT call cap_duo_prepare: Haven must be a SIGNED build (the data-protection keychain
# entitlement is what lets an identity persist; unsigned, DemoSeed's engine guard returns early and
# every scene is an empty shell) and cap_build_install forces CODE_SIGNING_ALLOWED=NO. So the
# build/install is done here, signed, with no -sdk flag (embedded HavenWatch collides with a forced sdk).
#
# Output: apple/screenshots/iphone-duo-{cover,inner}[/<locale>]/  (CAP_LOCALES=big8 for localized sets;
# launch arguments only). Usage: ./Tools/capture_duo.sh        (CAP_SKIP_CLEAN=1 keeps existing dirs)
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # -> apple/
cd "$PROJECT_ROOT"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/../../_shared/screenshots/capture-lib.sh"
# DUO_PLAN lives in the repo-root conf (rocket / duo-screenshots.sh read that one).
# shellcheck disable=SC1091
source "$PROJECT_ROOT/../.local-screenshots.conf"

PROJECT="$PROJECT_ROOT/Haven.xcodeproj"
SCHEME="Haven"
BUNDLE_ID="com.blaineam.kith"
export CAP_APP_NAME="Haven"
export CAP_STATUSBAR_STRIP=0.032   # wide panels: keep the OCR leak band shallow
OUT_DIR="$PROJECT_ROOT/screenshots"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/haven-shots-duo"

# "tab|scene|file" — identical to capture_screenshots.sh (NN = DUO_PLAN key).
SCENES=(
  "circle||01-feed.png"
  "circle|story|02-story.png"
  "messages|thread|03-thread.png"
  "circle|call|04-call.png"
  "you||05-you.png"
  "you|identity|06-identity.png"
  "messages||07-messages.png"
)

plan_posture() { local e; for e in "${DUO_PLAN[@]}"; do [ "${e%%:*}" = "$1" ] && { echo "${e##*:}"; return; }; done; }

# Simulators play app audio aloud: mute the Mac for the run, restore on exit.
SAVED_MUTED=""
mute_on() {
  SAVED_MUTED="$(osascript -e 'output muted of (get volume settings)' 2>/dev/null || true)"
  [ -n "$SAVED_MUTED" ] || SAVED_MUTED="false"
  osascript -e 'set volume output muted true' >/dev/null 2>&1 || true
}
mute_off() { [ -n "$SAVED_MUTED" ] && osascript -e "set volume output muted $SAVED_MUTED" >/dev/null 2>&1; SAVED_MUTED=""; return 0; }
trap mute_off EXIT

# ── Resolve both Duo sims (never boots anything) ───────────────────────────────────
cap_duo_sim_for cover >/dev/null || exit 1
cap_duo_sim_for inner >/dev/null || exit 1
echo "  Duo cover=$DUO_COVER_UDID inner=$DUO_INNER_UDID"
for u in "$DUO_COVER_UDID" "$DUO_INNER_UDID"; do
  xcrun simctl ui "$u" appearance light >/dev/null 2>&1 || true
  cap_clean_statusbar "$u" "$BUNDLE_ID"
done

# ── Signed build (xcodegen first: the checkout is FileProvider-tagged) ──────────────
( xcodegen generate >/dev/null 2>&1 ) || true
mkdir -p "$DERIVED"
echo "  Building $SCHEME (signed)…"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$DUO_COVER_UDID" -configuration Debug \
    -derivedDataPath "$DERIVED" \
    DEVELOPMENT_TEAM="${HAVEN_TEAM_ID:-8ZVSPZYSVF}" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build \
    >"$DERIVED/build.log" 2>&1; then
  echo "  build failed; tail of log:" >&2; tail -40 "$DERIVED/build.log" >&2; exit 1
fi
APP="$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name "*.app" | head -1)"
[ -n "$APP" ] || { echo "  no .app produced" >&2; exit 1; }
for u in "$DUO_COVER_UDID" "$DUO_INNER_UDID"; do
  xcrun simctl terminate "$u" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$u" "$BUNDLE_ID" >/dev/null 2>&1 || true   # clean state -> fresh seed
  xcrun simctl install "$u" "$APP"
done

if [ -z "${CAP_SKIP_CLEAN:-}" ]; then
  for P in cover inner; do rm -rf "${OUT_DIR:?}/iphone-duo-$P"; done
fi
for P in cover inner; do mkdir -p "$OUT_DIR/iphone-duo-$P"; done

mute_on

# Warm-up launch per sim primes the demo seed + JPEG decode (as in the iPhone rig).
for u in "$DUO_COVER_UDID" "$DUO_INNER_UDID"; do
  env SIMCTL_CHILD_HAVEN_DEMO=1 SIMCTL_CHILD_HAVEN_SKIP_ONBOARDING=1 SIMCTL_CHILD_HAVEN_NO_NET=1 \
      SIMCTL_CHILD_HAVEN_TAB=circle xcrun simctl launch "$u" "$BUNDLE_ID" >/dev/null 2>&1 || true
done
sleep 6
for u in "$DUO_COVER_UDID" "$DUO_INNER_UDID"; do xcrun simctl terminate "$u" "$BUNDLE_ID" >/dev/null 2>&1 || true; done

RC=0
capture_locale() {  # capture_locale <locale or "" for the English base>
  local locale="$1" entry tab rest scene file nn posture udid dir out tries sz largs=""
  [ -n "$locale" ] && largs="$(cap_locale_args "$locale")"
  echo "  — ${locale:-en-US}"
  for entry in "${SCENES[@]}"; do
    tab="${entry%%|*}"; rest="${entry#*|}"; scene="${rest%%|*}"; file="${rest#*|}"
    nn="${file%%-*}"; posture="$(plan_posture "$nn")"
    [ -n "$posture" ] || { echo "  ✗ $file is not in DUO_PLAN" >&2; RC=1; continue; }
    udid="$(cap_duo_udid "$posture")"
    dir="$OUT_DIR/iphone-duo-$posture"; [ -n "$locale" ] && dir="$dir/$locale"; mkdir -p "$dir"
    out="$dir/$file"
    cap_terminate_foreign "$udid" "$BUNDLE_ID"
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    sleep 0.6
    # HAVEN_* are read from the process ENVIRONMENT (SIMCTL_CHILD_), never launch arguments;
    # only the locale rides as launch arguments (never a system-language change / reboot).
    # shellcheck disable=SC2086
    env SIMCTL_CHILD_HAVEN_DEMO=1 SIMCTL_CHILD_HAVEN_SKIP_ONBOARDING=1 SIMCTL_CHILD_HAVEN_NO_NET=1 \
        SIMCTL_CHILD_HAVEN_TAB="$tab" SIMCTL_CHILD_HAVEN_SCENE="$scene" \
        xcrun simctl launch "$udid" "$BUNDLE_ID" $largs >/dev/null 2>&1
    sleep 9   # the demo seed blanks the UI until it finishes
    tries=0; sz=0
    while :; do
      cap_duo_shot "$posture" "$out" 2 || { RC=1; break; }
      sz=$(stat -f%z "$out" 2>/dev/null || echo 0)
      # A blank frame compresses tiny; real content is MBs. Re-capture until substantial.
      if [ "$sz" -ge 400000 ] || [ "$tries" -ge 5 ]; then break; fi
      tries=$((tries + 1)); sleep 4
    done
    echo "  iphone-duo-$posture${locale:+/$locale}/$file ($((sz / 1024))KB, $tries retries)"
  done
}

capture_locale ""
for LOCALE in $(cap_locales); do capture_locale "$LOCALE"; done
for P in cover inner; do
  u="$(cap_duo_udid "$P")"
  cap_clear_statusbar "$u"
  xcrun simctl terminate "$u" "$BUNDLE_ID" >/dev/null 2>&1 || true
done
echo "✓ Duo captures: $OUT_DIR/iphone-duo-{cover,inner}"
exit "$RC"
