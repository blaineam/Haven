# Haven relay in a container — pulls the prebuilt STATIC musl binary from the GitHub
# release (no Rust toolchain needed) and runs it. The binary is fully static and bundles
# its own TLS roots (webpki-roots), so it needs nothing from the OS but a place to store data.
#
# Multi-arch: `docker buildx` / compose sets TARGETARCH; we map it to the release asset.
# Pin a version with `--build-arg HAVEN_RELAY_VERSION=v0.1.0-beta.19` (or `latest`).
FROM alpine:3.20
ARG HAVEN_RELAY_VERSION=v0.1.0-beta.18
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
    chmod +x /usr/local/bin/haven-relay; \
    apk del wget; \
    adduser -D -H -u 10001 haven; \
    mkdir -p /data && chown 10001:10001 /data

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Persisted store (identity + sealed-blob mailbox); HAVEN_RELAY_DIR points the relay at it.
ENV HAVEN_RELAY_DIR=/data
VOLUME ["/data"]
# The plain-HTTP media interface (the reliable cross-NAT media path).
EXPOSE 8674
USER 10001:10001
ENTRYPOINT ["/entrypoint.sh"]
