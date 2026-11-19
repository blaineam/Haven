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
