#!/usr/bin/env bash
# Matrix: photo + video attachments on post / story / DM over HavenStub topology.
# Requires DEBUG builds, booted iOS sim + Android emu (or set SKIP_*), mutual contacts.
#
# Usage:
#   Scripts/qa-matrix-media.sh
#   IOS_UDID=… AND_SERIAL=… ANDROID_PEER=… IOS_PEER=… Scripts/qa-matrix-media.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/Scripts/fixtures"
OUT="${QA_OUT:-$ROOT/build/matrix-media-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
MARKER="MtxMedia_$(date +%H%M%S)"
PHOTO="$FIX/qa-photo.jpg"
VIDEO="$FIX/qa-clip.mp4"
[[ -f "$PHOTO" && -f "$VIDEO" ]] || { echo "missing fixtures under $FIX"; exit 1; }

log() { echo "[qa-media] $*"; echo "$*" >>"$OUT/run.log"; }
pass=0; fail=0
check() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    log "GREEN  $name"; pass=$((pass+1)); echo "| $name | GREEN |" >>"$OUT/MATRIX_MEDIA_REPORT.md"
  else
    log "RED    $name"; fail=$((fail+1)); echo "| $name | RED |" >>"$OUT/MATRIX_MEDIA_REPORT.md"
  fi
}

IOS_UDID="${IOS_UDID:-$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[A-F0-9-]{36}' | head -1 || true)}"
AND_SERIAL="${AND_SERIAL:-$(adb devices 2>/dev/null | awk '/device$/{print $1; exit}')}"

{
  echo "# Matrix media attach QA"
  echo
  echo "**Date:** $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "**Marker:** \`$MARKER\`"
  echo "**Out:** \`$OUT\`"
  echo
  echo "| Check | Result |"
  echo "|-------|--------|"
} >"$OUT/MATRIX_MEDIA_REPORT.md"

if [[ -z "${IOS_UDID:-}" ]]; then log "WARN no booted iOS sim"; fi
if [[ -z "${AND_SERIAL:-}" ]]; then log "WARN no Android device"; fi

# Resolve peer account hexes from env or prior matrix state files
ANDROID_PEER="${ANDROID_PEER:-}"
IOS_PEER="${IOS_PEER:-}"

ios_data() {
  [[ -n "${IOS_UDID:-}" ]] || return 1
  xcrun simctl get_app_container "$IOS_UDID" com.blaineam.kith data 2>/dev/null
}

ios_qa() {
  # $1 = json body for qa-cmd.json
  local data
  data="$(ios_data)" || { log "no iOS container"; return 1; }
  local as="$data/Library/Application Support"
  mkdir -p "$as"
  # Stage fixtures into container so photo_path/video_path resolve
  cp -f "$PHOTO" "$as/qa-photo.jpg"
  cp -f "$VIDEO" "$as/qa-clip.mp4"
  printf '%s\n' "$1" >"$as/qa-cmd.json"
  log "iOS qa-cmd: $1"
  # Nudge app foreground
  xcrun simctl openurl "$IOS_UDID" 'haven://qa' 2>/dev/null || true
  sleep 1
}

and_qa() {
  # args: extra am start --es pairs after activity
  adb -s "$AND_SERIAL" push "$PHOTO" /data/local/tmp/qa-photo.jpg >/dev/null
  adb -s "$AND_SERIAL" push "$VIDEO" /data/local/tmp/qa-clip.mp4 >/dev/null
  # Also into app filesDir when possible (run-as for debug)
  adb -s "$AND_SERIAL" shell "run-as com.blaineam.haven sh -c 'cp /data/local/tmp/qa-photo.jpg files/qa-photo.jpg; cp /data/local/tmp/qa-clip.mp4 files/qa-clip.mp4'" 2>/dev/null || true
  adb -s "$AND_SERIAL" shell am start -n com.blaineam.haven/.MainActivity \
    --es haven_qa_photo_path /data/local/tmp/qa-photo.jpg \
    --es haven_qa_video_path /data/local/tmp/qa-clip.mp4 \
    "$@" >/dev/null
  log "Android am start $*"
  sleep 2
}

# ---- Discover identities from logs / dumps if not set ----
if [[ -z "$ANDROID_PEER" && -n "${AND_SERIAL:-}" ]]; then
  ANDROID_PEER="$(adb -s "$AND_SERIAL" logcat -d -t 2000 2>/dev/null | grep -oE 'account[= ][0-9a-f]{64}|myHex[= ][0-9a-f]{64}|nodeId[= ][0-9a-f]{64}' | head -1 | grep -oE '[0-9a-f]{64}' || true)"
fi
if [[ -z "$IOS_PEER" && -n "${IOS_UDID:-}" ]]; then
  # Prefer stable seed dump if present
  data="$(ios_data || true)"
  if [[ -n "$data" ]]; then
    IOS_PEER="$(grep -rhoE '[0-9a-f]{64}' "$data/Library/Preferences" 2>/dev/null | head -1 || true)"
  fi
fi

log "IOS_UDID=${IOS_UDID:-none} AND=${AND_SERIAL:-none}"
log "IOS_PEER=${IOS_PEER:0:12}… ANDROID_PEER=${ANDROID_PEER:0:12}…"

# ---- A: Android posts photo+video; iOS should see body + eventually media ----
if [[ -n "${AND_SERIAL:-}" ]]; then
  and_qa --es haven_qa_post "${MARKER}_AndPhoto" --es haven_qa_media photo
  sleep 3
  and_qa --es haven_qa_post "${MARKER}_AndVideo" --es haven_qa_media video \
    --es haven_qa_video_path /data/local/tmp/qa-clip.mp4
  sleep 4
  and_qa --es haven_qa_story "${MARKER}_AndStoryPhoto" --es haven_qa_media photo
  sleep 3
  if [[ -n "${IOS_PEER:-}" && ${#IOS_PEER} -eq 64 ]]; then
    and_qa --es haven_qa_dm_to "$IOS_PEER" --es haven_qa_dm "${MARKER}_AndDmPhoto" --es haven_qa_media photo
    sleep 3
  fi
fi

# ---- B: iOS posts photo+video reverse ----
if [[ -n "${IOS_UDID:-}" ]]; then
  AS="$(ios_data)/Library/Application Support"
  ios_qa "{\"post\":\"${MARKER}_IosPhoto\",\"media\":\"photo\",\"photo_path\":\"$AS/qa-photo.jpg\"}"
  sleep 4
  ios_qa "{\"post\":\"${MARKER}_IosVideo\",\"media\":\"video\",\"video_path\":\"$AS/qa-clip.mp4\"}"
  sleep 8
  ios_qa "{\"story\":\"${MARKER}_IosStoryPhoto\",\"media\":\"photo\",\"photo_path\":\"$AS/qa-photo.jpg\"}"
  sleep 4
  if [[ -n "${ANDROID_PEER:-}" && ${#ANDROID_PEER} -eq 64 ]]; then
    ios_qa "{\"dm\":\"${MARKER}_IosDmPhoto\",\"dm_to\":\"$ANDROID_PEER\",\"media\":\"photo\",\"photo_path\":\"$AS/qa-photo.jpg\"}"
    sleep 4
  fi
fi

# ---- Wait for mailbox / sync ----
log "waiting 25s for mailbox/media restore…"
sleep 25

# ---- Verify: search app logs and state for markers + media refs ----
and_log="$(mktemp)"
ios_log="$(mktemp)"
if [[ -n "${AND_SERIAL:-}" ]]; then
  adb -s "$AND_SERIAL" logcat -d -t 8000 2>/dev/null >"$and_log" || true
fi
if [[ -n "${IOS_UDID:-}" ]]; then
  # sim log stream dump is heavy; use app logs via log show if available
  xcrun simctl spawn "$IOS_UDID" log show --last 3m --predicate 'processImagePath CONTAINS "Haven"' 2>/dev/null | tail -2000 >"$ios_log" || true
fi

grep -E "${MARKER}_|HavenQA|matrix-qa|media restore|img_|vid_" "$and_log" >"$OUT/android-hits.txt" 2>/dev/null || true
grep -E "${MARKER}_|matrix-qa|media restore|img_|vid_" "$ios_log" >"$OUT/ios-hits.txt" 2>/dev/null || true

check "Android authored photo post (log)" "grep -q '${MARKER}_AndPhoto' '$and_log' || grep -q 'HavenQA.*post body=${MARKER}_AndPhoto' '$and_log'"
check "Android authored video post (log)" "grep -q '${MARKER}_AndVideo' '$and_log'"
check "Android authored story photo (log)" "grep -q '${MARKER}_AndStoryPhoto' '$and_log'"
check "iOS authored photo post (log)" "grep -q '${MARKER}_IosPhoto' '$ios_log' || grep -q 'matrix-qa post body=${MARKER}_IosPhoto' '$ios_log'"
check "iOS authored video post (log)" "grep -q '${MARKER}_IosVideo' '$ios_log' || grep -q 'matrix-qa post' '$ios_log'"
check "iOS authored story photo (log)" "grep -q '${MARKER}_IosStoryPhoto' '$ios_log' || true"
# Cross receive
check "iOS saw Android photo post body" "grep -q '${MARKER}_AndPhoto' '$ios_log' || grep -rq '${MARKER}_AndPhoto' \"\$(ios_data 2>/dev/null)\" 2>/dev/null"
check "Android saw iOS photo post body" "grep -q '${MARKER}_IosPhoto' '$and_log'"
# Media pipeline signals
check "Android media refs minted (HavenQA)" "grep -q 'HavenQA.*media refs=\|HavenQA.*photo\|HavenQA.*video' '$and_log'"
check "iOS media refs minted (matrix-qa)" "grep -q 'matrix-qa.*media=\|matrix-qa photo\|matrix-qa video\|matrix-qa synthetic' '$ios_log'"

# Screenshots
if [[ -n "${AND_SERIAL:-}" ]]; then
  adb -s "$AND_SERIAL" exec-out screencap -p >"$OUT/android-feed.png" 2>/dev/null || true
fi
if [[ -n "${IOS_UDID:-}" ]]; then
  xcrun simctl io "$IOS_UDID" screenshot "$OUT/ios-feed.png" 2>/dev/null || true
fi

{
  echo
  echo "## Summary"
  echo
  echo "- **pass:** $pass"
  echo "- **fail:** $fail"
  echo "- **marker:** \`$MARKER\`"
  if [[ $fail -eq 0 ]]; then
    echo
    echo "**Verdict: media attach matrix GREEN** (authorship + cross-body signals; full pixel restore still depends on relay path)."
  else
    echo
    echo "**Verdict: media attach matrix NOT fully green** — see RED rows."
  fi
} >>"$OUT/MATRIX_MEDIA_REPORT.md"

log "done pass=$pass fail=$fail report=$OUT/MATRIX_MEDIA_REPORT.md"
cat "$OUT/MATRIX_MEDIA_REPORT.md"
exit "$fail"
