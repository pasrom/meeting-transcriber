#!/usr/bin/env bash
# Build the whisperkit-cli Swift binary.
# Usage: ./scripts/build_whisperkit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WHISPERKIT_DIR="$PROJECT_ROOT/tools/whisperkit-cli"

if [ ! -f "$WHISPERKIT_DIR/Package.swift" ]; then
    echo "ERROR: whisperkit-cli Package.swift not found at $WHISPERKIT_DIR" >&2
    exit 1
fi

echo "Building whisperkit-transcribe..."
cd "$WHISPERKIT_DIR" && swift build -c release

echo "Done. Binary at: $WHISPERKIT_DIR/.build/release/whisperkit-transcribe"
