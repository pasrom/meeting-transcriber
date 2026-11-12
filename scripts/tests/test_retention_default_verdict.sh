#!/bin/bash
# Regression test for `retention_default_verdict`, which the meeting lanes of
# e2e-app.sh use to assert that a finished job keeps its recording while
# recording retention is off (issue #723).
#
# The verdict is negative-capable: a recording deleted after the job finished
# must read as `deleted`, not as `kept`, and only the spellings the app reads
# as on may skip the check. A helper that looked once and never again, or that
# skipped on any value, would turn the lane's guard into a pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

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

expect_output() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then ok "$name"; else bad "$name" "expected '$expected', got '$actual'"; fi
}

MIX="$TMP/20270115_1200_sync_mix.wav"

# Unset (the default) and explicitly off both require the recording to stay.
touch "$MIX"
expect_output unset_and_present_is_kept kept "$(retention_default_verdict "" "$MIX" 0)"
expect_output off_and_present_is_kept kept "$(retention_default_verdict 0 "$MIX" 0)"

# Gone during the grace period: the second look must catch it.
( sleep 0.3; rm -f "$MIX" ) &
expect_output deleted_after_done_is_caught deleted "$(retention_default_verdict "" "$MIX" 1)"
wait

# Never there: told apart from deleted, so the lane names the right cause.
expect_output absent_up_front_is_missing missing "$(retention_default_verdict "" "$MIX" 0)"

# Every value the app reads as on skips, whatever the file does: yes/true in
# any case and any integer but 0 (`UserDefaults.flag`).
for on in 1 2 -1 YES yes true TRUE; do
    expect_output "on_as_${on}_skips" skip "$(retention_default_verdict "$on" "$MIX" 0)"
done

# Values the app reads as off or as unset do not skip.
for off in 0 no NO false maybe 1x -; do
    expect_output "off_as_${off}_does_not_skip" missing "$(retention_default_verdict "$off" "$MIX" 0)"
done

echo "$PASSED checks passed"
COMPLETED=1
