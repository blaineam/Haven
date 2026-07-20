#!/bin/sh
# On the FIRST run, attach to your circle from HAVEN_RELAY_LINK (saved into /data). On every
# later run the link is already saved, so `run` alone reuses it — leaving HAVEN_RELAY_LINK set
# is harmless (passing the same link just re-saves it). Any extra args (e.g. --no-storage)
# pass straight through.
set -eu

# HAVEN_RELAY_HTTP_URL → --http-url. This matters far more in a container than the "optional,
# for a reverse proxy" framing suggests.
#
# The relay advertises its HTTP media interface by listing its own network addresses. Under Docker's
# default bridge networking that is the CONTAINER's address (172.x.y.z) — which nothing else on the
# LAN can reach. So peers get an unusable URL, silently fall back to the iroh blob dial, and every
# put and fetch times out: media stops syncing entirely while the relay looks perfectly healthy from
# the inside. Set this to how members actually reach this box:
#
#     HAVEN_RELAY_HTTP_URL=http://192.168.1.50:8674     (its LAN address)
#
# `network_mode: host` in the compose file is the other fix — then the relay sees the host's real
# addresses and works this out itself.
if [ -n "${HAVEN_RELAY_HTTP_URL:-}" ]; then
  set -- --http-url "$HAVEN_RELAY_HTTP_URL" "$@"
fi

if [ -n "${HAVEN_RELAY_LINK:-}" ]; then
  exec haven-relay run --link "$HAVEN_RELAY_LINK" "$@"
fi
exec haven-relay run "$@"
