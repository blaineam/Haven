#!/bin/sh
# On the FIRST run, attach to your circle from HAVEN_RELAY_LINK (saved into /data). On every
# later run the link is already saved, so `run` alone reuses it — leaving HAVEN_RELAY_LINK set
# is harmless (passing the same link just re-saves it). Any extra args (e.g. --no-storage,
# --http-url https://relay.example.com) pass straight through.
set -eu
if [ -n "${HAVEN_RELAY_LINK:-}" ]; then
  exec haven-relay run --link "$HAVEN_RELAY_LINK" "$@"
fi
exec haven-relay run "$@"
