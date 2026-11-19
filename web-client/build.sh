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
cp "$here/web-host.js" "$here/storage.js" "$here/responsive.css" "$dist/"
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
