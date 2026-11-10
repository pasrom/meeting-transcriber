#!/bin/bash
# Regression test for the menu-bar badge collection the e2e-app.sh lanes use.
#
# The lanes note /state.badge on every snapshot they already read and assert
# on the set afterwards: `recording` must have been seen in a recording lane,
# and no processing badge in a record-only one. So the collection must keep
# each value once whatever order it arrives in, ignore a snapshot without the
# field instead of recording an empty value, and never fail, since it runs
# inside poll predicates whose status decides the poll.
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

E2E_BADGES_SEEN=""
for b in inactive recording recording transcribing recording diarizing; do
    STATE_BODY="{\"badge\": \"$b\", \"watchState\": \"recording\"}"
    badge_note
done
[ "$E2E_BADGES_SEEN" = "inactive recording transcribing diarizing" ] \
    && ok each_value_once_in_first_seen_order || bad each_value_once_in_first_seen_order "'$E2E_BADGES_SEEN'"

badge_seen recording && ok seen_value_is_found || bad seen_value_is_found "$E2E_BADGES_SEEN"
! badge_seen processing && ok unseen_value_is_not_found || bad unseen_value_is_not_found "$E2E_BADGES_SEEN"
# Whole values only: `user` must not match a seen `userAction`.
E2E_BADGES_SEEN="userAction"
! badge_seen user && ok matches_whole_values || bad matches_whole_values "$E2E_BADGES_SEEN"

# A snapshot passed as an argument rather than through STATE_BODY (a reader
# that ran in a command substitution), one without the field, one that is not
# JSON at all, and no snapshot: none fails, only the first adds.
E2E_BADGES_SEEN=""
# shellcheck disable=SC2034 # read by badge_note when no argument is given
STATE_BODY='{"badge": "inactive"}'
badge_note '{"badge": "done"}' && badge_note '{"watchState": "idle"}' && badge_note 'not json' \
    && ok never_fails || bad never_fails "a call returned non-zero"
[ "$E2E_BADGES_SEEN" = "done" ] && ok argument_wins_and_absent_adds_nothing || bad argument_wins_and_absent_adds_nothing "'$E2E_BADGES_SEEN'"
unset STATE_BODY
E2E_BADGES_SEEN=""
badge_note && [ -z "$E2E_BADGES_SEEN" ] && ok no_snapshot_at_all || bad no_snapshot_at_all "'$E2E_BADGES_SEEN'"

E2E_BADGES_SEEN="recording transcribing done"
[ "$(badges_seen_among diarizing processing transcribing "done")" = "transcribing done" ] \
    && ok lists_the_seen_ones_of_a_set || bad lists_the_seen_ones_of_a_set "'$(badges_seen_among diarizing processing transcribing "done")'"
[ -z "$(badges_seen_among diarizing processing)" ] && ok none_of_a_set_is_empty || bad none_of_a_set_is_empty "not empty"

COMPLETED=1
echo "All $PASSED tests passed."
