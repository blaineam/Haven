# Build caches under /tmp, shared by the QA scripts.
#
# macOS's periodic /tmp cleanup deletes FILES that have not been read for a few days and leaves the
# folders. A Swift package checkout then looks present to xcodebuild, which does not fetch it again
# and fails with "Could not resolve package dependencies: the package manifest ... cannot be
# accessed". That stopped the whole cross-device suite before its first step (2026-11-24).

# haven_dd_prune <derivedData>: remove a cache whose package checkouts have lost their manifests.
# It is build output only; the next build makes it again.
haven_dd_prune() {
  local dd="$1" checkout
  [[ "$dd" == /tmp/* && -d "$dd/SourcePackages/checkouts" ]] || return 0
  while IFS= read -r checkout; do
    if [[ ! -f "$checkout/Package.swift" ]]; then
      echo "[haven-dd] $dd is missing $(basename "$checkout")/Package.swift (cleared from /tmp); rebuilding from scratch"
      rm -rf "$dd"
      return 0
    fi
  done < <(find "$dd/SourcePackages/checkouts" -mindepth 1 -maxdepth 1 -type d)
}
