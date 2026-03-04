#!/usr/bin/env bash
# Build the audiotap Swift binary (CATapDescription-based audio capture).
# Usage: ./scripts/build_audiotap.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUDIOTAP_DIR="$PROJECT_ROOT/tools/audiotap"

if [ ! -f "$AUDIOTAP_DIR/Package.swift" ]; then
    echo "ERROR: audiotap Package.swift not found at $AUDIOTAP_DIR" >&2
    exit 1
fi

echo "Building audiotap..."
cd "$AUDIOTAP_DIR" && swift build -c release

echo "Done. Binary at: $AUDIOTAP_DIR/.build/release/audiotap"
