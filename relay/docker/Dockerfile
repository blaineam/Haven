# Haven relay in a container — pulls the prebuilt STATIC musl binary from the GitHub
# release (no Rust toolchain needed) and runs it. The binary is fully static and bundles
# its own TLS roots (webpki-roots), so it needs nothing from the OS but a place to store data.
#
# Ships official `cloudflared` next to haven-relay so free trycloudflare / named-token tunnels
# work out of the box (same model as Mac/desktop). Without it, Alpine has no curl at runtime
# and auto-download fails silently → LAN-only media URL and remote members never get media.
#
# Multi-arch: BuildKit/buildx sets TARGETARCH; the LEGACY builder (older NAS Docker) does NOT —
# there the declared-but-unset ARG tripped `set -u` (exit 2) before wget even ran, so we default
# it to "" and fall back to `uname -m` on the build machine (NAS builds are native-arch anyway).
# The default tracks the newest RELEASE, deliberately. Pin a specific tag with
# `--build-arg HAVEN_RELAY_VERSION=v1.1.2` when you want to hold a version on purpose.
# ── SOURCE mode ────────────────────────────────────────────────────────────────────────────
# `--build-arg HAVEN_RELAY_SOURCE=1` builds the relay from GitHub at `HAVEN_RELAY_REF` (a branch,
# tag or commit sha) instead of downloading a release asset — so a relay fix can be tested on the
# box that actually has the problem WITHOUT cutting a release for every iteration.
#
#     docker compose build --build-arg HAVEN_RELAY_SOURCE=1 --build-arg HAVEN_RELAY_REF=main
#
# Be warned this is a REAL Rust build (the relay pulls in iroh and the whole net stack): minutes on
# a fast machine, considerably longer on a NAS CPU, and it wants a couple of GB of RAM. The default
# download path is untouched and still needs no toolchain at all.
FROM rust:1-alpine AS build
ARG HAVEN_RELAY_SOURCE=0
ARG HAVEN_RELAY_REF=main
ARG HAVEN_RELAY_REPO=blaineam/haven
WORKDIR /src
RUN set -eux; \
    if [ "$HAVEN_RELAY_SOURCE" != "1" ]; then : > /haven-relay; exit 0; fi; \
    apk add --no-cache musl-dev pkgconfig openssl-dev wget tar; \
    wget -O /tmp/src.tgz "https://codeload.github.com/${HAVEN_RELAY_REPO}/tar.gz/${HAVEN_RELAY_REF}"; \
    tar -xzf /tmp/src.tgz -C /src --strip-components=1; \
    cargo build --release -p haven-relay --manifest-path core/Cargo.toml; \
    cp core/target/release/haven-relay /haven-relay

FROM alpine:3.20
# Keep in sync with core/haven-net/src/cfquicktunnel.rs CLOUDFLARED_VERSION.
ARG CLOUDFLARED_VERSION=2026.7.2
ARG HAVEN_RELAY_VERSION=latest
ARG HAVEN_RELAY_SOURCE=0
ARG TARGETARCH=""
COPY --from=build /haven-relay /tmp/haven-relay-src
RUN set -eux; \
    apk add --no-cache ca-certificates wget; \
    update-ca-certificates; \
    arch="$TARGETARCH"; \
    if [ -z "$arch" ]; then \
      case "$(uname -m)" in \
        x86_64) arch=amd64 ;; \
        aarch64|arm64) arch=arm64 ;; \
        armv7l|armv6l|armhf) arch=arm ;; \
      esac; \
    fi; \
    # ── haven-relay binary ──────────────────────────────────────────────────
    if [ "$HAVEN_RELAY_SOURCE" = "1" ]; then \
      install -m 0755 /tmp/haven-relay-src /usr/local/bin/haven-relay; \
      rm -f /tmp/haven-relay-src; \
    else \
      rm -f /tmp/haven-relay-src; \
      case "$arch" in \
        amd64) asset="haven-relay-x86_64-unknown-linux-musl" ;; \
        arm64) asset="haven-relay-aarch64-unknown-linux-musl" ;; \
        arm)   asset="haven-relay-armv7-unknown-linux-musleabihf" ;; \
        *) echo "unsupported arch: '$arch' (uname -m: $(uname -m)) — set --build-arg TARGETARCH=amd64|arm64|arm" >&2; exit 1 ;; \
      esac; \
      if [ "$HAVEN_RELAY_VERSION" = "latest" ]; then \
        url="https://github.com/blaineam/haven/releases/latest/download/$asset"; \
      else \
        url="https://github.com/blaineam/haven/releases/download/$HAVEN_RELAY_VERSION/$asset"; \
      fi; \
      wget -O /usr/local/bin/haven-relay "$url"; \
      chmod 0755 /usr/local/bin/haven-relay; \
    fi; \
    /usr/local/bin/haven-relay version; \
    # ── cloudflared (official CF release; Apache-2.0) ───────────────────────
    # Placed next to haven-relay so ensure_cloudflared finds it via PATH / exe dir
    # without a runtime download (Alpine has no curl after we strip the build tools).
    case "$arch" in \
      amd64) cf_asset="cloudflared-linux-amd64" ;; \
      arm64) cf_asset="cloudflared-linux-arm64" ;; \
      arm)   cf_asset="cloudflared-linux-arm" ;; \
      *) echo "unsupported arch for cloudflared: $arch" >&2; exit 1 ;; \
    esac; \
    wget -O /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/${cf_asset}"; \
    chmod 0755 /usr/local/bin/cloudflared; \
    /usr/local/bin/cloudflared version; \
    apk del wget; \
    mkdir -p /data

COPY entrypoint.sh /entrypoint.sh
# EXPLICIT mode, not `+x`: `chmod +x` only ADDS the exec bit to whatever mode COPY brought in.
# If a NAS share/ACL stripped the read bits from the host file, COPY lands it as 600 and `+x`
# yields 700 — unreadable by anyone but the owner ("can't open … Permission denied"). 0755 is
# unambiguous. Ditto the binary above.
RUN chmod 0755 /entrypoint.sh

# Persisted store (identity + sealed-blob mailbox); HAVEN_RELAY_DIR points the relay at it.
ENV HAVEN_RELAY_DIR=/data
# Ensure bundled cloudflared is found even if PATH is minimal.
ENV PATH="/usr/local/bin:${PATH}"
VOLUME ["/data"]
# Media HTTP, iroh DERP (TCP), circle TURN (UDP). Path proxy may use 8675 when fabric is on.
EXPOSE 8674 8675 3340 3478/udp
# Runs as root by default — the pragmatic choice for a NAS: it can always read /entrypoint.sh and
# write /data whether that's a named volume OR a bind mount to a NAS share (a non-root UID usually
# can't write a bind-mounted share, and UID mapping across NAS platforms is a mess). This is a
# self-hosted relay on your own box; if you'd rather run unprivileged, add `user: "1000:1000"` to
# the compose service and make sure that UID owns the data volume/dir.
ENTRYPOINT ["/entrypoint.sh"]
