#!/usr/bin/env bash
# Resolves the Swift package graph for an xcodebuild scheme, retrying on failure.
#
# Why this exists: xcodebuild resolves packages as the first part of a build,
# binary targets included (NemoTextProcessing and LocalVQE come from GitHub
# release downloads). GitHub answers those downloads with a 504 now and then,
# and xcodebuild tries once, so one bad answer failed the analyze job with
# "Could not resolve package dependencies ... badResponseStatusCode(504)".
# Resolving in a step of its own lets that one part be retried; the build that
# follows finds the graph resolved and the artifacts in place.
#
# The waits double from 15 s (15, 30, 60, 120), so five attempts span about
# four minutes, longer than the 504 spells seen on the runners. A real
# resolution error (a wrong version, a checksum mismatch) fails the same way
# five times, so the cost of retrying it is those four minutes, not a wrong
# result.
#
# Usage: scripts/ci/resolve-packages.sh <xcodebuild args...>
# scripts/tests/test_resolve_packages.sh pins the retry behaviour.
set -euo pipefail

attempts=5
delay=15
for ((attempt = 1; attempt <= attempts; attempt++)); do
    if xcodebuild -resolvePackageDependencies "$@"; then
        exit 0
    fi
    if ((attempt < attempts)); then
        echo "::warning::Package resolution failed (attempt $attempt of $attempts), retrying in ${delay} s"
        sleep "$delay"
        delay=$((delay * 2))
    fi
done
echo "::error::Package resolution failed $attempts times"
exit 1
