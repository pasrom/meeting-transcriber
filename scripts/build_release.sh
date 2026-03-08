#!/usr/bin/env bash
# Build a self-contained MeetingTranscriber.app bundle.
#
# Usage:
#   ./scripts/build_release.sh [--notarize] [--with-diarize]
#
# Without --with-diarize: Swift-only bundle (~100 MB)
#   - audiotap (app audio capture)
#   - MeetingTranscriber (Swift menu bar app with WhisperKit)
#
# With --with-diarize: adds Python diarization venv (~200 MB)
#   - python-diarize/ (pyannote-audio + torch)
#   - diarize.py (standalone script)
#
# Output:
#   .build/release/MeetingTranscriber.dmg
#
# Requirements:
#   - macOS 14+ (Sonoma) on Apple Silicon
#   - Xcode Command Line Tools (swift, codesign, hdiutil)
#   - Internet access (downloads python-build-standalone if --with-diarize)

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
CACHE_DIR="$PROJECT_ROOT/.build/python-standalone-cache"
APP_BUNDLE="$BUILD_DIR/MeetingTranscriber.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

NOTARIZE=false
WITH_DIARIZE=false
for arg in "$@"; do
    case "$arg" in
        --notarize) NOTARIZE=true ;;
        --with-diarize) WITH_DIARIZE=true ;;
    esac
done

# Read version from pyproject.toml
VERSION=$(grep '^version = ' "$PROJECT_ROOT/pyproject.toml" | head -1 | sed 's/version = "\(.*\)"/\1/')
echo "Building MeetingTranscriber v${VERSION}"
echo "  Diarization: $WITH_DIARIZE"
echo "  Notarize:    $NOTARIZE"
echo "======================================="

# ── Step 0: Clean previous build ─────────────────────────────────────────────

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES"

# ── Step 1: Build audiotap binary ────────────────────────────────────────────

echo ""
echo "Step 1: Building audiotap binary..."

AUDIOTAP_DIR="$PROJECT_ROOT/tools/audiotap"
(cd "$AUDIOTAP_DIR" && swift build -c release --disable-sandbox)

AUDIOTAP_BIN="$AUDIOTAP_DIR/.build/release/audiotap"
if [ -f "$AUDIOTAP_BIN" ]; then
    cp "$AUDIOTAP_BIN" "$RESOURCES/audiotap"
    echo "  audiotap binary: $RESOURCES/audiotap"
else
    echo "  WARNING: audiotap binary not found after build."
    echo "  App audio capture will not work."
fi

# ── Step 2: Build Swift menu bar app ─────────────────────────────────────────

echo ""
echo "Step 2: Building Swift menu bar app..."

SPM_DIR="$PROJECT_ROOT/app/MeetingTranscriber"
(cd "$SPM_DIR" && swift build -c release --disable-sandbox)

cp "$SPM_DIR/.build/release/MeetingTranscriber" "$MACOS_DIR/MeetingTranscriber"

# ── Step 3: Assemble app bundle ──────────────────────────────────────────────

echo ""
echo "Step 3: Assembling app bundle..."

# Info.plist with version
sed "s|<string>1.0</string>|<string>${VERSION}</string>|g" \
    "$SPM_DIR/Sources/Info.plist" > "$CONTENTS/Info.plist"

# ── Step 4 (optional): Build diarization Python venv ─────────────────────────

if [ "$WITH_DIARIZE" = true ]; then
    echo ""
    echo "Step 4: Building diarization Python venv..."

    PYTHON_VERSION="3.14.3"
    PBS_RELEASE="20260303"
    PYTHON_ARCHIVE="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz"
    PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PYTHON_ARCHIVE}"

    mkdir -p "$CACHE_DIR"
    CACHED_ARCHIVE="$CACHE_DIR/$PYTHON_ARCHIVE"

    if [ ! -f "$CACHED_ARCHIVE" ]; then
        echo "  Downloading python-build-standalone..."
        curl -L --progress-bar -o "$CACHED_ARCHIVE" "$PYTHON_URL"
    else
        echo "  Using cached Python archive"
    fi

    # Extract standalone Python directly as the diarize environment
    # (no venv — avoids broken symlinks and missing stdlib)
    DIARIZE_ENV="$RESOURCES/python-diarize"
    rm -rf "$DIARIZE_ENV"
    mkdir -p "$DIARIZE_ENV"
    tar xzf "$CACHED_ARCHIVE" -C "$DIARIZE_ENV" --strip-components=1

    echo "  Installing diarization dependencies..."
    "$DIARIZE_ENV/bin/pip3" install --upgrade pip --quiet
    "$DIARIZE_ENV/bin/pip3" install -r "$PROJECT_ROOT/tools/diarize/requirements.txt" --quiet

    # Copy standalone diarize script
    cp "$PROJECT_ROOT/tools/diarize/diarize.py" "$DIARIZE_ENV/diarize.py"

    # Clean up cruft to reduce bundle size
    rm -rf "$DIARIZE_ENV"/lib/python*/site-packages/pip
    rm -rf "$DIARIZE_ENV"/lib/python*/site-packages/setuptools
    rm -rf "$DIARIZE_ENV"/lib/python*/site-packages/pkg_resources
    rm -rf "$DIARIZE_ENV"/lib/python*/site-packages/pip-*.dist-info
    rm -rf "$DIARIZE_ENV"/lib/python*/site-packages/setuptools-*.dist-info
    find "$DIARIZE_ENV" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "$DIARIZE_ENV" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
    find "$DIARIZE_ENV" -type d -name "test" -exec rm -rf {} + 2>/dev/null || true
    # Remove large CUDA/ROCm binary libraries (not Python source referencing CUDA)
    find "$DIARIZE_ENV" -name "*.so" -path "*cuda*" -delete 2>/dev/null || true
    find "$DIARIZE_ENV" -name "*.dylib" -path "*cuda*" -delete 2>/dev/null || true
    find "$DIARIZE_ENV" -name "*.so" -path "*cudnn*" -delete 2>/dev/null || true
    find "$DIARIZE_ENV" -name "*.so" -path "*rocm*" -delete 2>/dev/null || true
    find "$DIARIZE_ENV" -name "*.pyc" -delete 2>/dev/null || true
    rm -f "$DIARIZE_ENV"/lib/libpython*.a
    rm -rf "$DIARIZE_ENV/share"
    rm -rf "$DIARIZE_ENV/include"

    DIARIZE_SIZE=$(du -sh "$DIARIZE_ENV" | cut -f1)
    echo "  Diarization env: $DIARIZE_SIZE"
else
    echo ""
    echo "Step 4: Skipping diarization (use --with-diarize to include)"
fi

# ── Step 5: Code signing ─────────────────────────────────────────────────────

echo ""
echo "Step 5: Code signing..."

if [ "$NOTARIZE" = true ]; then
    if [ -z "${DEVELOPER_ID:-}" ]; then
        echo "  ERROR: DEVELOPER_ID not set. Set it to your 'Developer ID Application: ...' identity."
        exit 1
    fi

    # Create entitlements file
    ENTITLEMENTS="$BUILD_DIR/entitlements.plist"
    cat > "$ENTITLEMENTS" << 'ENTITLEMENTS_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS_EOF

    # Sign all dylibs/shared objects
    echo "  Signing embedded libraries..."
    find "$APP_BUNDLE" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 | \
        xargs -0 -I{} codesign --force --sign "$DEVELOPER_ID" \
            --options runtime --timestamp "{}"

    # Sign executables in diarization venv (if present)
    if [ -d "$RESOURCES/python-diarize" ]; then
        echo "  Signing diarization executables..."
        find "$RESOURCES/python-diarize" -type f -perm +111 -not -name "*.py" -not -name "*.sh" -print0 2>/dev/null | \
            xargs -0 -I{} codesign --force --sign "$DEVELOPER_ID" \
                --options runtime --timestamp "{}"
    fi

    # Sign audiotap binary
    if [ -f "$RESOURCES/audiotap" ]; then
        codesign --force --sign "$DEVELOPER_ID" \
            --options runtime --timestamp "$RESOURCES/audiotap"
    fi

    # Sign the main app binary with entitlements
    codesign --force --sign "$DEVELOPER_ID" \
        --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
        "$APP_BUNDLE"
    echo "  Signed with Developer ID for notarization"
else
    # Use local development certificate if available
    SIGN_HASH=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | awk '{print $2}')
    if [ -n "$SIGN_HASH" ] && [ "$SIGN_HASH" != "0" ]; then
        codesign --deep --force --sign "$SIGN_HASH" "$APP_BUNDLE"
        echo "  Signed with certificate: $SIGN_HASH"
    else
        codesign --deep --force --sign - "$APP_BUNDLE"
        echo "  Ad-hoc signed (install via right-click → Open)"
    fi
fi

# ── Step 6: Create DMG ───────────────────────────────────────────────────────

DMG_NAME="MeetingTranscriber-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

if [ -z "${HOMEBREW_TEMP:-}" ]; then
    echo ""
    echo "Step 6: Creating DMG..."

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

    # ── Step 7: Notarize (optional) ──────────────────────────────────────────

    if [ "$NOTARIZE" = true ]; then
        echo ""
        echo "Step 7: Notarizing DMG..."

        if [ -z "${APPLE_ID:-}" ] || [ -z "${TEAM_ID:-}" ] || [ -z "${APP_PASSWORD:-}" ]; then
            echo "  ERROR: APPLE_ID, TEAM_ID, and APP_PASSWORD must be set for notarization."
            exit 1
        fi

        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APP_PASSWORD"

        echo "  DMG submitted for notarization (no --wait, no staple)"
        echo "  Gatekeeper will verify online when users open the DMG"
    fi
else
    echo ""
    echo "Step 6: Skipping DMG (Homebrew mode)"
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
