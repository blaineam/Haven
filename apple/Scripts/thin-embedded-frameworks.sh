#!/bin/sh
#
# thin-embedded-frameworks.sh
#
# Post-build script phase of the HavenMac target (wired via `postBuildScripts`
# in apple/project.yml — the xcodegen project is regenerated, never edited —
# so it runs after "Embed Frameworks" and every other embed step). Removes
# every architecture the app itself is not built for from the frameworks and
# dylibs embedded in the bundle, then re-signs what it touched. Ported
# verbatim from Enter Space's Scripts/thin-embedded-frameworks.sh.
#
# WHY
# ---
# The Mac app links arm64-only (ARCHS[sdk=macosx*] = arm64 at the project
# level: Apple's 2026-09 notice lets Mac App Store apps that require macOS
# 13+ drop Intel, and macOS 27 is Apple-silicon-only). Xcode thins what it
# links, but a binary framework copied out of an .xcframework is copied
# whole: the macos-arm64_x86_64 slice of the upstream WebRTC.xcframework
# (WebRTC.framework, fat) still carried both architectures, so half of those
# bytes were dead weight in every download — exactly the size Apple's notice
# is about. App Store Connect thins iOS apps per device; it does not thin
# macOS frameworks.
#
# WHAT IT DOES
# ------------
#   * macOS only (PLATFORM_NAME == macosx). iOS, watchOS and tvOS legs of the
#     same target are untouched.
#   * For every *.framework and *.dylib in $TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH
#     it reads `lipo -archs` and, when a slice is not in $ARCHS, removes it
#     with `lipo -remove`. Already-thin binaries are skipped silently, so the
#     phase is idempotent and quiet on a clean bundle.
#   * Re-signs each thinned framework in place with the build's identity
#     (EXPANDED_CODE_SIGN_IDENTITY) when signing is allowed — the signature
#     "Embed Frameworks" applied covered the fat binary and no longer
#     verifies. With CODE_SIGNING_ALLOWED=NO nothing is signed.
#   * Any lipo or codesign failure fails the build: a half-thinned framework
#     must never reach a product.
#
# The phase runs with "Based on dependency analysis" off (alwaysOutOfDate = 1)
# like the existing "Strip Extended Attributes" phase: it inspects the bundle
# on every build and costs nothing when there is nothing to do.

set -eu

log()  { printf '%s\n' "thin-embedded-frameworks: $*"; }
fail() { printf '%s\n' "error: thin-embedded-frameworks: $*" >&2; exit 1; }

if [ "${PLATFORM_NAME:-}" != "macosx" ]; then
    exit 0
fi

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${FRAMEWORKS_FOLDER_PATH:-}" ]; then
    exit 0
fi
FRAMEWORKS_DIR="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
[ -d "$FRAMEWORKS_DIR" ] || exit 0

[ -n "${ARCHS:-}" ] || fail "ARCHS is empty; cannot tell which slices to keep"

want_arch() {
    for keep in $ARCHS; do
        [ "$1" = "$keep" ] && return 0
    done
    return 1
}

# Re-signs $1 (a framework bundle or a dylib) with the build's identity when
# the build is signing at all. EXPANDED_CODE_SIGN_IDENTITY is the identity's
# SHA-1, or "-" for ad-hoc; both are valid for `codesign --sign`.
resign() {
    if [ "${CODE_SIGNING_ALLOWED:-NO}" != "YES" ] || [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        log "code signing is off; $(basename "$1") left unsigned"
        return 0
    fi
    log "re-signing $(basename "$1") with ${EXPANDED_CODE_SIGN_IDENTITY_NAME:-$EXPANDED_CODE_SIGN_IDENTITY}"
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
        --preserve-metadata=identifier,entitlements,flags --timestamp=none "$1" \
        || fail "codesign failed for $1"
}

# Thins the Mach-O at $1 in place, then re-signs $2 (the bundle it belongs to).
thin() {
    binary="$1"
    signable="$2"
    archs="$(/usr/bin/lipo -archs "$binary")" || fail "lipo -archs failed for $binary"
    remove=""
    kept=0
    for arch in $archs; do
        if want_arch "$arch"; then
            kept=$((kept + 1))
        else
            remove="$remove -remove $arch"
        fi
    done
    if [ -z "$remove" ]; then
        return 0    # already thin: the common case, stay quiet
    fi
    [ "$kept" -gt 0 ] || fail "$binary has [$archs] but ARCHS=[$ARCHS] would keep none of them"
    mode="$(stat -f '%OLp' "$binary")"
    tmp="$binary.thin.$$"
    # shellcheck disable=SC2086  # $remove is a deliberate word list
    if ! /usr/bin/lipo "$binary" $remove -output "$tmp"; then
        rm -f "$tmp"
        fail "lipo -remove failed for $binary"
    fi
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$binary"
    log "$(basename "$signable"): [$archs] -> [$(/usr/bin/lipo -archs "$binary")]"
    resign "$signable"
}

# The executable of a framework is named by CFBundleExecutable. Resolve it
# through Versions/Current on macOS-style bundles so the real file is edited,
# not the top-level symlink.
for fw in "$FRAMEWORKS_DIR"/*.framework; do
    [ -d "$fw" ] || continue
    name="$(basename "$fw" .framework)"
    if [ -d "$fw/Versions/Current" ]; then
        root="$fw/Versions/Current"
        plist="$root/Resources/Info.plist"
    else
        root="$fw"
        plist="$fw/Info.plist"
    fi
    if [ -f "$plist" ]; then
        exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
        [ -n "$exe" ] && name="$exe"
    fi
    binary="$root/$name"
    if [ ! -f "$binary" ]; then
        log "skipping $(basename "$fw"): no executable at $binary"
        continue
    fi
    thin "$binary" "$fw"
done

for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    thin "$dylib" "$dylib"
done
