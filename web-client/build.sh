#!/bin/sh
# Build the browser client core: core/haven-web → web-client/pkg (wasm + JS glue).
#
#   web-client/build.sh            # release build
#
# Needs: rustup's toolchain with the wasm32-unknown-unknown target, a clang that can target
# wasm32 (ring's C; Apple's clang cannot — Homebrew `llvm` can), and wasm-bindgen-cli at the
# exact version core/Cargo.lock pins (the CLI and the crate must match).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
core="$here/../core"

# Homebrew's `cargo` shadows rustup's and has no wasm32 std; prefer rustup's when present.
[ -x "$HOME/.cargo/bin/cargo" ] && PATH="$HOME/.cargo/bin:$PATH"

if [ -z "${CC_wasm32_unknown_unknown:-}" ]; then
  for llvm in /opt/homebrew/opt/llvm /usr/local/opt/llvm; do
    if [ -x "$llvm/bin/clang" ]; then
      export CC_wasm32_unknown_unknown="$llvm/bin/clang" AR_wasm32_unknown_unknown="$llvm/bin/llvm-ar"
      break
    fi
  done
fi

want=$(awk '/^name = "wasm-bindgen"$/ { getline; gsub(/version = |"/, ""); print; exit }' "$core/Cargo.lock")
bindgen=${WASM_BINDGEN:-wasm-bindgen}
have=$("$bindgen" --version 2>/dev/null | awk '{print $2}') || have=
if [ "$have" != "$want" ]; then
  echo "wasm-bindgen-cli $want required (found '${have:-none}'):" >&2
  echo "  cargo install wasm-bindgen-cli --version $want --locked" >&2
  exit 1
fi

target=${CARGO_TARGET_DIR:-$core/target}
(cd "$core" && CARGO_TARGET_DIR="$target" cargo build -p haven-web --target wasm32-unknown-unknown --release --locked)
rm -rf "$here/pkg"
"$bindgen" --target web --out-dir "$here/pkg" "$target/wasm32-unknown-unknown/release/haven_web.wasm"

# Shrink the module with Binaryen's wasm-opt when it is installed (the release archive is built
# with it; a local build without it is the same program, larger). -Oz because the module is paid
# for on every first visit over a home connection. The feature flags name what rustc emits for
# wasm32-unknown-unknown; without them wasm-opt rejects the module it is asked to shrink.
# HAVEN_REQUIRE_WASM_OPT=1 (CI) makes a missing or failing wasm-opt an error instead of a note.
wasm="$here/pkg/haven_web_bg.wasm"
before=$(wc -c < "$wasm" | tr -d ' ')
if command -v wasm-opt >/dev/null 2>&1; then
  if wasm-opt -Oz --enable-bulk-memory --enable-sign-ext --enable-mutable-globals \
       --enable-nontrapping-float-to-int --enable-reference-types --enable-multivalue \
       -o "$wasm.opt" "$wasm"; then
    mv "$wasm.opt" "$wasm"
    echo "wasm-opt: $before -> $(wc -c < "$wasm" | tr -d ' ') bytes"
  else
    rm -f "$wasm.opt"
    [ "${HAVEN_REQUIRE_WASM_OPT:-}" = 1 ] && { echo "wasm-opt failed" >&2; exit 1; }
    echo "wasm-opt failed: shipping the unoptimized module ($before bytes)" >&2
  fi
else
  [ "${HAVEN_REQUIRE_WASM_OPT:-}" = 1 ] && { echo "wasm-opt (binaryen) is required but not installed" >&2; exit 1; }
  echo "wasm-opt not installed: module left unoptimized ($before bytes)"
fi
echo "built $here/pkg"

# ── dist/: the bundle a relay serves under /app/ ─────────────────────────────────────────────
# The UI is the desktop frontend (desktop/ui), unchanged, with a host shim in place of Tauri.
ui="$here/../desktop/ui"
dist="$here/dist"
rm -rf "$dist"
mkdir -p "$dist/pkg" "$dist/vendor" "$dist/palette-icons"
cp "$ui/app.js" "$ui/strings.js" "$ui/styles.css" "$ui/imgworker.js" "$dist/"
cp "$ui"/vendor/* "$dist/vendor/"
cp "$ui"/palette-icons/* "$dist/palette-icons/"
cp "$here/web-host.js" "$here/storage.js" "$here/sw.js" "$here/responsive.css" "$dist/"
cp "$here/pkg/haven_web.js" "$here/pkg/haven_web_bg.wasm" "$dist/pkg/"
# index.html: the desktop page with the host shim loaded first and the responsive layer last.
awk '
  /<script src="strings.js"/ && !done_host { print "    <script src=\"web-host.js\"></script>"; done_host = 1 }
  /<\/head>/ && !done_css { print "    <link rel=\"stylesheet\" href=\"responsive.css\" />"; done_css = 1 }
  { print }
' "$ui/index.html" > "$dist/index.html"
grep -q 'web-host.js' "$dist/index.html" || { echo "index.html: host shim not injected" >&2; exit 1; }
grep -q 'responsive.css' "$dist/index.html" || { echo "index.html: responsive layer not injected" >&2; exit 1; }
echo "built $dist ($(find "$dist" -type f | wc -l | tr -d ' ') files)"

# ── dist-site/: the same files, for an ordinary web site ─────────────────────────────────────
# A static host (a project page, any file server) can serve the client too. Such a page is not a
# relay's: web-host.js reads the marker below, starts with no relay, and links through a
# rendezvous relay. A static host usually cannot set response headers, so the content policy the
# relay sends as a header (core/haven-net/src/webbundle.rs) rides in the page instead; the one
# directive a page cannot carry, frame-ancestors, is the host's to send if it can.
#   HAVEN_SITE_RENDEZVOUS="https://relay.example"   optional, comma-separated: relays the site
#       names as the meeting point for linking, instead of the public ones the apps fall back to.
site="$here/dist-site"
rm -rf "$site"
cp -R "$dist" "$site"
csp="default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; media-src 'self' blob:; font-src 'self'; connect-src 'self' https: wss:; worker-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'"
HAVEN_CSP="$csp" HAVEN_RDV="${HAVEN_SITE_RENDEZVOUS:-}" awk '
  /<meta name="viewport"/ && !done {
    print
    print "    <meta http-equiv=\"Content-Security-Policy\" content=\"" ENVIRON["HAVEN_CSP"] "\" />"
    print "    <meta name=\"referrer\" content=\"no-referrer\" />"
    print "    <meta name=\"haven-host\" content=\"site\" />"
    if (ENVIRON["HAVEN_RDV"] != "") print "    <meta name=\"haven-rendezvous\" content=\"" ENVIRON["HAVEN_RDV"] "\" />"
    done = 1; next
  }
  { print }
' "$dist/index.html" > "$site/index.html"
grep -q 'name="haven-host" content="site"' "$site/index.html" || { echo "dist-site/index.html: site marker not injected" >&2; exit 1; }
echo "built $site"
