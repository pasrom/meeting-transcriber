#!/usr/bin/env bash
# Build a self-contained MeetingTranscriber.app bundle.
#
# Usage:
#   ./scripts/build_release.sh [--no-notarize] [--staple] [--appstore]
#
# Output:
#   .build/release/MeetingTranscriber.dmg
#
# Requirements:
#   - macOS 14+ (Sonoma) on Apple Silicon
#   - Xcode Command Line Tools (swift, codesign, hdiutil)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env if present (APP_PASSWORD, DEVELOPER_ID, etc.)
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

BUILD_DIR="$PROJECT_ROOT/.build/release"
APP_BUNDLE="$BUILD_DIR/MeetingTranscriber.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

NOTARIZE=true
STAPLE=false
APPSTORE=false
OVERRIDE_VERSION=""
for arg in "$@"; do
    case "$arg" in
        --no-notarize) NOTARIZE=false ;;
        --staple) STAPLE=true ;;
        --appstore) APPSTORE=true ;;
        --version=*) OVERRIDE_VERSION="${arg#--version=}" ;;
    esac
done

# Read version: prefer --version flag, then VERSION file
if [ -n "$OVERRIDE_VERSION" ]; then
    VERSION="$OVERRIDE_VERSION"
else
    VERSION=$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')
fi
echo "Building MeetingTranscriber v${VERSION}"
echo "  Notarize:    $NOTARIZE"
echo "  Staple:      $STAPLE"
echo "  App Store:   $APPSTORE"
echo "======================================="

# ── Step 0: Clean previous build ─────────────────────────────────────────────

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES"

# ── Step 1: Build Swift menu bar app ─────────────────────────────────────────

echo ""
echo "Step 1: Building Swift menu bar app..."

SPM_DIR="$PROJECT_ROOT/app/MeetingTranscriber"
SWIFT_BUILD_FLAGS=(-c release --disable-sandbox)
if [ "$APPSTORE" = true ]; then
    SWIFT_BUILD_FLAGS+=(-Xswiftc -DAPPSTORE)
fi
(cd "$SPM_DIR" && swift build "${SWIFT_BUILD_FLAGS[@]}")

cp "$SPM_DIR/.build/release/MeetingTranscriber" "$MACOS_DIR/MeetingTranscriber"

# ── Step 2: Assemble app bundle ──────────────────────────────────────────────

echo ""
echo "Step 2: Assembling app bundle..."

# Info.plist with version
cp "$SPM_DIR/Sources/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"

# App icon
ICONSET_SRC="$SPM_DIR/Sources/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICONSET_SRC" ]; then
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    cp "$ICONSET_SRC/icon_16x16.png"      "$ICONSET/icon_16x16.png"
    cp "$ICONSET_SRC/icon_16x16@2x.png"   "$ICONSET/icon_16x16@2x.png"
    cp "$ICONSET_SRC/icon_32x32.png"       "$ICONSET/icon_32x32.png"
    cp "$ICONSET_SRC/icon_32x32@2x.png"    "$ICONSET/icon_32x32@2x.png"
    cp "$ICONSET_SRC/icon_128x128.png"     "$ICONSET/icon_128x128.png"
    cp "$ICONSET_SRC/icon_128x128@2x.png"  "$ICONSET/icon_128x128@2x.png"
    cp "$ICONSET_SRC/icon_256x256.png"     "$ICONSET/icon_256x256.png"
    cp "$ICONSET_SRC/icon_256x256@2x.png"  "$ICONSET/icon_256x256@2x.png"
    cp "$ICONSET_SRC/icon_512x512.png"     "$ICONSET/icon_512x512.png"
    cp "$ICONSET_SRC/icon_512x512@2x.png"  "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
    rm -rf "$ICONSET"
    echo "  App icon: $RESOURCES/AppIcon.icns"
fi

# Inject git commit hash
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
/usr/libexec/PlistBuddy -c "Add :GitCommitHash string $GIT_HASH" "$CONTENTS/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :GitCommitHash $GIT_HASH" "$CONTENTS/Info.plist"

# ── Step 3: Code signing ─────────────────────────────────────────────────────

echo ""
echo "Step 3: Code signing..."

# Select entitlements based on build variant
if [ "$APPSTORE" = true ]; then
    ENTITLEMENTS="$SPM_DIR/Entitlements/AppStore.entitlements"
else
    ENTITLEMENTS="$SPM_DIR/Entitlements/Homebrew.entitlements"
fi

if [ "$NOTARIZE" = true ]; then
    if [ -z "${DEVELOPER_ID:-}" ]; then
        echo "  ERROR: DEVELOPER_ID not set. Set it to your 'Developer ID Application: ...' identity."
        exit 1
    fi

    # Sign all dylibs/shared objects (one at a time to avoid xargs arg length limits)
    echo "  Signing embedded libraries..."
    find "$APP_BUNDLE" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 | \
        while IFS= read -r -d '' lib; do
            codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp "$lib"
        done

    # Sign the main app binary with entitlements
    codesign --force --sign "$DEVELOPER_ID" \
        --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
        "$APP_BUNDLE"
    echo "  Signed with Developer ID for notarization"

    # When --staple is set, notarize and staple the .app itself so Gatekeeper
    # does not need to contact Apple online when the app is launched (cask
    # installs strip the DMG context, so the DMG ticket alone is not sufficient).
    if [ "$STAPLE" = true ]; then
        if [ -z "${APPLE_ID:-}" ] || [ -z "${TEAM_ID:-}" ] || [ -z "${APP_PASSWORD:-}" ]; then
            echo "  ERROR: APPLE_ID, TEAM_ID, and APP_PASSWORD must be set for notarization."
            exit 1
        fi

        echo "  Notarizing .app bundle..."
        APP_ZIP="$BUILD_DIR/MeetingTranscriber-app.zip"
        rm -f "$APP_ZIP"
        ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
        xcrun notarytool submit "$APP_ZIP" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APP_PASSWORD" \
            --wait
        rm -f "$APP_ZIP"

        echo "  Stapling notarization ticket to .app..."
        xcrun stapler staple "$APP_BUNDLE"
        xcrun stapler validate "$APP_BUNDLE"
    fi
else
    # Use local development certificate if available (extract 40-char hex SHA-1 hash)
    SIGN_HASH=$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '[0-9A-F]{40}' | head -1)
    if [ -n "$SIGN_HASH" ]; then
        codesign --deep --force --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
        echo "  Signed with certificate: $SIGN_HASH"
    else
        codesign --deep --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
        echo "  Ad-hoc signed (install via right-click → Open)"
    fi
fi

# ── Step 5: Create DMG ───────────────────────────────────────────────────────

if [ "$APPSTORE" = true ]; then
    DMG_NAME="MeetingTranscriber-AppStore-${VERSION}.dmg"
else
    DMG_NAME="MeetingTranscriber-${VERSION}.dmg"
fi
DMG_PATH="$BUILD_DIR/$DMG_NAME"

if [ -z "${HOMEBREW_TEMP:-}" ]; then
    echo ""
    echo "Step 4: Creating DMG..."

    rm -f "$DMG_PATH"

    DMG_STAGING="$BUILD_DIR/dmg-staging"
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    mv "$APP_BUNDLE" "$DMG_STAGING/MeetingTranscriber.app"
    ln -s /Applications "$DMG_STAGING/Applications"

    hdiutil create -volname "MeetingTranscriber" \
        -srcfolder "$DMG_STAGING" \
        -ov -format UDZO \
        "$DMG_PATH"

    mv "$DMG_STAGING/MeetingTranscriber.app" "$APP_BUNDLE"
    rm -rf "$DMG_STAGING"

    # ── Step 5: Notarize (optional) ──────────────────────────────────────────

    if [ "$NOTARIZE" = true ]; then
        echo ""
        echo "Step 5: Notarizing DMG..."

        if [ -z "${APPLE_ID:-}" ] || [ -z "${TEAM_ID:-}" ] || [ -z "${APP_PASSWORD:-}" ]; then
            echo "  ERROR: APPLE_ID, TEAM_ID, and APP_PASSWORD must be set for notarization."
            exit 1
        fi

        WAIT_FLAG=""
        [ "$STAPLE" = true ] && WAIT_FLAG="--wait"

        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APP_PASSWORD" \
            $WAIT_FLAG

        if [ "$STAPLE" = true ]; then
            echo "  Stapling notarization ticket to DMG..."
            xcrun stapler staple "$DMG_PATH"
            xcrun stapler validate "$DMG_PATH"
        else
            echo "  DMG submitted for notarization (Gatekeeper will verify online)"
        fi
    fi
else
    echo ""
    echo "Step 4: Skipping DMG (Homebrew mode)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "======================================="
BUNDLE_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo "App bundle: $APP_BUNDLE ($BUNDLE_SIZE)"
if [ -f "$DMG_PATH" ]; then
    DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
    echo "DMG:        $DMG_PATH ($DMG_SIZE)"
    echo ""
    echo "To test: open $DMG_PATH"
fi
