#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT_DIRS=(
    app/MeetingTranscriber/Sources
    app/MeetingTranscriber/Tests
    tools/audiotap/Sources
    tools/meeting-simulator/Sources
    scripts/generate_menu_bar_gifs.swift
)

# --- SwiftFormat (formatter) ---
if command -v swiftformat &>/dev/null; then
    if [[ "${1:-}" == "--fix" ]]; then
        echo "Running swiftformat..."
        swiftformat "${SWIFT_DIRS[@]}"
    else
        echo "Checking swiftformat..."
        swiftformat --dryrun --lint "${SWIFT_DIRS[@]}"
    fi
else
    echo "Warning: swiftformat not found. Install with: brew install swiftformat"
fi

# --- SwiftLint (linter) ---
if command -v swiftlint &>/dev/null; then
    if [[ "${1:-}" == "--fix" ]]; then
        echo "Running swiftlint --fix..."
        swiftlint lint --fix
    else
        echo "Running swiftlint..."
        swiftlint lint "$@"
    fi
else
    echo "Error: swiftlint not found. Install with: brew install swiftlint"
    exit 1
fi
