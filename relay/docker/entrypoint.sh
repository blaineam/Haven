#!/bin/sh
# On the FIRST run, attach to your circle from HAVEN_RELAY_LINK (saved into /data). On every
# later run the saved link is reused and HAVEN_RELAY_LINK is IGNORED — see the long note below;
# re-applying it every start is a footgun, not a convenience. Any extra args (e.g. --no-storage)
# pass straight through.
set -eu

# ── Public media URL / cloudflared front door ────────────────────────────────
#
# Default (no HAVEN_RELAY_HTTP_URL): haven-relay auto-starts a free Cloudflare Quick Tunnel
# using the cloudflared binary shipped in this image (`*.trycloudflare.com`). Hostname is
# ephemeral — it changes on container restart; the app re-learns it via frame 19.
#
# Stable production NAS:
#   HAVEN_RELAY_HTTP_URL=https://relay.example.com
#   HAVEN_RELAY_TUNNEL_TOKEN=<cf install token>   # optional: spawn named tunnel in-process
#   # or leave token unset and run your own reverse proxy / host cloudflared
#
# LAN-only (no internet media):
#   HAVEN_RELAY_NO_TUNNEL=1
#   HAVEN_RELAY_HTTP_URL=http://192.168.1.50:8674   # optional LAN advertise
#
if [ -n "${HAVEN_RELAY_HTTP_URL:-}" ]; then
  set -- --http-url "$HAVEN_RELAY_HTTP_URL" "$@"
fi
if [ -n "${HAVEN_RELAY_TUNNEL_TOKEN:-}" ]; then
  set -- --tunnel-token "$HAVEN_RELAY_TUNNEL_TOKEN" "$@"
fi
if [ "${HAVEN_RELAY_NO_TUNNEL:-0}" = "1" ]; then
  set -- --no-tunnel "$@"
fi

# Haven fabric: circle-hosted iroh DERP (HTTPS front door → :3340) + TURN (UDP :3478).
# See docs/NAS-FABRIC-RELAY.md. Flags are ignored by older binaries (unknown flag → fail);
# use a fabric-capable build (feature/iroh-relay-gossip or newer release).
if [ -n "${HAVEN_RELAY_DERP_URL:-}" ]; then
  set -- --derp-url "$HAVEN_RELAY_DERP_URL" "$@"
fi
# Default DERP bind is 127.0.0.1 — useless behind Docker port publish. Listen on all interfaces
# unless the operator overrides (HAVEN_RELAY_DERP_BIND=127.0.0.1:3340 to keep it loopback).
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
if [ -n "${HAVEN_RELAY_TURN_BIND:-}" ]; then
  set -- --turn-bind "$HAVEN_RELAY_TURN_BIND" "$@"
fi
if [ "${HAVEN_RELAY_NO_DERP:-0}" = "1" ]; then
  set -- --no-derp "$@"
fi
if [ "${HAVEN_RELAY_NO_TURN:-0}" = "1" ]; then
  set -- --no-turn "$@"
fi

# Ensure bundled cloudflared is first on PATH (Dockerfile installs to /usr/local/bin).
export PATH="/usr/local/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
if command -v cloudflared >/dev/null 2>&1; then
  echo "▸ cloudflared: $(command -v cloudflared) ($(cloudflared version 2>/dev/null | head -1 || echo present))"
else
  echo "⚠ cloudflared not on PATH — free auto-tunnel will try download (may fail without curl)"
fi

# HAVEN_RELAY_LINK is applied ONLY on the first run — i.e. only while no link is saved in the data
# dir yet.
#
# It used to be re-applied on EVERY container start, and `--link` persists, so the value sitting in
# `.env` silently overwrote the relay's saved link each time the container came up. A user whose
# relay was serving one stale circle re-linked it by hand, watched it work, restarted the container
# for an unrelated reason, and was quietly reverted to the stale link — with nothing in the log to
# say so. Re-pasting a link was the only known fix for a frozen relay at the time, so this turned a
# fixable problem into a permanent one.
#
# It is also no longer needed: a relay now LEARNS circles from the members it is already paired with
# (the ENROLL control op), so the link is a one-time pairing handshake rather than a policy that has
# to be kept fresh in an env file.
#
# To deliberately re-link (e.g. pairing this relay with a different account), either set
# HAVEN_RELAY_LINK_FORCE=1 for one start, or delete the saved link:
#     docker compose exec haven-relay rm /data/link.json
HAVEN_RELAY_DIR="${HAVEN_RELAY_DIR:-/data}"
SAVED_LINK="$HAVEN_RELAY_DIR/link.json"
# Point cloudflared log dir at the data volume so free-tunnel failures are inspectable.
export HAVEN_CLOUDFLARED_LOG_DIR="${HAVEN_CLOUDFLARED_LOG_DIR:-$HAVEN_RELAY_DIR/logs}"
mkdir -p "$HAVEN_CLOUDFLARED_LOG_DIR" 2>/dev/null || true

if [ -n "${HAVEN_RELAY_LINK:-}" ] && [ -f "$SAVED_LINK" ] && [ "${HAVEN_RELAY_LINK_FORCE:-0}" != "1" ]; then
  echo "▸ HAVEN_RELAY_LINK is set, but this relay already has a saved link ($SAVED_LINK)."
  echo "  IGNORING the environment link and keeping the saved one — re-applying it on every start"
  echo "  is how a hand-fixed relay silently reverted to a stale circle list after a restart."
  echo "  The relay also learns new circles from its paired members, so the link does not need to"
  echo "  stay current. To re-link on purpose: set HAVEN_RELAY_LINK_FORCE=1 for one start, or"
  echo "  'rm $SAVED_LINK' and restart."
  exec haven-relay run "$@"
fi

if [ -n "${HAVEN_RELAY_LINK:-}" ]; then
  if [ -f "$SAVED_LINK" ]; then
    echo "▸ HAVEN_RELAY_LINK_FORCE=1 — OVERWRITING the saved link with the one from the environment."
  fi
  exec haven-relay run --link "$HAVEN_RELAY_LINK" "$@"
fi
exec haven-relay run "$@"
