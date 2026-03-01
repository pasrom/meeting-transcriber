#!/usr/bin/env bash
# Launch the Meeting Transcriber menu bar app.
# Builds an .app bundle so macOS APIs (notifications, etc.) work correctly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSCRIBER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export TRANSCRIBER_ROOT

SPM_DIR="$TRANSCRIBER_ROOT/app/MeetingTranscriber"
BUILD_BINARY="$SPM_DIR/.build/release/MeetingTranscriber"
APP_BUNDLE="$SPM_DIR/.build/MeetingTranscriber.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/MeetingTranscriber"
INFO_PLIST="$SPM_DIR/Sources/Info.plist"

# Build if needed
if [ ! -f "$BUILD_BINARY" ]; then
    echo "Building Meeting Transcriber app..."
    cd "$SPM_DIR"
    swift build -c release
fi

# Assemble .app bundle
mkdir -p "$APP_MACOS"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILD_BINARY" "$APP_BINARY"

# Code-sign so macOS keeps Screen Recording permission across rebuilds.
# Uses SHA-1 hash to avoid "ambiguous identity" errors with duplicate names.
SIGN_HASH=$(security find-identity -v -p codesigning | head -1 | awk '{print $2}')
if [ -n "$SIGN_HASH" ]; then
    codesign --force --sign "$SIGN_HASH" "$APP_BUNDLE" 2>/dev/null && \
        echo "  Signed with: $SIGN_HASH"
fi

echo "Starting Meeting Transcriber..."
echo "  TRANSCRIBER_ROOT=$TRANSCRIBER_ROOT"

# Launch via `open` so macOS LaunchServices properly registers the app
# (required for notification permissions, etc.).
# The app discovers the project root by walking up from the executable.
open -W "$APP_BUNDLE"
