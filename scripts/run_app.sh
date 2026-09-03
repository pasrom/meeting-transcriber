#!/usr/bin/env bash
# Launch the Meeting Transcriber menu bar app.
# Builds an .app bundle so macOS APIs (notifications, etc.) work correctly.
#
# --build-only: Build the bundle but skip `open -W`. Used by the Pattern-C
#   E2E driver (scripts/e2e-app.sh) which deploys the bundle to a stable
#   path and launches it itself; opening the in-tree bundle there would
#   confuse macOS LaunchServices about which one to use for TCC.

set -euo pipefail

BUILD_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSCRIBER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export TRANSCRIBER_ROOT

SPM_DIR="$TRANSCRIBER_ROOT/app/MeetingTranscriber"
BUILD_BINARY="$SPM_DIR/.build/release/MeetingTranscriber"
APP_BUNDLE="$SPM_DIR/.build/MeetingTranscriber-Dev.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/MeetingTranscriber"
INFO_PLIST="$SPM_DIR/Sources/Info.plist"
# shellcheck source=lib/bundle-ids.sh
source "$SCRIPT_DIR/lib/bundle-ids.sh"

# Always rebuild to pick up code changes
echo "Building Meeting Transcriber app..."
cd "$SPM_DIR"
SWIFT_BUILD_FLAGS=(-c release)
# Opt-in fault-injection build for the mic-device-change e2e lane only
# (scripts/e2e-app.sh --mic-device-change). Compiles the issue #379
# reproduction seam in MicCaptureHandler; never set for normal/release builds.
if [ -n "${MTT_FAULT_INJECTION:-}" ]; then
    SWIFT_BUILD_FLAGS+=(-Xswiftc -DE2E_FAULT_INJECTION)
    echo "  (fault-injection build: -DE2E_FAULT_INJECTION)"
fi
swift build "${SWIFT_BUILD_FLAGS[@]}"

# Which certificate the previous build signed this bundle with, read BEFORE the
# bundle is touched. It lives in the main executable's embedded signature, and
# the `cp "$BUILD_BINARY"` below replaces that executable with a freshly linked,
# ad-hoc signed one, after which there is no certificate left to read. Measured:
# intact bundle yields the hash, the same bundle after the copy yields nothing,
# so a read placed after the copy is dead code that silently always falls
# through. Used by the identity choice further down.
# shellcheck source=lib/signing.sh
source "$SCRIPT_DIR/lib/signing.sh"
PREV_SIGNING_CERT=""
if [ -d "$APP_BUNDLE" ]; then
    PREV_SIGNING_CERT="$(bundle_signing_cert_sha1 "$APP_BUNDLE" 2>/dev/null || true)"
fi

# Assemble .app bundle
mkdir -p "$APP_MACOS"
# Use the dev bundle identifier to keep permissions separate from release.
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEV_BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"

# Inject version from VERSION file
APP_VERSION=$(cat "$TRANSCRIBER_ROOT/VERSION" | tr -d '[:space:]')
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Inject git commit hash into Info.plist
GIT_HASH=$(git -C "$TRANSCRIBER_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
/usr/libexec/PlistBuddy -c "Add :GitCommitHash string $GIT_HASH" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :GitCommitHash $GIT_HASH" "$APP_BUNDLE/Contents/Info.plist"

cp "$BUILD_BINARY" "$APP_BINARY"

# Licences for the third-party code and weights this bundle redistributes. The
# dev app is not distributed, but scripts/e2e-app.sh deploys it, so keeping it
# identical to a release bundle is what makes an e2e run evidence about the
# thing users get. Fatal here, unlike the model below: a missing licence file in
# the repo is a repo bug, not an unreachable download.
# shellcheck source=lib/bundle-licenses.sh
source "$SCRIPT_DIR/lib/bundle-licenses.sh"
install_third_party_licenses "$APP_BUNDLE/Contents/Resources"

# LocalVQE echo-cancellation model, the same resources build_release.sh bundles,
# so the dev app (which scripts/e2e-app.sh deploys) can exercise the feature.
# Non-fatal here and fatal there: an unreachable download must not stop someone
# running the dev app for unrelated work. Stderr is deliberately not silenced —
# that is where a checksum mismatch reports itself, and "model unavailable"
# alone would hide a poisoned cache.
# shellcheck source=lib/localvqe-resources.sh
source "$SCRIPT_DIR/lib/localvqe-resources.sh"
if ! install_localvqe_resources "$APP_BUNDLE/Contents/Resources"; then
    echo "  WARNING: LocalVQE model unavailable; echo cancellation will find no model."
fi

# Code-sign so macOS keeps its permission grants across rebuilds.
# Uses SHA-1 hash to avoid "ambiguous identity" errors with duplicate names.
#
# Signing happens WITH the Homebrew entitlements, the same set build_release.sh
# uses: without them the dev build carries no entitlements at all, so anything
# gated on one behaves differently here than in a release build, notably the
# time-sensitive consent prompt (issue #543).
#
# Prefer Developer ID, do not take whatever the keychain lists first. TCC binds
# a grant to the signing certificate's leaf SHA-1, so the identity chosen here
# decides whether the dev app keeps its microphone and screen-recording grants
# or silently loses all of them. `head -1` made that depend on keychain
# ordering, and it changed under us the day an Apple Development certificate
# was added: the rebuilt app then records nothing, with no error anywhere and
# no prompt, because from TCC's point of view it is a different application.
# The same preference is applied in lib/signing.sh for the profile case.
#
# Ahead of even that: if the deployed bundle is already signed with a
# certificate that is still in the keychain, keep it. Two valid Developer ID
# Application certificates (the overlap around a renewal) would otherwise put
# us back to "whichever is listed first", and switching between them voids the
# grants just as thoroughly as switching issuer would.
_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
_DEVID="$(grep "Developer ID Application" <<<"$_IDENTITIES" | head -1 | awk '{print $2}')" || true

SIGN_HASH=""
SIGN_REASON=""
# Keep the certificate the previous build used, but only while it is still in
# the keychain AND it is either a Developer ID one or there is no Developer ID
# to move to. The second half matters: a bundle left over from before this fix
# is signed with Apple Development, and "keep what is there" alone would pin it
# to the wrong certificate forever, with the only escape being to delete the
# bundle by hand. With the check, such a bundle moves to Developer ID by itself
# and the renewal case still keeps the certificate actually in use.
if [ -n "$PREV_SIGNING_CERT" ] && grep -q "$PREV_SIGNING_CERT" <<<"$_IDENTITIES"; then
    if [ -z "$_DEVID" ] || [ "$PREV_SIGNING_CERT" = "$_DEVID" ] \
        || grep "$PREV_SIGNING_CERT" <<<"$_IDENTITIES" | grep -q "Developer ID Application"; then
        SIGN_HASH="$PREV_SIGNING_CERT"
        SIGN_REASON="kept the certificate this bundle already carried"
    fi
fi
if [ -z "$SIGN_HASH" ] && [ -n "$_DEVID" ]; then
    SIGN_HASH="$_DEVID"
    SIGN_REASON="chose the Developer ID Application certificate"
fi
if [ -z "$SIGN_HASH" ]; then
    SIGN_HASH=$(head -1 <<<"$_IDENTITIES" | awk '{print $2}') || true
    if [ -n "$SIGN_HASH" ]; then
        SIGN_REASON="no Developer ID Application certificate exists, took the first identity"
        echo "  NOTE: TCC grants made against a different certificate will not apply to this build."
    fi
fi
# Say which rule chose and which certificate it is. Without this the build log
# shows only a hash, and the whole reason this block exists is that the wrong
# certificate is invisible until the app silently records nothing.
if [ -n "$SIGN_HASH" ]; then
    echo "  Signing identity: $SIGN_REASON"
    grep "$SIGN_HASH" <<<"$_IDENTITIES" | sed 's/^ */    /'
fi
# $DEV_ENTITLEMENTS is that same path, named once in the library so this build
# and any later re-sign of the deployed bundle cannot drift apart (issue #609).
prepare_signing "$APP_BUNDLE" "$DEV_ENTITLEMENTS" "$DEV_BUNDLE_ID" "$SIGN_HASH"
if [ -n "$SIGNING_IDENTITY" ]; then
    # Failure is fatal and its stderr is kept. This used to be `2>/dev/null && echo`,
    # which hid both: a bad entitlements path left the bundle completely UNSIGNED
    # with no diagnostic, and every lane that rsyncs it then loses its TCC grants.
    codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$SIGNING_ENTITLEMENTS" "$APP_BUNDLE" \
        || { echo "codesign failed for $APP_BUNDLE (identity $SIGNING_IDENTITY, entitlements $SIGNING_ENTITLEMENTS)" >&2; exit 1; }
    echo "  Signed with: $SIGNING_IDENTITY (+ entitlements)"
fi
verify_signing "$APP_BUNDLE"

if [ "$BUILD_ONLY" = true ]; then
    echo "Bundle ready: $APP_BUNDLE"
    exit 0
fi

echo "Starting Meeting Transcriber..."
echo "  TRANSCRIBER_ROOT=$TRANSCRIBER_ROOT"

# Launch via `open` so macOS LaunchServices properly registers the app
# (required for notification permissions, etc.).
# The app discovers the project root by walking up from the executable.
open -W "$APP_BUNDLE"
