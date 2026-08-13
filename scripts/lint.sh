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

# shellcheck source=scripts/tool-versions.sh
source scripts/tool-versions.sh

# Warn, never fail: CI runs the pinned binaries, this machine runs whatever is
# installed, and a mismatch means a local pass and a CI pass are two different
# claims. That is not hypothetical - the formatter pin sat two minors behind
# the machines using it, so `--fix` here rewrote files the pinned check then
# rejected. Warning rather than blocking on purpose: an unrelated one-line fix
# should not be gated on a toolchain upgrade.
warn_version_drift() {
    local tool="$1" expected="$2" got="$3"
    if [[ "$got" != "$expected" ]]; then
        echo "Warning: local $tool is $got, CI pins $expected. Results can differ; 'brew upgrade $tool' to match." >&2
    fi
}

# --- SwiftFormat (formatter) ---
if [[ "$RUN_FORMAT" == "true" ]]; then
    if command -v swiftformat &>/dev/null; then
        warn_version_drift swiftformat "$SWIFTFORMAT_VERSION" "$(swiftformat --version || echo unknown)"
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
        warn_version_drift swiftlint "$SWIFTLINT_VERSION" "$(swiftlint version || echo unknown)"
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
