#!/usr/bin/env bash
# Write the QA authorize-members list to every path the HavenStub may read.
# Usage: qa-e2e-authorize.sh <members-file>   (one 64-hex id per line)
set -euo pipefail
FILE="${1:?usage: qa-e2e-authorize.sh <members-file>}"
content="$(cat "$FILE")"
paths=(
  "$HOME/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/qa-authorize-members.txt"
  "$HOME/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/HavenStub/qa-authorize-members.txt"
  "$HOME/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/com.blaineam.kith.qa.stub/qa-authorize-members.txt"
  "/tmp/haven-mac-stub-home/Library/Application Support/qa-authorize-members.txt"
  "/tmp/haven-mac-stub-home/Library/Application Support/HavenStub/qa-authorize-members.txt"
)
for p in "${paths[@]}"; do
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$content" >"$p"
done
echo "[authorize] $(grep -c . "$FILE" || true) member hexes → ${#paths[@]} stub paths"
