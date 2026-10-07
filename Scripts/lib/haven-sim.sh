# shellcheck shell=bash
# The ONE iOS simulator the Haven QA fleet may touch, by UDID. Source this, then call haven_sim_udid.
#
# Never `simctl … booted` and never "the first booted device": other sessions boot their own sims
# (other apps' UI tests, screenshot rigs) and the QA scripts used to install, terminate, uninstall and
# wipe Haven on whichever booted sim listed first — on 2026-10-07 that was another session's
# "ES Restore Tests" iPhone mid-test. Selection, in order:
#   1. HAVEN_IOS_UDID (explicit override)
#   2. HAVEN_E2E_SIM_UDID default — the fleet's dedicated "iPhone 17 Pro" (80289DC4…) when it exists
#   3. a device named EXACTLY "iPhone 17 Pro" (booted one first) — never a renamed per-app clone
# Prints nothing (and returns 1) when none matches; callers fail loudly.
haven_sim_udid() {
  if [[ -n "${HAVEN_IOS_UDID:-}" ]]; then echo "$HAVEN_IOS_UDID"; return 0; fi
  local pinned="${HAVEN_E2E_SIM_UDID:-80289DC4-7E50-4C99-BE07-FDDCF3FF0CCF}"
  local list; list="$(xcrun simctl list devices available 2>/dev/null || true)"
  if grep -q "($pinned)" <<<"$list"; then echo "$pinned"; return 0; fi
  local named; named="$(grep -E '^[[:space:]]+iPhone 17 Pro \([A-F0-9-]{36}\)' <<<"$list" || true)"
  local pick; pick="$(grep '(Booted)' <<<"$named" | grep -oE '[A-F0-9-]{36}' | head -1 || true)"
  [[ -n "$pick" ]] || pick="$(grep -oE '[A-F0-9-]{36}' <<<"$named" | head -1 || true)"
  [[ -n "$pick" ]] || return 1
  echo "$pick"
}

# Boot the Haven sim if it is not already booted (by UDID — never touches any other device).
haven_sim_ensure_booted() {
  local udid="$1"
  if ! xcrun simctl list devices 2>/dev/null | grep -q "($udid) (Booted)"; then
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  fi
}
