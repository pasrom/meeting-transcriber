#!/usr/bin/env bash
# Removes this repository's own build output from the analyze job's DerivedData,
# leaving what a dependency-only cache may keep: the package checkouts, the
# compiled dependency modules and the build database.
#
#   prune-analyze-derived-data.sh <derived-data-dir>
#
# With its own outputs gone from the saved entry, xcodebuild has to compile
# AudioTapLib, the app and the tests from scratch, so the log `swiftlint analyze`
# reads is complete (the reason is in scripts/ci/check-compiler-log-coverage.sh,
# which verifies the result on every run rather than trusting this list). The
# job runs this once, before the cache is saved.
#
# rm -rf ignores a path that does not exist or a glob that matches nothing, so a
# cold cache needs no special case.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $(basename "$0") <derived-data-dir>" >&2
    exit 2
fi

dd="$1"

# Intermediates of the local projects the scheme builds (the app package and the
# AudioTapLib package with its C target), then their products. Dependency
# products (WhisperKit, FluidAudio, ...) sit in the same folder and must stay.
# Logs and the index only grow the cache.
rm -rf \
    "$dd"/Build/Intermediates.noindex/{MeetingTranscriber,AudioTapLib}.build \
    "$dd"/Build/Products/*/{MeetingTranscriber*,AudioTapLib*,CExceptionCatcher*,ExecutableModules} \
    "$dd/Logs" "$dd/Index.noindex"
