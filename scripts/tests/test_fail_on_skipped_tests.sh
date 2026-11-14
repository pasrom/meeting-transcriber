#!/bin/bash
# Regression test for scripts/ci/fail-on-skipped-tests.sh, the check that
# keeps a skipped test in the E2E lane from reading as a green run.
#
# Both directions matter: an unexpected skip must fail, and a run whose only
# skips are the allowed classes must pass. A log that proves nothing (empty,
# unreadable) must fail rather than pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/ci/fail-on-skipped-tests.sh"

TMP="$(mktemp -d)"
# Set at the very end; see test_kill_and_verify_gone.sh for why a `set -u`
# abort would otherwise read as a pass.
COMPLETED=0
cleanup() {
    local rc=$?
    rm -rf "$TMP"
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

# Lines as `swift test` prints them, behind a prefix: buffered test output can
# land in front of such a line, so the check must not anchor on the line start.
passed_line="2026-01-01T00:00:00.0000000Z Test Case '-[AppTests.EngineE2ETests testTranscribes]' passed (5.882 seconds)."
skip_line() {
    echo "2026-01-01T00:00:00.0000000Z Test Case '-[AppTests.$1 $2]' skipped (0.002 seconds)."
}

run() {
    status=0
    out="$(bash "$CHECK" "$@" 2>&1)" || status=$?
}

# No skip at all: pass.
echo "$passed_line" > "$TMP/clean.log"
run "$TMP/clean.log"
[ "$status" -eq 0 ] && grep -qx 'no unexpected skips' <<<"$out" \
    && ok clean_run_passes || bad clean_run_passes "status $status: '$out'"

# One skipped test, nothing allowed: fail and name the test.
{ echo "$passed_line"; skip_line EngineE2ETests testNeedsModel; } > "$TMP/skip.log"
run "$TMP/skip.log"
[ "$status" -eq 1 ] && grep -q '^::error title=Test skipped::EngineE2ETests.testNeedsModel ' <<<"$out" \
    && ok unexpected_skip_fails || bad unexpected_skip_fails "status $status: '$out'"

# The same skip, with its class allowed: pass, and the skip is still listed.
run "$TMP/skip.log" EngineE2ETests
[ "$status" -eq 0 ] && grep -qx 'expected skip: EngineE2ETests.testNeedsModel' <<<"$out" \
    && ok allowed_skip_passes || bad allowed_skip_passes "status $status: '$out'"

# An allowed class does not cover another class, also not one it prefixes.
{ echo "$passed_line"; skip_line EngineE2ETests testNeedsModel; skip_line EngineE2ETestsExtra testOther; } > "$TMP/two.log"
run "$TMP/two.log" EngineE2ETests
[ "$status" -eq 1 ] && grep -q '::EngineE2ETestsExtra.testOther ' <<<"$out" \
    && ! grep -q '::EngineE2ETests.testNeedsModel ' <<<"$out" \
    && grep -qx '1 test(s) skipped unexpectedly' <<<"$out" \
    && ok allowance_is_per_class || bad allowance_is_per_class "status $status: '$out'"

# A log with skips only shows no test ran: fail, even with the class allowed.
skip_line EngineE2ETests testNeedsModel > "$TMP/only-skips.log"
run "$TMP/only-skips.log" EngineE2ETests
[ "$status" -eq 1 ] && grep -q 'holds no passed test' <<<"$out" \
    && ok log_without_a_passed_test_fails || bad log_without_a_passed_test_fails "status $status: '$out'"

# An empty log and a missing log fail.
: > "$TMP/empty.log"
run "$TMP/empty.log"
[ "$status" -eq 1 ] && ok empty_log_fails || bad empty_log_fails "status $status: '$out'"
run "$TMP/absent.log"
[ "$status" -eq 1 ] && grep -q 'cannot read the test log' <<<"$out" \
    && ok missing_log_fails || bad missing_log_fails "status $status: '$out'"

# No argument is a usage error, not a pass.
run
[ "$status" -eq 2 ] && ok no_argument_is_a_usage_error || bad no_argument_is_a_usage_error "status $status: '$out'"

echo "$PASSED passed"
COMPLETED=1
