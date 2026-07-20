#!/usr/bin/env sh
# Haven relay — one-command setup to be your circle's always-on mailbox.
#
# THE EASY WAY (default): install the `haven-relay` static binary and run it. It links to
# your circle and serves BOTH roles — live connection relay AND the sealed-media mailbox —
# straight off THIS machine's local disk, over Haven Net (iroh). No cloud, no S3, no ports,
# no domain, no config. Every blob it stores is end-to-end sealed to your circle, so the
# relay can never read anything.
#
#   curl -fsSL https://wemiller.com/apps/haven/relay/install.sh | sh
#   # then:
#   haven-relay run --link "haven-relay://circle#...."   # paste the link the app shows you
#   haven-relay run                                       # restart later: reuses the saved link
#
# THE CLASSIC WAY (--bucket): self-host a plain S3 bucket with `rclone serve s3` and point
# Haven at it (needs a public IP / port-forward / VPS). Prefer a managed bucket (R2/B2/S3)?
# You don't need this script — see README.md.
#
# Usage:
#   sh install.sh                       # install the haven-relay binary (recommended)
#   sh install.sh --bucket [--native]   # classic rclone-serve-s3 bucket instead
#   sh install.sh --bucket --port 8333 --dir ~/haven-bridge
set -eu

MODE=relay        # relay | bucket
BUCKET_MODE=docker
PORT=8333
DATADIR="${HAVEN_BRIDGE_DIR:-$HOME/haven-bridge}"
BUCKET=haven
PREFIX="${PREFIX:-$HOME/.local/bin}"
REPO="${HAVEN_RELAY_REPO:-blaineam/haven}"   # GitHub releases host the prebuilt binaries
RELAY_DATA="${HAVEN_RELAY_DATA:-}"   # custom storage path for the relay (identity + sealed-blob store)
WANT_SERVICE=1                       # auto-set up start-on-restart (platform-detected)

while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) MODE=bucket ;;
    --native) BUCKET_MODE=native ;;
    --port)   PORT="$2"; shift ;;
    --dir)    DATADIR="$2"; shift ;;
    --store|--data) RELAY_DATA="$2"; shift ;;   # custom relay storage path (where sealed blobs live)
    --no-service)   WANT_SERVICE=0 ;;            # skip the auto-start setup
    --prefix) PREFIX="$2"; shift ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
  shift
done

# Threaded into every relay command so the storage dir, auto-start, and the link all agree.
DATA_ARG=""
[ -n "$RELAY_DATA" ] && DATA_ARG="--data $RELAY_DATA"

OS="$(uname -s 2>/dev/null || echo unknown)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"

# ─────────────────────────────────────────────────────────────────────────────────────
# THE EASY WAY — install the haven-relay static binary.
# ─────────────────────────────────────────────────────────────────────────────────────
install_relay() {
  case "$OS-$ARCH" in
    Linux-x86_64)              TARGET="x86_64-unknown-linux-musl" ;;
    Linux-aarch64|Linux-arm64) TARGET="aarch64-unknown-linux-musl" ;;   # 64-bit Raspberry Pi OS / Arm servers
    Linux-armv7l)              TARGET="armv7-unknown-linux-musleabihf" ;; # 32-bit Raspbian, Pi 2/3/4
    Linux-armv6l)              TARGET="arm-unknown-linux-musleabihf" ;;   # Pi Zero / Pi 1
    Darwin-arm64)   TARGET="aarch64-apple-darwin" ;;
    Darwin-x86_64)  TARGET="x86_64-apple-darwin" ;;
    *) echo "✗ No prebuilt haven-relay for $OS-$ARCH."
       echo "  Build from source:  cd core && cargo build --release -p haven-relay"
       exit 1 ;;
  esac

  mkdir -p "$PREFIX"
  URL="https://github.com/${REPO}/releases/latest/download/haven-relay-${TARGET}"
  echo "▸ Downloading haven-relay ($TARGET)…"
  # Download beside the target and RENAME into place, rather than writing over it.
  #
  # This is also the upgrade path: re-running the installer on a box where the relay is already
  # running used to fail, because writing over a RUNNING executable returns ETXTBSY ("text file
  # busy") on Linux — and the error below then blamed a missing release asset, which sent people
  # looking in entirely the wrong place. rename(2) swaps the directory entry instead of touching
  # the running inode, so it succeeds while the old binary keeps serving until it is restarted.
  if curl -fsSL "$URL" -o "$PREFIX/haven-relay.new"; then
    chmod +x "$PREFIX/haven-relay.new"
    UPGRADE=0
    [ -e "$PREFIX/haven-relay" ] && UPGRADE=1
    mv -f "$PREFIX/haven-relay.new" "$PREFIX/haven-relay"
    if [ "$UPGRADE" = 1 ]; then
      echo "▸ Replaced an existing haven-relay — it keeps running the OLD binary until restarted."
      RESTART_HINT=1
    fi
  else
    rm -f "$PREFIX/haven-relay.new"
    echo "✗ Could not download a prebuilt binary (no release asset yet for $TARGET?)."
    echo "  Build from source instead:"
    echo "      git clone https://github.com/${REPO} && cd haven/core"
    echo "      cargo build --release -p haven-relay"
    echo "      cp target/release/haven-relay \"$PREFIX/\""
    exit 1
  fi

  echo
  echo "═══════════════════════════════════════════════════════════════"
  echo "✓ Installed: $PREFIX/haven-relay"
  case ":$PATH:" in
    *":$PREFIX:"*) : ;;
    *) echo "  (add $PREFIX to your PATH, or run it by full path)" ;;
  esac

  BIN="$PREFIX/haven-relay"
  STORE_DESC="${RELAY_DATA:-~/.haven-relay}"

  # Auto-set-up start-on-restart, platform-detected (systemd user unit / launchd agent / Task
  # Scheduler / @reboot cron). The binary picks the right mechanism; we just thread the storage
  # path through so the auto-started service uses the same data dir. It won't START until you've
  # linked a circle (below) — it just registers, then comes up on the next login.
  if [ "$WANT_SERVICE" = 1 ]; then
    echo "▸ Setting up auto-start on restart…"
    # shellcheck disable=SC2086
    "$BIN" service install $DATA_ARG || echo "  (couldn't auto-install the service; see 'haven-relay service install')"
  fi

  echo "═══════════════════════════════════════════════════════════════"
  echo
  echo "Now make it your circle's mailbox in two steps:"
  echo
  echo "  1. In the Haven app:  You → Advanced → Relay → \"Add a relay\""
  echo "     It shows a relay link (haven-relay://circle#...). Copy it."
  echo
  echo "  2. On this machine (one time, to attach + save the link):"
  echo "       haven-relay run --link \"haven-relay://circle#....\" $DATA_ARG"
  echo
  echo "It generates + SAVES its own identity, stores the circle's sealed blobs in"
  echo "  $STORE_DESC/store, and serves them over Haven Net. After that first link it"
  echo "auto-starts on every restart (set up above) — no need to keep a terminal open."
  echo
  echo "  • Restart manually any time:   haven-relay run $DATA_ARG"
  echo "  • Remove the auto-start:       haven-relay service uninstall"
  if [ "${RESTART_HINT:-0}" = 1 ]; then
    echo
    echo "  ⚠ UPGRADE: the new binary is installed but the OLD one is still running."
    echo "    Restart it to pick this up — your identity, link and store are untouched:"
    echo "      Linux (systemd user unit):  systemctl --user restart haven-relay"
    echo "      macOS (launchd agent):      launchctl kickstart -k gui/\$(id -u)/com.haven.relay"
    echo "      Docker:                     docker compose pull && docker compose up -d"
    echo "      Anything else:              stop it, then  haven-relay run $DATA_ARG"
  fi
  echo
  echo "The relay only ever moves ciphertext. It cannot read your circle's content."
  echo "═══════════════════════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────────────────────
# THE CLASSIC WAY — self-host an S3 bucket with rclone serve s3.
# ─────────────────────────────────────────────────────────────────────────────────────
start_bucket() {
  mkdir -p "$DATADIR/data/$BUCKET"   # the folder named '$BUCKET' IS the S3 bucket

  CREDFILE="$DATADIR/.haven-bridge-creds"
  if [ -f "$CREDFILE" ]; then
    . "$CREDFILE"
  else
    AKEY="haven$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    SKEY="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf 'AKEY=%s\nSKEY=%s\n' "$AKEY" "$SKEY" > "$CREDFILE"
    chmod 600 "$CREDFILE"
  fi

  echo "▸ Haven bucket (rclone serve s3 — MIT)  OS=$OS ARCH=$ARCH mode=$BUCKET_MODE"
  echo "▸ Data dir: $DATADIR"

  if [ "$BUCKET_MODE" = docker ]; then
    command -v docker >/dev/null 2>&1 || { echo "✗ Docker not found. Re-run with --native."; exit 1; }
    docker rm -f haven-bridge >/dev/null 2>&1 || true
    docker run -d --name haven-bridge --restart unless-stopped \
      -p "$PORT:8333" -v "$DATADIR/data:/data" \
      rclone/rclone serve s3 /data --addr :8333 --auth-key "$AKEY,$SKEY" >/dev/null
    echo "✓ rclone serve s3 running in Docker (container: haven-bridge, auto-restarts)."
  else
    BIN="$DATADIR/rclone"
    if ! command -v rclone >/dev/null 2>&1 && [ ! -x "$BIN" ]; then
      case "$OS-$ARCH" in
        Linux-x86_64)  RC="linux-amd64" ;;
        Linux-aarch64) RC="linux-arm64" ;;
        Darwin-arm64)  RC="osx-arm64" ;;
        Darwin-x86_64) RC="osx-amd64" ;;
        *) echo "✗ No native rclone build for $OS-$ARCH. Use Docker (drop --native)."; exit 1 ;;
      esac
      echo "▸ Downloading rclone ($RC)…"
      curl -fsSL "https://downloads.rclone.org/rclone-current-${RC}.zip" -o "$DATADIR/rclone.zip"
      unzip -oj "$DATADIR/rclone.zip" '*/rclone' -d "$DATADIR" >/dev/null
      rm -f "$DATADIR/rclone.zip"; chmod +x "$BIN"
    fi
    RCLONE="$(command -v rclone || echo "$BIN")"
    nohup "$RCLONE" serve s3 "$DATADIR/data" --addr ":$PORT" --auth-key "$AKEY,$SKEY" \
      >"$DATADIR/rclone.log" 2>&1 &
    echo "✓ rclone serve s3 running natively (pid $!, log: $DATADIR/rclone.log)."
  fi

  LANIP="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo 127.0.0.1)"
  cat <<EOF

═══════════════════════════════════════════════════════════════
✓ Your Haven bucket is live (rclone serve s3 — MIT, fully open source).

Paste these into Haven → You → Advanced → Storage → Custom S3 bucket,
then turn on "Volunteer as tribute":

   Endpoint:    $LANIP:$PORT
   Region:      us-east-1
   Bucket:      $BUCKET
   Access key:  $AKEY
   Secret key:  $SKEY

• For your circle to reach it from anywhere, expose the port (router
  port-forward, Tailscale, or a small VPS). Everything stored is sealed.
• Tip: the haven-relay binary needs NONE of this — no ports, no public host.
  Re-run without --bucket to use it instead.
═══════════════════════════════════════════════════════════════
EOF
}

case "$MODE" in
  relay)  install_relay ;;
  bucket) start_bucket ;;
esac
