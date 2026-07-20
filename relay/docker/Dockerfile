# Haven relay in a container — pulls the prebuilt STATIC musl binary from the GitHub
# release (no Rust toolchain needed) and runs it. The binary is fully static and bundles
# its own TLS roots (webpki-roots), so it needs nothing from the OS but a place to store data.
#
# Multi-arch: BuildKit/buildx sets TARGETARCH; the LEGACY builder (older NAS Docker) does NOT —
# there the declared-but-unset ARG tripped `set -u` (exit 2) before wget even ran, so we default
# it to "" and fall back to `uname -m` on the build machine (NAS builds are native-arch anyway).
# The default tracks the newest RELEASE, deliberately. It used to pin v0.1.0-beta.23, which meant
# anyone following the README got a relay from before 1.0 and kept it indefinitely — a relay is
# invisible when it works, so nothing ever prompted a rebuild. Relay-side protocol fixes (e.g. 1.1.2,
# where a link granted only ONE circle so a default relay served one and refused the rest) then never
# reached the boxes that needed them. Pin a specific tag with
# `--build-arg HAVEN_RELAY_VERSION=v1.1.2` when you want to hold a version on purpose.
# ── SOURCE mode ────────────────────────────────────────────────────────────────────────────
# `--build-arg HAVEN_RELAY_SOURCE=1` builds the relay from GitHub at `HAVEN_RELAY_REF` (a branch,
# tag or commit sha) instead of downloading a release asset — so a relay fix can be tested on the
# box that actually has the problem WITHOUT cutting a release for every iteration.
#
# It fetches the source itself rather than needing the repo in the build context, because the
# machine that runs a relay (a NAS) is usually not the machine that has a checkout. Nothing but the
# Dockerfile has to be present:
#
#     docker compose build --build-arg HAVEN_RELAY_SOURCE=1 --build-arg HAVEN_RELAY_REF=main
#
# The result is statically linked against musl exactly like the released binary, and
# `haven-relay version` reports the crate version it was built from.
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
ARG HAVEN_RELAY_VERSION=latest
ARG HAVEN_RELAY_SOURCE=0
ARG TARGETARCH=""
COPY --from=build /haven-relay /tmp/haven-relay-src
RUN set -eux; \
    if [ "$HAVEN_RELAY_SOURCE" = "1" ]; then \
      install -m 0755 /tmp/haven-relay-src /usr/local/bin/haven-relay; \
      rm -f /tmp/haven-relay-src; \
      mkdir -p /data; \
      /usr/local/bin/haven-relay version; \
      exit 0; \
    fi; \
    rm -f /tmp/haven-relay-src; \
    apk add --no-cache wget; \
    arch="$TARGETARCH"; \
    if [ -z "$arch" ]; then \
      case "$(uname -m)" in \
        x86_64) arch=amd64 ;; \
        aarch64|arm64) arch=arm64 ;; \
        armv7l|armv6l|armhf) arch=arm ;; \
      esac; \
    fi; \
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
VOLUME ["/data"]
# The plain-HTTP media interface (the reliable cross-NAT media path).
EXPOSE 8674
# Runs as root by default — the pragmatic choice for a NAS: it can always read /entrypoint.sh and
# write /data whether that's a named volume OR a bind mount to a NAS share (a non-root UID usually
# can't write a bind-mounted share, and UID mapping across NAS platforms is a mess). This is a
# self-hosted relay on your own box; if you'd rather run unprivileged, add `user: "1000:1000"` to
# the compose service and make sure that UID owns the data volume/dir.
ENTRYPOINT ["/entrypoint.sh"]
