#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT_DIRS=(
    app/MeetingTranscriber/Sources
    app/MeetingTranscriber/Tests
    tools/audiotap/Sources
    tools/meeting-simulator/Sources
    tools/mt-cli/Sources
    tools/mt-cli/Tests
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
# `--strict` promotes warning-level rules to errors so any new violation
# fails CI rather than slowly accumulating. Pair with the swiftSettings'
# `-warnings-as-errors` for full zero-warning enforcement.
if command -v swiftlint &>/dev/null; then
    if [[ "${1:-}" == "--fix" ]]; then
        echo "Running swiftlint --fix..."
        swiftlint lint --fix --strict
    else
        echo "Running swiftlint --strict..."
        swiftlint lint --strict "$@"
    fi
else
    echo "Error: swiftlint not found. Install with: brew install swiftlint"
    exit 1
fi
