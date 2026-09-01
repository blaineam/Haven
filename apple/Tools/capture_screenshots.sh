#!/usr/bin/env bash
#
# Haven — App Store / portfolio screenshots.
#
# Captures a RICH, PII-FREE set for iPhone + iPad (and, opt-in, Mac Catalyst) from the
# app's gated demo mode. Every scene is driven by launch-environment flags — NO real
# contacts, circles, posts, stories, or DMs are ever read or written:
#
#   HAVEN_DEMO=1            seed the synthetic dataset (DemoSeeder — fictional people,
#                          generated gradient "photos", deterministic throwaway keys)
#   HAVEN_SKIP_ONBOARDING=1 jump straight into the app
#   HAVEN_NO_NET=1          never bring the live P2P node online (offline + deterministic,
#                          and it suppresses the notification-permission prompt)
#   HAVEN_TAB=<circle|messages|you>   selected tab
#   HAVEN_SCENE=<scene>     auto-present a hero scene (story|thread|identity|call)
#
# IMPORTANT: these are read via ProcessInfo.processInfo.environment, so they MUST be
# passed as ENVIRONMENT variables (SIMCTL_CHILD_… for `simctl launch`), never as `-key
# value` launch arguments.
#
# Scenes (App Store display order) → screenshots/<rawKey>/NN-name.png at the sim's
# native size. Framing + (optional) upload happen in the shared update-screenshots.sh
# pipeline (.local-screenshots.conf + docs/appstore-screenshots/Haven-*.monkr).
#
# Usage: ./Tools/capture_screenshots.sh [all|iphone|ipad|mac]
#   (no arg == all == iphone + ipad; `mac` is opt-in — it needs an UNLOCKED + AWAKE
#    display with Screen Recording permission for the controlling terminal.)
#
# Build rules (hard-won across these repos): the Apple project is XcodeGen-generated
# and the checkout is FileProvider-tagged (it re-injects xattrs + spawns duplicate
# "Haven N.xcodeproj" copies), so we regenerate a fresh Haven.xcodeproj up front, build
# every leg synchronously into /tmp derived data, and pin the project path explicitly.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # → apple/
cd "$PROJECT_ROOT"

# shellcheck disable=SC1091
source "$PROJECT_ROOT/../../_shared/screenshots/capture-lib.sh"

PROJECT="$PROJECT_ROOT/Haven.xcodeproj"
SCHEME="Haven"
BUNDLE_ID="com.blaineam.kith"

IPHONE="iPhone 17 Pro Max"
APPLETV=""   # (none)
OUT="$PROJECT_ROOT/screenshots"
ONLY="${1:-all}"

# Scene table: "tab|scene|file". An empty scene just shows the tab.
SCENES=(
  "circle||01-feed.png"        # the private circle feed (stories + posts)
  "circle|story|02-story.png"  # full-screen stories
  "messages|thread|03-thread.png"  # a private DM thread (E2E)
  "circle|call|04-call.png"    # an in-progress group call
  "you||05-you.png"            # your profile (your posts live here)
  "you|identity|06-identity.png"   # your identity, on your devices
  "messages||07-messages.png"  # the DM list
)

# ── Audio: simulators play app audio aloud. Mute the Mac for the capture window only
#    and restore the user's exact previous state (even on abnormal exit).
SAVED_MUTED=""
mute_on() {
  [ -n "$SAVED_MUTED" ] && return 0
  SAVED_MUTED="$(osascript -e 'output muted of (get volume settings)' 2>/dev/null || true)"
  [ -n "$SAVED_MUTED" ] || SAVED_MUTED="false"
  osascript -e 'set volume output muted true' >/dev/null 2>&1 || true
}
mute_off() {
  [ -z "$SAVED_MUTED" ] && return 0
  osascript -e "set volume output muted $SAVED_MUTED" >/dev/null 2>&1 || true
  SAVED_MUTED=""
}
trap mute_off EXIT

# Resolve the first available device name from a candidate list (echoes the first that
# simctl already knows about; falls through to $1, which cap_resolve_udid will create).
resolve_device_name() {
  for cand in "$@"; do
    if xcrun simctl list devices available | grep -q "$cand ("; then echo "$cand"; return 0; fi
  done
  echo "$1"
}

# capture_sim <deviceName> <rawKey>
capture_sim() {
  local devName="$1" key="$2"
  echo "==> $devName ($key)"
  local udid; udid="$(cap_resolve_udid "$devName")"
  [ -n "$udid" ] || { echo "!! no simulator for $devName" >&2; return 1; }
  echo "  UDID: $udid"

  local derived="/tmp/haven-shots-dd-$key"
  mkdir -p "$derived"
  echo "  Building $SCHEME…"
  # MUST be SIGNED: an unsigned build has no data-protection keychain entitlement, so no identity
  # persists, FeedStore builds no social engine, and DemoSeed's `let main = feed.demoEngine` guard
  # returns early — every scene captures as an empty "No messages yet" shell.
  if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
      -destination "platform=iOS Simulator,id=$udid" -configuration Debug \
      -derivedDataPath "$derived" \
      DEVELOPMENT_TEAM="${HAVEN_TEAM_ID:-8ZVSPZYSVF}" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build \
      >"$derived/build.log" 2>&1; then
    echo "  build failed; tail of log:" >&2
    tail -40 "$derived/build.log" >&2
    return 1
  fi
  local app
  app="$(find "$derived/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name "*.app" | head -1)"
  [ -n "$app" ] || { echo "  no .app produced" >&2; return 1; }

  rm -rf "${OUT:?}/$key"; mkdir -p "$OUT/$key"
  mute_on
  cap_boot "$udid"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true   # clean state → fresh seed
  xcrun simctl install "$udid" "$app"
  cap_clean_statusbar "$udid"

  # Warm-up launch primes the demo seed + JPEG decode so the first real scene renders fast.
  env SIMCTL_CHILD_HAVEN_DEMO=1 SIMCTL_CHILD_HAVEN_SKIP_ONBOARDING=1 SIMCTL_CHILD_HAVEN_NO_NET=1 \
      SIMCTL_CHILD_HAVEN_TAB=circle \
      xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 6
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true

  for entry in "${SCENES[@]}"; do
    local tab="${entry%%|*}" rest="${entry#*|}"
    local scene="${rest%%|*}" file="${rest#*|}"
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    sleep 0.6
    env SIMCTL_CHILD_HAVEN_DEMO=1 SIMCTL_CHILD_HAVEN_SKIP_ONBOARDING=1 SIMCTL_CHILD_HAVEN_NO_NET=1 \
        SIMCTL_CHILD_HAVEN_TAB="$tab" SIMCTL_CHILD_HAVEN_SCENE="$scene" \
        xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null 2>&1
    # The demo seed re-runs on every launch and blanks the UI until it finishes; on a cold/slow sim the
    # first scenes were captured as a blank white screen (which compresses to a tiny ~90KB PNG, vs
    # 2-4MB of real content). Wait, then RE-CAPTURE until the shot is substantial — robust to seed timing.
    sleep 9
    local tries=0 sz=0
    while :; do
      # TCC: simctl's screenshot service can't write ~/Documents — TMPDIR + mv.
      local htmp="${TMPDIR:-/tmp}/.haven-shot-$$.png"
      xcrun simctl io "$udid" screenshot "$htmp" >/dev/null 2>&1 && mv -f "$htmp" "$OUT/$key/$file"
      sz=$(stat -f%z "$OUT/$key/$file" 2>/dev/null || echo 0)
      if [ "$sz" -ge 400000 ] || [ "$tries" -ge 5 ]; then break; fi
      tries=$((tries + 1)); sleep 4
    done
    echo "  $key/$file ($((sz / 1024))KB${tries:+, $tries retries})"
  done

  # Localized hero captures (CAP_LOCALES=big8) → <key>/<locale>/
  if [[ "$key" == iphone* || "$key" == ipad* ]] && [ -n "$(cap_locales)" ]; then
    for LOCALE in $(cap_locales); do
      echo "  — locale $LOCALE"
      mkdir -p "$OUT/$key/$LOCALE"
      for lentry in "${SCENES[@]}"; do
        local ltab="${lentry%%|*}" lrest="${lentry#*|}"
        local lscene="${lrest%%|*}" lfile="${lrest#*|}"
        xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
        sleep 0.6
        # shellcheck disable=SC2046
        env SIMCTL_CHILD_HAVEN_DEMO=1 SIMCTL_CHILD_HAVEN_SKIP_ONBOARDING=1 SIMCTL_CHILD_HAVEN_NO_NET=1 \
            SIMCTL_CHILD_HAVEN_TAB="$ltab" SIMCTL_CHILD_HAVEN_SCENE="$lscene" \
            xcrun simctl launch "$udid" "$BUNDLE_ID" $(cap_locale_args "$LOCALE") >/dev/null 2>&1
        sleep 9
        local ltries=0 lsz=0
        while :; do
          local htmp="${TMPDIR:-/tmp}/.haven-shot-$$.png"
          xcrun simctl io "$udid" screenshot "$htmp" >/dev/null 2>&1 && mv -f "$htmp" "$OUT/$key/$LOCALE/$lfile"
          lsz=$(stat -f%z "$OUT/$key/$LOCALE/$lfile" 2>/dev/null || echo 0)
          if [ "$lsz" -ge 400000 ] || [ "$ltries" -ge 5 ]; then break; fi
          ltries=$((ltries + 1)); sleep 4
        done
        echo "  $key/$LOCALE/$lfile ($((lsz / 1024))KB)"
      done
    done
  fi

  cap_clear_statusbar "$udid"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  mute_off
}

# ── macOS leg (opt-in) ──────────────────────────────────────────────────────────────
# Haven on macOS is a NATIVE windowed app (HavenMac scheme — Catalyst is long gone). We
# build it, launch each scene with the same HAVEN_* env (binary exec'd directly — `open`
# does NOT propagate the caller's environment), resolve the app's window via the shared
# mac-window-id.swift, and `screencapture -o -l<id>` it as a clean floating-window PNG
# (rounded corners + alpha; no full-screen control needed — it's not a menu-bar app).
# Requires an UNLOCKED + AWAKE display + Screen Recording permission for the terminal.
capture_mac() {
  local key="mac"
  echo "==> macOS native ($key)"
  local SHARED="$PROJECT_ROOT/../../_shared/screenshots"
  [ -f "$SHARED/mac-window-id.swift" ] || { echo "  !! $SHARED/mac-window-id.swift missing" >&2; return 1; }

  local LOCKED
  LOCKED=$(swift - <<'SWIFT' 2>/dev/null
import CoreGraphics; import Foundation
if let d = CGSessionCopyCurrentDictionary() as? [String:Any] { print(d["CGSSessionScreenIsLocked"] as? Int ?? 0) } else { print(0) }
SWIFT
)
  if [ "$LOCKED" = "1" ]; then
    echo "  !! display is LOCKED — unlock + keep awake, then re-run \`./Tools/capture_screenshots.sh mac\`." >&2
    return 1
  fi

  local derived="/tmp/haven-shots-dd-mac"
  mkdir -p "$derived"
  echo "  Building HavenMac (native macOS)…"
  # Signed for the same reason as the sim leg: no entitlement ⇒ no identity ⇒ no demo engine ⇒
  # every scene captures empty.
  if ! xcodebuild -project "$PROJECT" -scheme HavenMac \
      -destination "platform=macOS" -configuration Debug \
      -derivedDataPath "$derived" \
      DEVELOPMENT_TEAM="${HAVEN_TEAM_ID:-8ZVSPZYSVF}" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build \
      >"$derived/mac-build.log" 2>&1; then
    echo "  mac build failed; tail of log:" >&2
    tail -40 "$derived/mac-build.log" >&2
    return 1
  fi
  local APP
  APP="$(find "$derived/Build/Products" -maxdepth 2 -name "Haven.app" | head -1)"
  [ -n "$APP" ] || { echo "  no HavenMac .app produced" >&2; return 1; }

  rm -rf "${OUT:?}/$key"; mkdir -p "$OUT/$key"
  mute_on
  caffeinate -d -i -u -t 600 >/dev/null 2>&1 &  local caff=$!
  for entry in "${SCENES[@]}"; do
    local tab="${entry%%|*}" rest="${entry#*|}"
    local scene="${rest%%|*}" file="${rest#*|}"
    pkill -f "Haven.app/Contents/MacOS/Haven" 2>/dev/null; sleep 1
    # Exec the binary directly — env vars do NOT survive LaunchServices (`open`).
    HAVEN_DEMO=1 HAVEN_SKIP_ONBOARDING=1 HAVEN_NO_NET=1 HAVEN_TAB="$tab" HAVEN_SCENE="$scene" \
      "$APP/Contents/MacOS/Haven" >/dev/null 2>&1 &
    sleep 7
    local wid; wid="$(swift "$SHARED/mac-window-id.swift" "Haven" 2>/dev/null)"
    if [ -n "$wid" ]; then
      screencapture -o -x -l"$wid" "$OUT/$key/$file" 2>/dev/null && echo "  $key/$file (window $wid)"
    else
      echo "  !! no window for scene $scene" >&2
    fi
  done
  pkill -f "Haven.app/Contents/MacOS/Haven" 2>/dev/null
  kill "$caff" 2>/dev/null
  mute_off
}

# ── Dispatch ────────────────────────────────────────────────────────────────────────
RC=0
if [ "$ONLY" = "all" ] || [ "$ONLY" = "iphone" ]; then
  capture_sim "$IPHONE" "iphone-6.9" || RC=1
fi
if [ "$ONLY" = "all" ] || [ "$ONLY" = "ipad" ]; then
  IPAD="$(resolve_device_name "iPad Pro 13-inch (M5)" "iPad Pro 13-inch (M4)" "iPad Pro (12.9-inch) (6th generation)")"
  capture_sim "$IPAD" "ipad-13" || RC=1
fi
if [ "$ONLY" = "mac" ]; then
  capture_mac || echo "  (mac leg skipped — see message above)"
fi

echo ""
echo "==> Done. Raw screenshots under: $OUT"
ls -d "$OUT"/*/ 2>/dev/null || true
exit "$RC"
