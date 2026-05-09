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

# Always rebuild to pick up code changes
echo "Building Meeting Transcriber app..."
cd "$SPM_DIR"
swift build -c release

# Assemble .app bundle
mkdir -p "$APP_MACOS"
# Use dev bundle identifier to keep permissions separate from release
sed 's/com\.meetingtranscriber\.app/com.meetingtranscriber.dev/' \
    "$INFO_PLIST" > "$APP_BUNDLE/Contents/Info.plist"

# Inject version from VERSION file
APP_VERSION=$(cat "$TRANSCRIBER_ROOT/VERSION" | tr -d '[:space:]')
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Inject git commit hash into Info.plist
GIT_HASH=$(git -C "$TRANSCRIBER_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
/usr/libexec/PlistBuddy -c "Add :GitCommitHash string $GIT_HASH" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :GitCommitHash $GIT_HASH" "$APP_BUNDLE/Contents/Info.plist"

cp "$BUILD_BINARY" "$APP_BINARY"

# Code-sign so macOS keeps Screen Recording permission across rebuilds.
# Uses SHA-1 hash to avoid "ambiguous identity" errors with duplicate names.
SIGN_HASH=$(security find-identity -v -p codesigning | head -1 | awk '{print $2}')
if [ -n "$SIGN_HASH" ]; then
    codesign --force --sign "$SIGN_HASH" "$APP_BUNDLE" 2>/dev/null && \
        echo "  Signed with: $SIGN_HASH"
fi

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
