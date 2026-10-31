#!/usr/bin/env bash
# Runs the model pre-warm, `swift test --filter ModelPreloadTests [args...]`,
# from the package folder, and retries it once when it fails in a way a
# network blip can explain. Used by .github/actions/runner-home and
# .github/actions/setup-swift-test; tested by
# scripts/tests/test_prewarm_models.sh.
#
# Usage: (cd app/MeetingTranscriber && prewarm-models.sh [swift test args...])
#   PREWARM_MARKER  optional. Written once the suite has passed; when it
#                   already exists nothing runs. runner-home keys its warm
#                   cache on it; setup-swift-test leaves it unset, since
#                   actions/cache decides when that step runs.
#   PREWARM_LOG     the output of the last attempt (default under RUNNER_TEMP,
#                   else a fresh temp file: the Mini's runners share /tmp).
#   PREWARM_BACKOFF_SECONDS  wait before the retry (default 30).
#
# Why retry: the pre-warm downloads about 1 GB of models and the package
# checkouts, so a DNS blip or a Hugging Face hiccup failed the job, and on a
# sanitizer leg its cancel step then cancelled the whole run, which the gate
# reports as a sanitizer failure although no sanitizer test ran.
#
# Why a second attempt is safe: nothing from a failed attempt can pass for a
# finished model. The Hub client writes each file as `*.incomplete` and renames
# it on completion, and the WhisperKit locator checks every CoreML file of the
# variant, so a half-fetched variant downloads again. FluidAudio likewise
# moves each file into place only once it is complete, and purges a model
# cache that fails to load. The build and every model the first attempt
# finished are kept, so the second only does the rest. Both attempts run
# inside the caller's step timeout: a first attempt that used most of it
# times out as before rather than retrying.
# The marker is only written once the suite has passed, so an incomplete
# cache is never recorded as warm.
#
# Not retried, because each would fail the same way again: a missing
# ModelPreloadTests.swift, a run that exited 0 without the suite passing (the
# filter matched nothing: renamed or removed), a compile or link error, and
# a run ended by a signal (a cancelled run or a step timeout). A failed
# package fetch fails before the suite too, but carries no compiler
# diagnostic, so it is retried. So is a failing preload assertion: a model
# that did not load because a download failed and one that did not load
# because of a bug print the same assertion, so the second attempt is what
# tells them apart, and its error says the cause is likely not the network.
#
# Every retry is a ::warning:: and a step-summary line, so a flaky network is
# noticed rather than hidden behind a green run.

set -uo pipefail

readonly attempts=2
readonly suite=ModelPreloadTests
backoff=${PREWARM_BACKOFF_SECONDS:-30}
marker=${PREWARM_MARKER:-}
if [ -n "${PREWARM_LOG:-}" ]; then log=$PREWARM_LOG
elif [ -n "${RUNNER_TEMP:-}" ]; then log=$RUNNER_TEMP/model-prewarm.log
else log=$(mktemp); trap 'rm -f "$log"' EXIT; fi

summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}

if [ ! -f "Tests/$suite.swift" ]; then
    echo "::error::Pre-warm expects $PWD/Tests/$suite.swift — moved or renamed?"
    exit 1
fi
if [ -n "$marker" ] && [ -f "$marker" ]; then
    echo "Models already pre-warmed for this key"
    exit 0
fi

attempt=1
while :; do
    swift test --filter "$suite" "$@" 2>&1 | tee "$log"
    statuses=("${PIPESTATUS[@]}")
    rc=${statuses[0]}
    # First, since a cancel that signals the group can take tee down too.
    if [ "$rc" -gt 128 ]; then
        echo "::error::Pre-warm was ended by signal $((rc - 128)); not retried."
        exit "$rc"
    fi
    if [ "${statuses[1]}" -ne 0 ]; then
        echo "::error::Pre-warm could not write its log to $log (disk full?); the run cannot be judged."
        exit 1
    fi
    if [ "$rc" -eq 0 ]; then
        if ! grep -q "Test Suite '$suite' passed" "$log"; then
            echo "::error::Pre-warm did not run $suite — has it been renamed or removed?"
            exit 1
        fi
        if [ -n "$marker" ]; then touch "$marker"; fi
        if [ "$attempt" -gt 1 ]; then
            summary "- Model pre-warm passed on attempt $attempt of $attempts."
        fi
        exit 0
    fi
    # A compiler diagnostic, or SwiftPM's summary of a failed compile, link or
    # emit-module command. Only "with exit code": "due to signal 9" is a
    # compiler killed under memory pressure, which a retry can get past.
    if grep -qE '\.swift:[0-9]+:[0-9]+: error:|error: [a-z-]+ command failed with exit code' "$log"; then
        echo "::error::Pre-warm failed to build; not retried."
        exit 1
    fi
    if [ "$attempt" -ge "$attempts" ]; then
        echo "::error::Pre-warm did not pass $suite in $attempts attempts (last exit $rc). Failing the same way twice points at the code or the models rather than the network; see the log above."
        exit 1
    fi
    echo "::warning::Model pre-warm attempt $attempt of $attempts failed (exit $rc); retrying in ${backoff}s in case it was a transient download error. The failed attempt's output is above."
    summary "- Model pre-warm attempt $attempt of $attempts failed (exit $rc) and was retried; see the step log."
    sleep "$backoff"
    attempt=$((attempt + 1))
done
