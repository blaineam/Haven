#!/bin/sh
# On the FIRST run, attach to your circle from HAVEN_RELAY_LINK (saved into /data). On every
# later run the saved link is reused and HAVEN_RELAY_LINK is IGNORED — see the long note below.
set -eu

export PATH="/usr/local/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
HAVEN_RELAY_DIR="${HAVEN_RELAY_DIR:-/data}"
export HAVEN_CLOUDFLARED_LOG_DIR="${HAVEN_CLOUDFLARED_LOG_DIR:-$HAVEN_RELAY_DIR/logs}"
mkdir -p "$HAVEN_CLOUDFLARED_LOG_DIR" 2>/dev/null || true
CF_LOG="$HAVEN_CLOUDFLARED_LOG_DIR/cloudflared-quick.log"

# ── Public media URL / cloudflared front door ────────────────────────────────
# DEFAULT: free trycloudflare via bundled cloudflared (hostname changes on restart).
# Stable:  HAVEN_RELAY_HTTP_URL + optional HAVEN_RELAY_TUNNEL_TOKEN
# LAN:     HAVEN_RELAY_NO_TUNNEL=1
#
# Older haven-relay release binaries (e.g. 1.1.3) do not auto-spawn cloudflared.
# This entrypoint starts the free tunnel (or named token tunnel) and passes --http-url
# so the relay announces a real public origin to the circle.
CF_PID=""
cleanup() {
  if [ -n "${CF_PID:-}" ] && kill -0 "$CF_PID" 2>/dev/null; then
    kill "$CF_PID" 2>/dev/null || true
    wait "$CF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if command -v cloudflared >/dev/null 2>&1; then
  echo "▸ cloudflared: $(command -v cloudflared) ($(cloudflared version 2>/dev/null | head -1 || echo present))"
else
  echo "⚠ cloudflared not on PATH — free auto-tunnel unavailable"
fi

# Named tunnel (stable domain): spawn connector; operator sets HTTP_URL to that domain.
if [ -n "${HAVEN_RELAY_TUNNEL_TOKEN:-}" ] && [ "${HAVEN_RELAY_NO_TUNNEL:-0}" != "1" ]; then
  if command -v cloudflared >/dev/null 2>&1; then
    echo "▸ starting named Cloudflare tunnel (install token)…"
    : >"$CF_LOG"
    cloudflared tunnel --no-autoupdate run --token "$HAVEN_RELAY_TUNNEL_TOKEN" \
      >>"$CF_LOG" 2>&1 &
    CF_PID=$!
    sleep 2
  fi
fi

# Free quick tunnel when no public URL configured.
if [ -z "${HAVEN_RELAY_HTTP_URL:-}" ] \
  && [ -z "${HAVEN_RELAY_TUNNEL_TOKEN:-}" ] \
  && [ "${HAVEN_RELAY_NO_TUNNEL:-0}" != "1" ] \
  && command -v cloudflared >/dev/null 2>&1; then
  echo "▸ starting free Cloudflare Quick Tunnel → http://127.0.0.1:8675 (path proxy) …"
  : >"$CF_LOG"
  # Point at the PATH PROXY (8675), not the media server (8674).
  #
  # A quick tunnel gives exactly one hostname, which is why this used to expose media alone — but
  # the path proxy is what solves that: it fans one origin out to media (/k/ /l/ /t/), the iroh DERP
  # fabric (/relay /derp /ping) and the call-media hairpin (/webrtc/hairpin). Tunnelling straight to
  # 8674 published media and NOTHING else, so every client saw /webrtc/hairpin 404 and had no
  # reachable fabric — the call fallback path could never work on any platform, and it looked like a
  # client bug on whichever platform happened to be under test.
  cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8675 \
    >>"$CF_LOG" 2>&1 &
  CF_PID=$!
  # Scrape https://….trycloudflare.com (up to ~45s)
  i=0
  PUBLIC=""
  while [ $i -lt 45 ]; do
    if ! kill -0 "$CF_PID" 2>/dev/null; then
      echo "⚠ cloudflared exited early — see $CF_LOG"
      tail -20 "$CF_LOG" 2>/dev/null || true
      CF_PID=""
      break
    fi
    PUBLIC=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1 || true)
    if [ -n "$PUBLIC" ]; then
      echo "✓ free tunnel ready: $PUBLIC"
      echo "  (hostname is ephemeral — changes when this container restarts; apps re-learn via frame 19)"
      HAVEN_RELAY_HTTP_URL="$PUBLIC"
      export HAVEN_RELAY_HTTP_URL
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  if [ -z "${HAVEN_RELAY_HTTP_URL:-}" ] && [ -n "$CF_PID" ]; then
    echo "⚠ timed out waiting for trycloudflare URL — see $CF_LOG"
    tail -30 "$CF_LOG" 2>/dev/null || true
  fi
fi

if [ -n "${HAVEN_RELAY_HTTP_URL:-}" ]; then
  set -- --http-url "$HAVEN_RELAY_HTTP_URL" "$@"
fi
# If binary supports --tunnel-token and we have one, pass through (1.1.4+).
if [ -n "${HAVEN_RELAY_TUNNEL_TOKEN:-}" ]; then
  set -- --tunnel-token "$HAVEN_RELAY_TUNNEL_TOKEN" "$@" 2>/dev/null || true
fi
if [ "${HAVEN_RELAY_NO_TUNNEL:-0}" = "1" ]; then
  set -- --no-tunnel "$@" 2>/dev/null || true
fi

# Haven fabric: circle-hosted iroh DERP (HTTPS front door → :3340) + TURN (UDP :3478).
if [ -n "${HAVEN_RELAY_DERP_URL:-}" ]; then
  set -- --derp-url "$HAVEN_RELAY_DERP_URL" "$@"
fi
if [ -n "${HAVEN_RELAY_DERP_BIND:-}" ]; then
  set -- --derp-bind "$HAVEN_RELAY_DERP_BIND" "$@"
else
  set -- --derp-bind "0.0.0.0:3340" "$@"
fi
if [ -n "${HAVEN_RELAY_TURN_URL:-}" ]; then
  set -- --turn-url "$HAVEN_RELAY_TURN_URL" "$@"
fi
if [ -n "${HAVEN_RELAY_TURN_PUBLIC_IP:-}" ]; then
  set -- --turn-public-ip "$HAVEN_RELAY_TURN_PUBLIC_IP" "$@"
fi
if [ -z "${HAVEN_RELAY_TURN_URL:-}" ] && [ -z "${HAVEN_RELAY_TURN_PUBLIC_IP:-}" ] && [ "${HAVEN_RELAY_NO_TURN:-0}" != "1" ]; then
  echo "⚠ TURN: no HAVEN_RELAY_TURN_URL / HAVEN_RELAY_TURN_PUBLIC_IP set. Under bridge"
  echo "  networking the container cannot see a routable address, so TURN will NOT be"
  echo "  announced (clients fall back to STUN). For full call relay set"
  echo "  HAVEN_RELAY_TURN_PUBLIC_IP to this box's LAN IP (same-network peers) or its"
  echo "  public IP with UDP 3478 port-forwarded — or use network_mode: host."
fi
if [ -n "${HAVEN_RELAY_TURN_BIND:-}" ]; then
  set -- --turn-bind "$HAVEN_RELAY_TURN_BIND" "$@"
fi
if [ "${HAVEN_RELAY_NO_DERP:-0}" = "1" ]; then
  set -- --no-derp "$@"
fi
if [ "${HAVEN_RELAY_NO_TURN:-0}" = "1" ]; then
  set -- --no-turn "$@"
fi

SAVED_LINK="$HAVEN_RELAY_DIR/link.json"

if [ -n "${HAVEN_RELAY_LINK:-}" ] && [ -f "$SAVED_LINK" ] && [ "${HAVEN_RELAY_LINK_FORCE:-0}" != "1" ]; then
  echo "▸ HAVEN_RELAY_LINK is set, but this relay already has a saved link ($SAVED_LINK)."
  echo "  IGNORING the environment link and keeping the saved one."
  # Don't use exec — cloudflared child must outlive the shell; run in foreground and wait.
  haven-relay run "$@" &
  RELAY_PID=$!
  wait "$RELAY_PID"
  exit $?
fi

if [ -n "${HAVEN_RELAY_LINK:-}" ]; then
  if [ -f "$SAVED_LINK" ]; then
    echo "▸ HAVEN_RELAY_LINK_FORCE=1 — OVERWRITING the saved link with the one from the environment."
  fi
  haven-relay run --link "$HAVEN_RELAY_LINK" "$@" &
  RELAY_PID=$!
  wait "$RELAY_PID"
  exit $?
fi

haven-relay run "$@" &
RELAY_PID=$!
wait "$RELAY_PID"
exit $?
