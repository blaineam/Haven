# Haven relay in a container — pulls the prebuilt STATIC musl binary from the GitHub
# release (no Rust toolchain needed) and runs it. The binary is fully static and bundles
# its own TLS roots (webpki-roots), so it needs nothing from the OS but a place to store data.
#
# Multi-arch: `docker buildx` / compose sets TARGETARCH; we map it to the release asset.
# Pin a version with `--build-arg HAVEN_RELAY_VERSION=v0.1.0-beta.20` (or `latest`).
FROM alpine:3.20
ARG HAVEN_RELAY_VERSION=v0.1.0-beta.20
ARG TARGETARCH
RUN set -eux; \
    apk add --no-cache wget; \
    case "$TARGETARCH" in \
      amd64) asset="haven-relay-x86_64-unknown-linux-musl" ;; \
      arm64) asset="haven-relay-aarch64-unknown-linux-musl" ;; \
      arm)   asset="haven-relay-armv7-unknown-linux-musleabihf" ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
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
