#!/usr/bin/env bash
# Copies patched main.swift into the ProcTap package, then builds with Swift.
# Usage: ./scripts/build_proctap.sh [venv_path]
set -euo pipefail

VENV="${1:-.venv}"
SWIFT_DIR="${VENV}/lib/python3.14/site-packages/proctap/swift/screencapture-audio"

if [ ! -d "$SWIFT_DIR" ]; then
    echo "ERROR: ProcTap Swift directory not found at $SWIFT_DIR" >&2
    echo "Make sure proc-tap is installed: pip install -e '.[mac]'" >&2
    exit 1
fi

echo "Copying patched main.swift -> ${SWIFT_DIR}/Sources/screencapture-audio/"
cp patches/screencapture-audio/main.swift "${SWIFT_DIR}/Sources/screencapture-audio/"

echo "Building Swift binary..."
cd "$SWIFT_DIR" && swift build -c release

echo "Done. Binary at: ${SWIFT_DIR}/.build/release/screencapture-audio"
