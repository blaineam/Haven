#!/bin/bash
# Xcode Cloud looks for ci_scripts in the same directory as the .xcodeproj — for Haven that's
# apple/. It is ambiguous whether the repo ROOT is also searched (Apple's docs say project dir;
# most examples have project==root so the two coincide and never disambiguate). A root-level run
# failed with "Post-Clone script not found at ci_scripts/ci_post_clone.sh" while the file WAS at
# the root — i.e. that path is project-relative. This shim covers the root location anyway so the
# build can't fail on that guess again. The real script is location-independent (it derives
# everything from CI_PRIMARY_REPOSITORY_PATH).
set -euo pipefail
exec "${CI_PRIMARY_REPOSITORY_PATH:-/Volumes/workspace/repository}/apple/ci_scripts/ci_post_clone.sh" "$@"
