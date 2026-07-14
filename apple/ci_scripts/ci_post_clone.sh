#!/bin/bash
# Xcode Cloud post-clone. Runs after the clone, BEFORE dependency resolution and xcodebuild.
#
# Why this file has to exist at all: three build inputs are deliberately gitignored, so a fresh
# clone cannot build without regenerating them —
#   apple/*.xcodeproj    (.gitignore:14) — XcodeGen's output; committing it re-invites the
#                                          duplicate-project mess ("Haven 2.xcodeproj" …)
#   apple/Generated/     (.gitignore:13) — UniFFI's Swift bindings
#   *.xcframework        (.gitignore:25) — HavenFFI.xcframework, the compiled Rust core
# Without this script Xcode Cloud fails at "Resolve package dependencies" with
# "'…/apple/Haven.xcodeproj' does not exist". Fixing only the project would just move the
# failure down to the missing bindings, then the missing xcframework.
#
# Why it caches: the xcframework is a full Rust core compile across every Apple arch. Xcode Cloud
# bills compute minutes, so rebuilding it per run burns the free monthly allowance on bytes that
# are identical whenever core/ hasn't changed. Same approach as Enter Space's ci_post_clone.sh:
# key a GitHub Release off the source, restore on hit, build+publish on miss.
#
# Set GITHUB_TOKEN (repo scope) as a secret env var on the Xcode Cloud workflow to enable the
# cache. WITHOUT it this still works — it just builds every time.

set -euo pipefail

echo "=== Haven ci_post_clone: start ==="

REPO_DIR="${CI_PRIMARY_REPOSITORY_PATH:-/Volumes/workspace/repository}"
APPLE_DIR="$REPO_DIR/apple"
CACHE_REPO="blaineam/haven"
XCFW="$APPLE_DIR/HavenFFI.xcframework"

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

# ---------------------------------------------------------------------------
# Cache key: what the xcframework's CONTENT actually depends on.
# core/ is the Rust source; the build script decides targets/flags. Nothing else can change the
# binary, so anything else changing must NOT invalidate the cache.
# `git rev-parse HEAD:core` is the tree hash — it moves only when core/ moves, unlike the commit
# SHA which changes on every unrelated push.
# ---------------------------------------------------------------------------
# Fail SOFT: a cache key we can't compute must degrade to "build it", never kill the build.
# `set -e` would otherwise abort the whole script on a git hiccup (no .git, shallow clone oddity,
# git missing) — turning a cache miss into a red build. Caught by running this against a
# non-git working copy, where `rev-parse` failed and took the script down with it.
CORE_TREE=$(git -C "$REPO_DIR" rev-parse HEAD:core 2>/dev/null || true)
if [ -z "$CORE_TREE" ]; then
  # No git tree hash available — hash the core sources directly. Same property (changes iff core
  # changes), just slower. `find | sort` keeps it stable across filesystems.
  CORE_TREE=$(find "$REPO_DIR/core" -type f \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' -o -name '*.udl' \) \
    2>/dev/null | sort | xargs shasum 2>/dev/null | shasum | awk '{print $1}' || echo "")
  [ -n "$CORE_TREE" ] && echo "note: no git tree hash — keyed on hashed core/ sources instead"
fi
BUILD_HASH=$(shasum "$APPLE_DIR/build-rust-xcframework.sh" 2>/dev/null | awk '{print $1}' | cut -c1-8 || echo "")

if [ -n "$CORE_TREE" ] && [ -n "$BUILD_HASH" ]; then
  CACHE_TAG="xcfw-${CORE_TREE}-${BUILD_HASH}"
  echo "Cache key: $CACHE_TAG (core@${CORE_TREE:0:8}, script@${BUILD_HASH})"
else
  CACHE_TAG=""
  echo "⚠️  could not compute a cache key — building without cache (not fatal)"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/haven-cache.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
TARBALL="$TMP/havenffi.tar.gz"
CACHE_HIT=0

# ---------------------------------------------------------------------------
# 1. Restore
# ---------------------------------------------------------------------------
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "$CACHE_TAG" ]; then
  echo "--- checking cache ($CACHE_TAG) ---"
  RELEASE_JSON=$(curl -fsL \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$CACHE_REPO/releases/tags/$CACHE_TAG" 2>/dev/null || echo "")

  if [ -n "$RELEASE_JSON" ]; then
    # The API asset URL + Accept: application/octet-stream — NOT browser_download_url, which
    # 404s for a private repo under Bearer auth. "url" precedes "name" in each asset block.
    ASSET_URL=$(echo "$RELEASE_JSON" | awk '
      /"url": "https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\/[0-9]*"/ {
        match($0, /https:\/\/api\.github\.com[^"]*/); url = substr($0, RSTART, RLENGTH)
      }
      /"name": "havenffi\.tar\.gz"/ { print url; exit }')

    if [ -n "$ASSET_URL" ]; then
      echo "✅ cache hit — downloading"
      curl -fL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/octet-stream" \
        "$ASSET_URL" -o "$TARBALL"
      # Tarred from apple/, so it restores HavenFFI.xcframework AND Generated/ together — the
      # bindings and the binary are one unit; a mismatched pair would fail to link, confusingly.
      tar -xzf "$TARBALL" -C "$APPLE_DIR"
      CACHE_HIT=1
      echo "✅ restored from cache"
    else
      echo "cache release exists but asset missing — rebuilding"
    fi
  else
    echo "no cache entry — building"
  fi
else
  echo "⚠️  no GITHUB_TOKEN — cache disabled, building every run"
fi

# ---------------------------------------------------------------------------
# 2. Build on miss
# ---------------------------------------------------------------------------
if [ "$CACHE_HIT" -eq 0 ]; then
  echo "--- building HavenFFI.xcframework (Rust) ---"
  if ! command -v rustup >/dev/null 2>&1; then
    echo "installing rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  fi
  export PATH="$HOME/.cargo/bin:$PATH"
  # build-rust-xcframework.sh adds the Apple targets itself and drives cargo via $CARGO, so it
  # doesn't depend on the runner's default toolchain.
  bash "$APPLE_DIR/build-rust-xcframework.sh"

  # Publishing the cache is a PURE OPTIMISATION — the xcframework is already built and on disk by
  # this point. Nothing in here may fail the build. It lives in a function called with `|| true`
  # because `set -euo pipefail` makes that easy to get wrong: a `grep -o` that simply finds no
  # match exits 1, pipefail propagates it, and `set -e` then kills the whole script — throwing
  # away a successful 9-minute build over a missed cache upload. That is exactly what happened.
  publish_cache() {
    set +e            # local to this function; the rest of the script keeps strict mode
    echo "--- publishing cache ($CACHE_TAG) ---"
    local create upload_base http
    create=$(curl -sS -X POST \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$CACHE_REPO/releases" \
      -d "{\"tag_name\":\"$CACHE_TAG\",\"name\":\"$CACHE_TAG\",\"body\":\"Cached HavenFFI.xcframework + Swift bindings for core@${CORE_TREE:0:8}. Build artifact — safe to delete.\",\"draft\":false,\"prerelease\":true}" 2>/dev/null)
    upload_base=$(printf '%s' "$create" | grep -o '"upload_url":[[:space:]]*"https://[^{]*' | grep -o 'https://[^"]*' | head -1)

    # A release for this tag may already exist (a concurrent or retried run) — reuse it.
    if [ -z "$upload_base" ]; then
      create=$(curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$CACHE_REPO/releases/tags/$CACHE_TAG" 2>/dev/null)
      upload_base=$(printf '%s' "$create" | grep -o '"upload_url":[[:space:]]*"https://[^{]*' | grep -o 'https://[^"]*' | head -1)
    fi

    if [ -z "$upload_base" ]; then
      echo "⚠️  no upload URL — cache not published (non-fatal)"
      return 0
    fi
    tar -czf "$TARBALL" -C "$APPLE_DIR" HavenFFI.xcframework Generated 2>/dev/null || {
      echo "⚠️  tar failed — cache not published (non-fatal)"; return 0; }
    http=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Content-Type: application/gzip" \
      --data-binary @"$TARBALL" \
      "${upload_base}?name=havenffi.tar.gz" 2>/dev/null)
    case "$http" in
      2*) echo "✅ cache published (HTTP $http) — later runs restore instead of rebuilding" ;;
      *)  echo "⚠️  cache upload returned HTTP $http — not published (non-fatal)" ;;
    esac
    return 0
  }

  if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "$CACHE_TAG" ] && [ -d "$XCFW" ]; then
    publish_cache || true
  fi
fi

# ---------------------------------------------------------------------------
# 3. Generate the Xcode project — MUST come after the xcframework exists, since project.yml
#    references it as a target dependency.
# ---------------------------------------------------------------------------
echo "--- xcodegen ---"
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
cd "$APPLE_DIR"
xcodegen generate

# ---------------------------------------------------------------------------
# 4. Package.resolved — Xcode Cloud disables automatic dependency resolution and demands a
#    committed resolved file at:
#      apple/Haven.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
#    …which lives INSIDE the gitignored .xcodeproj, so it can never be committed there — git
#    cannot un-ignore a file inside an ignored directory. (The build error's advice, "check that
#    Package.resolved is committed", is impossible as written for a generated project.)
#    So the pinned versions are committed at apple/Package.resolved and copied into the freshly
#    generated project here. Update that file whenever an SPM dependency changes:
#      cp apple/Haven.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved apple/Package.resolved
# ---------------------------------------------------------------------------
SPM_DIR="$APPLE_DIR/Haven.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
if [ -f "$APPLE_DIR/Package.resolved" ]; then
  mkdir -p "$SPM_DIR"
  cp "$APPLE_DIR/Package.resolved" "$SPM_DIR/Package.resolved"
  echo "  Package.resolved → $(basename "$SPM_DIR")/ ✅"
else
  echo "⚠️  apple/Package.resolved missing — Xcode Cloud will fail to resolve packages"
fi

echo "=== ci_post_clone: done ==="
ls -d "$XCFW" >/dev/null 2>&1 && echo "  HavenFFI.xcframework ✅" || { echo "  HavenFFI.xcframework MISSING ❌"; exit 1; }
ls -d "$APPLE_DIR/Generated" >/dev/null 2>&1 && echo "  Generated/ ✅" || { echo "  Generated/ MISSING ❌"; exit 1; }
ls -d "$APPLE_DIR/Haven.xcodeproj" >/dev/null 2>&1 && echo "  Haven.xcodeproj ✅" || { echo "  Haven.xcodeproj MISSING ❌"; exit 1; }
