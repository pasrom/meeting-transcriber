#!/bin/bash
# Fails when an XCTest run skipped a test nobody expected to skip.
#
#   fail-on-skipped-tests.sh <swift-test-log> [allowed-class ...]
#
# The E2E lane gates its tests behind XCTSkip, so a test that stops running
# there (a missing model, a lost opt-in variable, a new gate) still reports a
# green run: `swift test` exits 0 on a skip. This reads the log of such a run
# and turns every skip into a failure, except for the test classes named as
# arguments, which are known to run in another job.
#
# A log without a single passed test fails too: an empty or truncated log
# would otherwise read as "nothing skipped".
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <swift-test-log> [allowed-class ...]" >&2
    exit 2
fi
LOG="$1"
shift

if [ ! -r "$LOG" ]; then
    echo "::error title=Skip check::cannot read the test log $LOG"
    exit 1
fi

# "Test Case '-[Module.Class testName]' skipped (0.002 seconds)." -> "Class testName"
finished() {
    sed -n "s/^.*Test Case '-\[[^.]*\.\([^ ]*\) \([^]]*\)\]' $1 (.*\$/\1 \2/p" "$LOG"
}

if [ -z "$(finished passed)" ]; then
    echo "::error title=Skip check::the test log holds no passed test, so it cannot show that nothing was skipped"
    exit 1
fi

unexpected=0
while read -r class name; do
    [ -n "$class" ] || continue
    allowed=0
    for a in "$@"; do
        if [ "$a" = "$class" ]; then
            allowed=1
            break
        fi
    done
    if [ "$allowed" -eq 1 ]; then
        echo "expected skip: $class.$name"
    else
        echo "::error title=Test skipped::$class.$name was skipped in a lane that is meant to run it"
        unexpected=$(( unexpected + 1 ))
    fi
done < <(finished skipped)

if [ "$unexpected" -gt 0 ]; then
    echo "$unexpected test(s) skipped unexpectedly"
    exit 1
fi
echo "no unexpected skips"
