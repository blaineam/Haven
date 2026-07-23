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

xcodebuild \
  -project Haven.xcodeproj \
  -scheme HavenMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DD" \
  PRODUCT_NAME=HavenStub \
  PRODUCT_BUNDLE_IDENTIFIER=com.blaineam.kith.qa.stub \
  CODE_SIGN_ENTITLEMENTS="HavenApp/Haven.macOS.stub.entitlements" \
  DEVELOPMENT_TEAM=8ZVSPZYSVF \
  build >"$LOG" 2>&1 || { echo "stub build FAILED — tail of $LOG:"; tail -30 "$LOG"; exit 1; }

grep -q "BUILD SUCCEEDED" "$LOG" || { echo "no BUILD SUCCEEDED in $LOG"; exit 1; }
APP="$DD/Build/Products/Debug/HavenStub.app"
[[ -d "$APP" ]] || { echo "missing $APP after build"; exit 1; }
echo "stub built → $APP"
