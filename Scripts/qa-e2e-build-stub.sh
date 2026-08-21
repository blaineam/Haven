#!/usr/bin/env bash
# Build the isolated HavenStub.app the QA fleets use as relay host + friend account.
# Same HavenMac sources, different product/bundle id (FeedView gates QA-stub behavior
# on the bundle id containing "qa.stub") + the stub entitlements (no app groups /
# iCloud so it can never touch the personal account's data).
#
# Output: /tmp/matrix-haven-mac-stub/Build/Products/Debug/HavenStub.app
# (the path every qa-* script expects; override with MATRIX_DD).
#
# NOTE: signed with the team identity — an unsigned/adhoc build has no keychain
# entitlement, the seed never persists, and the social engine never comes up
# (same trap as the iOS UI tests).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="${MATRIX_DD:-/tmp/matrix-haven-mac-stub}"
LOG="${DD}-build.log"

cd "$ROOT/apple"
xcodegen generate >/dev/null

# NOTE: PRODUCT_NAME is deliberately NOT overridden here.
#
# A command-line build setting applies to EVERY target in the graph, not just the app — so
# `PRODUCT_NAME=HavenStub` also renamed MillerKit's SwiftPM resource bundle, which is then copied
# by its real name. The build died on:
#
#   error: The file "MillerKit_MillerKit.bundle" couldn't be opened because there is no such file
#
# with a `HavenStub.bundle` sitting next to it. That broke the ENTIRE cross-device suite at
# bootstrap — no assertion in it had run since. Build under the real product name and rename
# afterwards instead.
xcodebuild \
  -project Haven.xcodeproj \
  -scheme HavenMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DD" \
  PRODUCT_BUNDLE_IDENTIFIER=com.blaineam.kith.qa.stub \
  CODE_SIGN_ENTITLEMENTS="HavenApp/Haven.macOS.stub.entitlements" \
  DEVELOPMENT_TEAM=8ZVSPZYSVF \
  build >"$LOG" 2>&1 || { echo "stub build FAILED — tail of $LOG:"; tail -30 "$LOG"; exit 1; }

grep -q "BUILD SUCCEEDED" "$LOG" || { echo "no BUILD SUCCEEDED in $LOG"; exit 1; }

# Rename the .app DIRECTORY only — do not touch anything inside it.
#
# A code signature seals `Contents/`, not the name of the enclosing folder, so renaming the bundle
# directory keeps Xcode's own signature (and its embedded provisioning profile) completely intact.
# Renaming the executable and patching CFBundleExecutable does NOT: it invalidates the seal, and
# every attempt to repair it by re-signing — ad-hoc or with the real Apple Development identity —
# produced a binary that amfid killed at exec (`Killed: 9`, exit 137), which reads as a crash rather
# than a signing problem. Leave the signed payload alone.
#
# The executable therefore stays `Haven`, so the stub cannot be matched with `pkill -x HavenStub`.
# It is matched by PATH instead (see qa-e2e-stub.sh), which is strictly safer anyway: it can never
# hit the real Haven.app the way a bare process-name match could.
BUILT="$DD/Build/Products/Debug/Haven.app"
APP="$DD/Build/Products/Debug/HavenStub.app"
if [[ -d "$BUILT" ]]; then
  rm -rf "$APP"
  mv "$BUILT" "$APP"
  codesign -v "$APP" >>"$LOG" 2>&1 || { echo "stub signature broke on rename — see $LOG"; exit 1; }
fi
[[ -d "$APP" ]] || { echo "missing $APP after build"; exit 1; }
echo "stub built → $APP"
