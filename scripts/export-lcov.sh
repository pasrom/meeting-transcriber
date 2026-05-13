#!/usr/bin/env bash
# Export LCOV coverage for an SPM package's xctest bundle.
#
# Usage: scripts/export-lcov.sh <package-dir> <output-path>
#
# Locates the most recently built `.xctest` bundle and `default.profdata`
# in <package-dir>, exports an LCOV report via `xcrun llvm-cov export`,
# writes to <output-path>. Caller must have already run
# `swift test --enable-code-coverage` in <package-dir>.

set -euo pipefail

package_dir=${1:?package-dir required (e.g. app/MeetingTranscriber)}
output_path=${2:?output-path required (e.g. coverage-homebrew.lcov)}

cd "$package_dir"
bin_path=$(swift build --show-bin-path)
profdata="$bin_path/codecov/default.profdata"
xctest_dir=$(find "$bin_path" -name '*.xctest' -type d | head -n1)
[[ -n "$xctest_dir" ]] || { echo "::error::no .xctest bundle in $bin_path" >&2; exit 1; }
xctest_bin="$xctest_dir/Contents/MacOS/$(basename "$xctest_dir" .xctest)"

xcrun llvm-cov export \
  -format=lcov \
  -instr-profile="$profdata" \
  -ignore-filename-regex='\.build/|Tests/|/usr/' \
  "$xctest_bin" \
  > "$output_path"
wc -l "$output_path"
