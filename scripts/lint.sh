#!/usr/bin/env bash
# Lint orchestrator. Single source of truth for the Swift directories that get
# formatted and linted across local dev and CI.
#
# Usage:
#   ./scripts/lint.sh                # check both (dry-run)
#   ./scripts/lint.sh --fix          # auto-correct both
#   ./scripts/lint.sh --format-only  # only SwiftFormat
#   ./scripts/lint.sh --lint-only    # only SwiftLint

set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT_DIRS=(
    app/MeetingTranscriber/Sources
    app/MeetingTranscriber/Tests
    tools/audiotap/Sources
    tools/audiotap/Tests
    tools/meeting-simulator/Sources
    tools/mt-cli/Sources
    tools/mt-cli/Tests
    scripts/generate_menu_bar_gifs.swift
)

MODE="${1:-}"
RUN_FORMAT=true
RUN_LINT=true
case "$MODE" in
    --format-only) RUN_LINT=false ;;
    --lint-only)   RUN_FORMAT=false ;;
esac

# --- SwiftFormat (formatter) ---
if [[ "$RUN_FORMAT" == "true" ]]; then
    if command -v swiftformat &>/dev/null; then
        if [[ "$MODE" == "--fix" ]]; then
            echo "Running swiftformat..."
            swiftformat "${SWIFT_DIRS[@]}"
        else
            echo "Checking swiftformat..."
            swiftformat --dryrun --lint "${SWIFT_DIRS[@]}"
        fi
    else
        echo "Warning: swiftformat not found. Install with: brew install swiftformat"
    fi
fi

# --- SwiftLint (linter) ---
# `--strict` promotes warning-level rules to errors so any new violation
# fails CI rather than slowly accumulating. Pair with the swiftSettings'
# `-warnings-as-errors` for full zero-warning enforcement.
if [[ "$RUN_LINT" == "true" ]]; then
    if command -v swiftlint &>/dev/null; then
        if [[ "$MODE" == "--fix" ]]; then
            echo "Running swiftlint --fix..."
            swiftlint lint --fix --strict
        else
            echo "Running swiftlint --strict..."
            swiftlint lint --strict
        fi
    else
        echo "Error: swiftlint not found. Install with: brew install swiftlint"
        exit 1
    fi
fi
