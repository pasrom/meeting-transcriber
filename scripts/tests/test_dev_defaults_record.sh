#!/bin/bash
# Regression test for dev_defaults_record, the snapshot the E2E drivers restore
# their settings from. write_dev_default writes the container plist too when
# one exists, so a snapshot of the standard plist alone leaves the lane's values
# in the container on exit. Each plist must come back to its OWN earlier value,
# and a trap that fires before the snapshot must not delete anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"
# shellcheck source=../lib/bundle-ids.sh
source "$ROOT/scripts/lib/bundle-ids.sh"

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
expect() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then ok "$name"; else bad "$name" "expected '$expected', got '$actual'"; fi
}

# Both plist locations point into the temp dir, so the real dev bundle's
# settings are never a participant. Not through a throwaway $HOME: a
# `defaults write` to `<home>/Library/Preferences/<id>.plist` under a home that
# is not the user's was seen to write nothing, and the snapshot held nothing.
BUNDLE="test.e2e.bundle"
STD="$TMP/standard/$BUNDLE.plist"
CTR="$TMP/container/$BUNDLE.plist"
dev_standard_plist() { printf '%s' "$STD"; }
dev_container_plist() { printf '%s' "$CTR"; }
mkdir -p "$(dirname "$STD")"
read_key() { /usr/bin/defaults read "$1" "$2" 2>/dev/null || echo absent; }

# --- no container: the standard plist alone ----------------------------------

/usr/bin/defaults write "$STD" autoWatch -bool false
/usr/bin/defaults write "$STD" transcriptionEngine -string whisperKit
REC="$TMP/record-std"
dev_defaults_record "$REC" "$BUNDLE" autoWatch transcriptionEngine recordOnly
expect only_the_standard_plist_is_recorded "3/$STD" \
    "$(grep -c . "$REC")/$(cut -d $'\037' -f1 "$REC" | sort -u)"
write_dev_default "$BUNDLE" autoWatch true bool
write_dev_default "$BUNDLE" transcriptionEngine parakeet string
write_dev_default "$BUNDLE" recordOnly true bool
defaults_restore_record "$REC"
expect standard_values_come_back "0/whisperKit/absent" \
    "$(read_key "$STD" autoWatch)/$(read_key "$STD" transcriptionEngine)/$(read_key "$STD" recordOnly)"
expect no_container_is_created "no" "$([ -e "$CTR" ] && echo yes || echo no)"

# --- with a container: each plist back to its own value ----------------------

mkdir -p "$(dirname "$CTR")"
/usr/bin/defaults write "$CTR" autoWatch -bool true
/usr/bin/defaults write "$CTR" recordOnly -bool false
REC="$TMP/record-both"
dev_defaults_record "$REC" "$BUNDLE" autoWatch transcriptionEngine recordOnly
expect both_plists_are_recorded 6 "$(grep -c . "$REC")"
write_dev_default "$BUNDLE" autoWatch false bool
write_dev_default "$BUNDLE" transcriptionEngine parakeet string
write_dev_default "$BUNDLE" recordOnly true bool
expect the_lane_wrote_the_container_too "parakeet" "$(read_key "$CTR" transcriptionEngine)"
defaults_restore_record "$REC"
expect standard_comes_back_to_its_own_values "0/whisperKit/absent" \
    "$(read_key "$STD" autoWatch)/$(read_key "$STD" transcriptionEngine)/$(read_key "$STD" recordOnly)"
expect container_comes_back_to_its_own_values "1/absent/0" \
    "$(read_key "$CTR" autoWatch)/$(read_key "$CTR" transcriptionEngine)/$(read_key "$CTR" recordOnly)"

# --- a trap that fires before the snapshot -----------------------------------

# The drivers arm their exit trap before they take the snapshot. A restore of a
# record that was never written must leave every key alone.
rc=0; defaults_restore_record "$TMP/never-written" || rc=$?
expect restore_before_the_snapshot_is_a_no_op "0/0/whisperKit" \
    "$rc/$(read_key "$STD" autoWatch)/$(read_key "$STD" transcriptionEngine)"

# A value a record line cannot carry refuses the record, so the caller can stop
# before it changes a value it could not put back.
/usr/bin/defaults write "$STD" nested -dict a b
rc=0; dev_defaults_record "$TMP/record-refused" "$BUNDLE" nested 2>/dev/null || rc=$?
expect a_value_a_record_cannot_carry_is_refused 1 "$rc"

COMPLETED=1
echo "all $PASSED passed"
