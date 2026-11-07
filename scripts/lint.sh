#!/usr/bin/env bash
# Lint orchestrator. Single source of truth for the Swift directories that get
# formatted and linted across local dev and CI.
#
# Usage:
#   ./scripts/lint.sh                # check both (dry-run)
#   ./scripts/lint.sh --fix          # auto-correct both
#   ./scripts/lint.sh --format-only  # only SwiftFormat
#   ./scripts/lint.sh --lint-only    # only SwiftLint
#   ./scripts/lint.sh --analyze      # only `swiftlint analyze`, as CI runs it (slow)

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
    --analyze)     RUN_FORMAT=false; RUN_LINT=false ;;
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

require_swiftlint() {
    if ! command -v swiftlint &>/dev/null; then
        echo "Error: swiftlint not found. Install with: brew install swiftlint"
        exit 1
    fi
    warn_version_drift swiftlint "$SWIFTLINT_VERSION" "$(swiftlint version || echo unknown)"
}

# --- SwiftLint (linter) ---
# `--strict` promotes warning-level rules to errors so any new violation
# fails CI rather than slowly accumulating. Pair with the swiftSettings'
# `-warnings-as-errors` for full zero-warning enforcement.
if [[ "$RUN_LINT" == "true" ]]; then
    require_swiftlint
    if [[ "$MODE" == "--fix" ]]; then
        echo "Running swiftlint --fix..."
        swiftlint lint --fix --strict
    else
        echo "Running swiftlint --strict..."
        swiftlint lint --strict
    fi
fi

# --- SwiftLint analyze (mirrors the `analyze` job in .github/workflows/ci.yml) ---
# The analyzer rules in .swiftlint.yml read the compiler arguments from an
# xcodebuild log, so this needs a build, and a clean one: an incremental build
# logs only the recompiled files, and `unused_declaration` then reports
# declarations whose callers were not in the log.
#
# Differs from CI in two ways, both stated here so a local/CI split is not a
# surprise: CI pins its Xcode through DEVELOPER_DIR (this uses whatever
# `xcode-select` points at, printed below), and CI adds a type-check timing flag
# that does not change analyze's findings.
if [[ "$MODE" == "--analyze" ]]; then
    require_swiftlint
    echo "Using $(xcodebuild -version | head -n 1); CI pins the Xcode named in ci.yml."
    # `pwd -P`: TMPDIR is a symlink on macOS, and swiftlint drops files whose
    # resolved path does not match the one in the log.
    work="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lint-analyze.XXXXXX")" && pwd -P)"
    log="$work/xcodebuild.log"
    # Packages are cached between runs (gitignored); only the build is clean.
    packages="$PWD/app/MeetingTranscriber/.build/analyze-packages"
    echo "Building for analyze (clean, a few minutes)..."
    if ! (cd app/MeetingTranscriber && xcodebuild -scheme MeetingTranscriber -destination 'platform=macOS' \
        -derivedDataPath "$work/DerivedData" -clonedSourcePackagesDirPath "$packages" \
        SWIFT_SUPPRESS_WARNINGS=NO build-for-testing >"$log" 2>&1); then
        # Keep the folder: the real error is often far above the last lines.
        echo "Error: the build failed, so there is nothing to analyze. Last lines below;" >&2
        echo "the full log is $log (delete $work when done)." >&2
        tail -n 30 "$log" >&2
        exit 1
    fi
    echo "Running swiftlint analyze --strict..."
    status=0
    swiftlint analyze --strict --compiler-log-path "$log" || status=$?
    if [[ "$status" -eq 0 ]]; then
        rm -rf "$work"
    else
        # Kept so a fix can be checked without another clean build.
        echo "Re-run after a fix: swiftlint analyze --strict --compiler-log-path $log" >&2
        echo "(delete $work when done)" >&2
    fi
    exit "$status"
fi
