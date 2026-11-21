#!/bin/bash
# Regression test for the suppressed-segment check of e2e-app.sh's --echo-bleed
# lane: echo_suppressed_violation, applied with the lane's own floor.
#
# The floor is read out of e2e-app.sh and held against the count the lane
# measures, written down here on its own, so a floor moved away from the
# measurement fails this test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

# Set at the very end; see test_kill_and_verify_gone.sh for why a `set -u`
# abort would otherwise read as a pass.
COMPLETED=0
cleanup() {
    local rc=$?
    if [ "$COMPLETED" -ne 1 ]; then
        echo "FAIL: the test aborted before reaching its end" >&2
        exit 1
    fi
    exit "$rc"
}
trap cleanup EXIT
PASSED=0
ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }

# What every measured run of the lane removed (see the constant's comment).
MEASURED=3
FLOOR="$(sed -n 's/^_ECHO_BLEED_MIN_SUPPRESSED=\([0-9][0-9]*\)$/\1/p' "$ROOT/scripts/e2e-app.sh")"
[ -n "$FLOOR" ] || bad the_lane_floor_exists "_ECHO_BLEED_MIN_SUPPRESSED not found in e2e-app.sh"
# shellcheck disable=SC2015 # bad exits, so it never runs after ok
[ "$FLOOR" -eq "$MEASURED" ] && ok the_floor_is_the_measurement \
    || bad the_floor_is_the_measurement "_ECHO_BLEED_MIN_SUPPRESSED is $FLOOR, the lane measures $MEASURED"

# The floor has to reach the check, and the check has to stop the lane: a
# literal at the call site would leave the constant read above at its value and
# the lane at another. Anchored on the whole assignment line, so a call
# commented out, or replaced by `violation=""` with the old text left in a
# comment, fails here; and the two lines after it must be the test of that
# variable and its `|| fail`, so `true || fail` or `|| true` fails too.
LANE="$ROOT/scripts/e2e-app.sh"
# shellcheck disable=SC2016 # the quotes are the literal text
CALL="$(grep -nxE '[[:space:]]*violation="\$\(echo_suppressed_violation "\$final" "\$_ECHO_BLEED_MIN_SUPPRESSED"\)"' "$LANE" || true)"
[ -n "$CALL" ] || bad the_lane_passes_its_floor "run_echo_bleed does not pass _ECHO_BLEED_MIN_SUPPRESSED"
ok the_lane_passes_its_floor
CALL_LINE="${CALL%%:*}"
GUARD="$(sed -n "$(( CALL_LINE + 1 ))p" "$LANE")"
STOP="$(sed -n "$(( CALL_LINE + 2 ))p" "$LANE")"
# shellcheck disable=SC2015,SC2016 # bad exits; the quotes are the literal text
grep -qxE '[[:space:]]*\[ -z "\$violation" \] \\' <<<"$GUARD" \
    && grep -qE '^[[:space:]]*\|\| fail ' <<<"$STOP" \
    && ok the_lane_stops_on_a_violation \
    || bad the_lane_stops_on_a_violation "the lines after the call do not fail on it:
$GUARD
$STOP"

job() { jq -nc --argjson n "$1" '{state: "done", echo: {detected: true, suppressedSegments: $n}}'; }
# shellcheck disable=SC2015 # bad exits, so it never runs after ok
passes() { local out; out="$(echo_suppressed_violation "$2" "$FLOOR")"; [ -z "$out" ] && ok "$1" || bad "$1" "'$out'"; }
# fails <name> <record> <reason> [floor]: the violation names the expected
# reason, so a case cannot pass on a different branch.
fails() {
    local out
    out="$(echo_suppressed_violation "$2" "${4-$FLOOR}")"
    case "$out" in
        *"$3"*) ok "$1" ;;
        *) bad "$1" "expected '$3', got '$out'" ;;
    esac
}

passes measured_count_passes "$(job "$MEASURED")"
# One segment short of what every run removed is a regression, not noise.
fails one_below_the_measured_count_fails "$(job $(( MEASURED - 1 )))" "below the floor"
fails missing_count_fails '{"state":"done","echo":{"detected":true}}' "no suppressedSegments count"
# jq orders every string above every number.
fails non_numeric_count_fails '{"state":"done","echo":{"suppressedSegments":"0"}}' "no suppressedSegments count"
# Empty output reads as a pass, so neither a record jq cannot parse nor an
# empty one, which jq reads as no input at all, may give it.
fails unreadable_record_fails 'not json' "could not read the job record"
# Valid JSON in the wrong shape, and a verdict followed by junk, give that one
# reason too, not a partial verdict with the error appended.
fails misshapen_record_fails '{"echo":"x"}' "could not read the job record"
# shellcheck disable=SC2015 # bad exits, so it never runs after ok
out="$(echo_suppressed_violation '{"echo":{"suppressedSegments":1}} junk' "$FLOOR")"
[ "$out" = 'jq could not read the job record (not JSON, or not shaped like a job)' ] \
    && ok trailing_junk_gives_one_reason || bad trailing_junk_gives_one_reason "'$out'"
fails empty_record_fails '' "is empty"
# A broken floor is the driver's fault and must not be reported as the app's.
fails bad_floor_is_named "$(job "$MEASURED")" "is not a count" ""

echo "$PASSED checks passed"
COMPLETED=1
