#!/bin/sh
# On the FIRST run, attach to your circle from HAVEN_RELAY_LINK (saved into /data). On every
# later run the saved link is reused and HAVEN_RELAY_LINK is IGNORED — see the long note below.
#
# This script is also the relay's SUPERVISOR (see the bottom): it keeps cloudflared up, restarts
# the relay when it exits, runs a newer signed self-update from the data volume when there is one
# (so updates survive container recreation), and rolls a crashing update back — no Docker restart
# needed for any of it.
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
trap cleanup EXIT
STOP=0
RELAY_PID=""
on_signal() {
  STOP=1
  if [ -n "${RELAY_PID:-}" ]; then kill -TERM "$RELAY_PID" 2>/dev/null || true; fi
}
trap on_signal INT TERM

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

# ── Which link (if any) the FIRST start passes ───────────────────────────────
LINK_ONCE=""
if [ -n "${HAVEN_RELAY_LINK:-}" ] && [ -f "$SAVED_LINK" ] && [ "${HAVEN_RELAY_LINK_FORCE:-0}" != "1" ]; then
  echo "▸ HAVEN_RELAY_LINK is set, but this relay already has a saved link ($SAVED_LINK)."
  echo "  IGNORING the environment link and keeping the saved one."
elif [ -n "${HAVEN_RELAY_LINK:-}" ]; then
  if [ -f "$SAVED_LINK" ]; then
    echo "▸ HAVEN_RELAY_LINK_FORCE=1 — OVERWRITING the saved link with the one from the environment."
  fi
  LINK_ONCE="$HAVEN_RELAY_LINK"
fi

# ── Self-update wiring ───────────────────────────────────────────────────────
# The relay installs verified updates into the DATA VOLUME ($HAVEN_RELAY_DIR/update/bin), never
# into the image, so they persist across `docker compose up`/recreate. This loop runs that binary
# while it is newer than the image's own (a rebuilt, newer image always wins).
IMAGE_BIN="${HAVEN_RELAY_IMAGE_BIN:-$(command -v haven-relay || echo /usr/local/bin/haven-relay)}"
VOL_BIN="$HAVEN_RELAY_DIR/update/bin/haven-relay"
export HAVEN_RELAY_UPDATE_INSTALL="${HAVEN_RELAY_UPDATE_INSTALL:-volume}"
export HAVEN_RELAY_SUPERVISED=1
if [ -z "${HAVEN_RELAY_UPDATE_CHANNEL:-}" ]; then
  # Default: follow stable releases — except an image built FROM SOURCE (testing a branch), which
  # would otherwise be replaced by the next release. Set the channel explicitly to override.
  if [ -f /etc/haven-relay-source-build ]; then
    HAVEN_RELAY_UPDATE_CHANNEL=off
  else
    HAVEN_RELAY_UPDATE_CHANNEL=stable
  fi
fi
export HAVEN_RELAY_UPDATE_CHANNEL
EXIT_RESTART=75

pick_bin() {
  if [ -x "$VOL_BIN" ]; then
    sel="$("$IMAGE_BIN" update --pick-bin "$VOL_BIN" --data "$HAVEN_RELAY_DIR" 2>/dev/null || true)"
    if [ -n "$sel" ] && [ -x "$sel" ]; then
      echo "$sel"
      return
    fi
  fi
  echo "$IMAGE_BIN"
}

# Interruptible sleep (a trapped TERM must not wait out the whole back-off).
nap() {
  sleep "$1" &
  wait $! 2>/dev/null || true
}

# ── Supervisor loop ──────────────────────────────────────────────────────────
# Not `exec`: cloudflared (started above) must outlive relay restarts — which also keeps a free
# trycloudflare hostname STABLE across self-updates.
fast_fails=0
while :; do
  BIN="$(pick_bin)"
  if [ "$BIN" != "$IMAGE_BIN" ]; then
    echo "▸ running self-updated $("$BIN" version 2>/dev/null || echo haven-relay) from the data volume"
  fi
  started="$(date +%s)"
  if [ -n "$LINK_ONCE" ]; then
    "$BIN" run --link "$LINK_ONCE" "$@" &
  else
    "$BIN" run "$@" &
  fi
  RELAY_PID=$!
  # Only the first start carries --link: it is saved to $SAVED_LINK by then.
  LINK_ONCE=""
  code=0
  wait "$RELAY_PID" || code=$?
  # A trapped signal interrupts `wait` early — keep reaping until the relay has really exited.
  while kill -0 "$RELAY_PID" 2>/dev/null; do
    code=0
    wait "$RELAY_PID" || code=$?
  done
  RELAY_PID=""
  if [ "$STOP" = 1 ]; then
    exit 0
  fi
  if [ "$code" = "$EXIT_RESTART" ]; then
    echo "▸ relay restarting (update installed or rolled back)…"
    fast_fails=0
    continue
  fi
  ran=$(( $(date +%s) - started ))
  if [ "$ran" -lt 60 ]; then
    fast_fails=$((fast_fails + 1))
  else
    fast_fails=0
  fi
  # Safety net under the relay's own probation logic: a self-updated binary that keeps dying
  # right after start is rolled back (and marked bad) so the previous/image binary runs again.
  if [ "$BIN" != "$IMAGE_BIN" ] && [ "$fast_fails" -ge 3 ]; then
    echo "✗ self-updated relay exited $fast_fails times in a row (last code $code) — rolling back."
    "$IMAGE_BIN" update --rollback --data "$HAVEN_RELAY_DIR" || rm -f "$VOL_BIN"
    fast_fails=0
    continue
  fi
  delay=5
  i=1
  while [ "$i" -lt "$fast_fails" ] && [ "$delay" -lt 60 ]; do
    delay=$((delay * 2))
    i=$((i + 1))
  done
  [ "$delay" -gt 60 ] && delay=60
  echo "⚠ relay exited (code $code) — restarting in ${delay}s."
  nap "$delay"
  if [ "$STOP" = 1 ]; then
    exit 0
  fi
done
