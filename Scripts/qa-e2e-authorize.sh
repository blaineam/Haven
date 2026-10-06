#!/usr/bin/env bash
# Write the QA authorize-members list where the HavenStub reads it: the shared QA directory
# (~/Library/Application Support/HavenQA/stub/ — see apple/HavenApp/QaFiles.swift). Never the stub's
# sandbox container: macOS App Data protection forbids touching another app's container.
# Usage: qa-e2e-authorize.sh <members-file>   (one 64-hex id per line)
set -euo pipefail
FILE="${1:?usage: qa-e2e-authorize.sh <members-file>}"
DIR="$HOME/Library/Application Support/HavenQA/stub"
mkdir -p "$DIR"
printf '%s\n' "$(cat "$FILE")" >"$DIR/qa-authorize-members.txt"
echo "[authorize] $(grep -c . "$FILE" || true) member hexes → $DIR/qa-authorize-members.txt"
