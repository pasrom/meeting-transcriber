#!/usr/bin/env bash
# Build a self-contained MeetingTranscriber.app bundle with embedded Python.
#
# Usage:
#   ./scripts/build_release.sh [--notarize]
#
# Output:
#   .build/release/MeetingTranscriber.dmg
#
# Requirements:
#   - macOS 14+ (Sonoma) on Apple Silicon
#   - Xcode Command Line Tools (swift, codesign, hdiutil)
#   - Internet access (downloads python-build-standalone on first run)

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
if [[ "${1:-}" == "--notarize" ]]; then
    NOTARIZE=true
fi

# Read version from pyproject.toml
VERSION=$(grep '^version = ' "$PROJECT_ROOT/pyproject.toml" | head -1 | sed 's/version = "\(.*\)"/\1/')
echo "Building MeetingTranscriber v${VERSION}"
echo "======================================="

# ── Step 0: Clean previous build ─────────────────────────────────────────────

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES"

# ── Step 1: Download python-build-standalone ──────────────────────────────────

PYTHON_VERSION="3.14.3"
PBS_RELEASE="20260303"
# Use cpython from Astral's python-build-standalone releases (stripped = smaller)
PYTHON_ARCHIVE="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PYTHON_ARCHIVE}"

mkdir -p "$CACHE_DIR"
CACHED_ARCHIVE="$CACHE_DIR/$PYTHON_ARCHIVE"

if [ ! -f "$CACHED_ARCHIVE" ]; then
    echo ""
    echo "Step 1: Downloading python-build-standalone..."
    curl -L --progress-bar -o "$CACHED_ARCHIVE" "$PYTHON_URL"
else
    echo ""
    echo "Step 1: Using cached Python archive"
fi

echo "  Extracting Python to Resources/python-env/"
PYTHON_ENV="$RESOURCES/python-env"
mkdir -p "$PYTHON_ENV"
tar xzf "$CACHED_ARCHIVE" -C "$PYTHON_ENV" --strip-components=1

# ── Step 2: Install Python package into embedded env ──────────────────────────

echo ""
echo "Step 2: Installing meeting-transcriber into embedded Python..."
PYTHON_BIN="$PYTHON_ENV/bin/python3"

# Upgrade pip first (standalone Python may have an older pip)
"$PYTHON_BIN" -m pip install --upgrade pip --quiet

# Install the package with mac + diarize extras
"$PYTHON_BIN" -m pip install "$PROJECT_ROOT[mac,diarize]" --quiet

# Create a wrapper script for the transcribe entry point.
# The shebang must be relative so the bundle is relocatable.
TRANSCRIBE_WRAPPER="$PYTHON_ENV/bin/transcribe"
cat > "$TRANSCRIBE_WRAPPER" << 'WRAPPER_EOF'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/python3" -m meeting_transcriber.cli "$@"
WRAPPER_EOF
chmod +x "$TRANSCRIBE_WRAPPER"

# ── Step 3: Build audiotap binary ─────────────────────────────────────────────

echo ""
echo "Step 3: Building audiotap binary..."

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

# ── Step 4: Build Swift menu bar app ─────────────────────────────────────────

echo ""
echo "Step 4: Building Swift menu bar app..."

SPM_DIR="$PROJECT_ROOT/app/MeetingTranscriber"
(cd "$SPM_DIR" && swift build -c release --disable-sandbox)

# Copy binary to app bundle
cp "$SPM_DIR/.build/release/MeetingTranscriber" "$MACOS_DIR/MeetingTranscriber"

# ── Step 5: Assemble app bundle ──────────────────────────────────────────────

echo ""
echo "Step 5: Assembling app bundle..."

# Info.plist with version
sed "s|<string>1.0</string>|<string>${VERSION}</string>|g" \
    "$SPM_DIR/Sources/Info.plist" > "$CONTENTS/Info.plist"

# ── Step 6: Clean up embedded Python ─────────────────────────────────────────

echo ""
echo "Step 6: Cleaning up embedded Python (reducing bundle size)..."

# Remove __pycache__ directories
find "$PYTHON_ENV" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Remove pip, setuptools, pkg_resources (not needed at runtime)
rm -rf "$PYTHON_ENV"/lib/python*/site-packages/pip
rm -rf "$PYTHON_ENV"/lib/python*/site-packages/setuptools
rm -rf "$PYTHON_ENV"/lib/python*/site-packages/pkg_resources
rm -rf "$PYTHON_ENV"/lib/python*/site-packages/pip-*.dist-info
rm -rf "$PYTHON_ENV"/lib/python*/site-packages/setuptools-*.dist-info

# Remove test directories
find "$PYTHON_ENV" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$PYTHON_ENV" -type d -name "test" -exec rm -rf {} + 2>/dev/null || true

# Remove CUDA/ROCm libraries (CPU/MPS only on macOS)
find "$PYTHON_ENV" -name "*cuda*" -delete 2>/dev/null || true
find "$PYTHON_ENV" -name "*cudnn*" -delete 2>/dev/null || true
find "$PYTHON_ENV" -name "*rocm*" -delete 2>/dev/null || true

# Remove .pyc files (Python will regenerate as needed)
find "$PYTHON_ENV" -name "*.pyc" -delete 2>/dev/null || true

# Remove Python static library (not needed for embedding)
rm -f "$PYTHON_ENV"/lib/libpython*.a

# Remove Tcl/Tk (not needed, causes Homebrew dylib warnings)
rm -rf "$PYTHON_ENV"/lib/itcl*
rm -rf "$PYTHON_ENV"/lib/tdbc*
rm -rf "$PYTHON_ENV"/lib/tcl*
rm -rf "$PYTHON_ENV"/lib/tk*
rm -rf "$PYTHON_ENV"/lib/libtcl*
rm -rf "$PYTHON_ENV"/lib/libtk*
rm -rf "$PYTHON_ENV"/lib/pkgconfig/tcl*.pc
rm -rf "$PYTHON_ENV"/lib/pkgconfig/tk*.pc

# Remove share/man docs
rm -rf "$PYTHON_ENV/share"

echo "  Cleaned up unnecessary files"

# ── Step 7: Code signing ─────────────────────────────────────────────────────

echo ""
echo "Step 7: Code signing..."

if [ "$NOTARIZE" = true ]; then
    # Notarized build: requires Apple Developer ID
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

    # Sign all binaries and dylibs individually with hardened runtime
    # (--deep doesn't apply --options runtime to nested binaries)
    echo "  Signing embedded libraries..."
    find "$APP_BUNDLE" -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.a" \) -print0 | \
        xargs -0 -I{} codesign --force --sign "$DEVELOPER_ID" \
            --options runtime --timestamp "{}"

    # Sign ALL executable binaries anywhere in python-env (bin/, torch/bin/, etc.)
    echo "  Signing embedded executables..."
    find "$RESOURCES/python-env" -type f -perm +111 -not -name "*.py" -not -name "*.sh" -print0 2>/dev/null | \
        xargs -0 -I{} codesign --force --sign "$DEVELOPER_ID" \
            --options runtime --timestamp "{}"

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
    # Use local development certificate if available (stable identity
    # preserves Screen Recording permission across rebuilds).
    # Falls back to ad-hoc signing if no certificate is found.
    SIGN_HASH=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | awk '{print $2}')
    if [ -n "$SIGN_HASH" ] && [ "$SIGN_HASH" != "0" ]; then
        codesign --deep --force --sign "$SIGN_HASH" "$APP_BUNDLE"
        echo "  Signed with certificate: $SIGN_HASH"
    else
        codesign --deep --force --sign - "$APP_BUNDLE"
        echo "  Ad-hoc signed (install via right-click → Open)"
    fi
fi

# ── Step 8: Create DMG (skip if BUILD_DIR is not writable, e.g. Homebrew) ────

DMG_NAME="MeetingTranscriber-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

if [ -z "${HOMEBREW_TEMP:-}" ]; then
    echo ""
    echo "Step 8: Creating DMG..."

    # Remove old DMG if it exists
    rm -f "$DMG_PATH"

    # Move app bundle into a staging directory (mv avoids permission
    # issues that ditto/cp have with Developer ID signed bundles).
    DMG_STAGING="$BUILD_DIR/dmg-staging"
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    mv "$APP_BUNDLE" "$DMG_STAGING/MeetingTranscriber.app"

    # Create a symlink to /Applications for drag-and-drop install
    ln -s /Applications "$DMG_STAGING/Applications"

    hdiutil create -volname "MeetingTranscriber" \
        -srcfolder "$DMG_STAGING" \
        -ov -format UDZO \
        "$DMG_PATH"

    # Move the app bundle back so it remains available after DMG creation
    mv "$DMG_STAGING/MeetingTranscriber.app" "$APP_BUNDLE"
    rm -rf "$DMG_STAGING"

    # ── Step 9: Notarize (optional) ──────────────────────────────────────────

    if [ "$NOTARIZE" = true ]; then
        echo ""
        echo "Step 9: Notarizing DMG..."

        if [ -z "${APPLE_ID:-}" ] || [ -z "${TEAM_ID:-}" ] || [ -z "${APP_PASSWORD:-}" ]; then
            echo "  ERROR: APPLE_ID, TEAM_ID, and APP_PASSWORD must be set for notarization."
            exit 1
        fi

        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APP_PASSWORD" \
            --wait

        xcrun stapler staple "$DMG_PATH"
        echo "  DMG notarized and stapled"
    fi
else
    echo ""
    echo "Step 8: Skipping DMG (build dir not writable — Homebrew mode)"
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
