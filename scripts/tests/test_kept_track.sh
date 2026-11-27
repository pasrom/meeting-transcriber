#!/bin/bash
# Regression test for `kept_track` and `is_native_flac`, which the e2e lanes
# use to find a kept recording's tracks whether the app left them as WAV or
# converted them to FLAC after the job.
#
# Negative-capable: a hidden partial copy, a lookalike suffix and a track of
# another stem must not be found, the WAV must win where both are there, and a
# FLAC inside a CAF file must not read as native FLAC.
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

STEM="20270115_1200_weekly_sync_ab12cd34"

# Nothing there, or only what is not a track: nothing found, status 1.
touch "$TMP/.${STEM}_app.partial.flac" "$TMP/${STEM}_app.flac.partial" "$TMP/${STEM}_app_16k.wav" "$TMP/other_app.wav"
st=0; out="$(kept_track "$TMP" "$STEM" app)" || st=$?
expect_output nothing_kept_prints_nothing "" "$out"
expect_output nothing_kept_returns_1 1 "$st"

# The FLAC alone is found.
touch "$TMP/${STEM}_app.flac"
expect_output flac_alone_is_found "$TMP/${STEM}_app.flac" "$(kept_track "$TMP" "$STEM" app)"

# With both spellings, the WAV.
touch "$TMP/${STEM}_app.wav"
expect_output wav_wins_over_flac "$TMP/${STEM}_app.wav" "$(kept_track "$TMP" "$STEM" app)"

# Another track of the same stem is not taken for this one.
st=0; kept_track "$TMP" "$STEM" mic >/dev/null || st=$?
expect_output other_track_is_not_found 1 "$st"

# A glob stem finds the track of any stem, the WAV first.
rm "$TMP/other_app.wav"
expect_output glob_stem_finds_the_wav "$TMP/${STEM}_app.wav" "$(kept_track "$TMP" "*" app)"
rm "$TMP/${STEM}_app.wav"
expect_output glob_stem_finds_the_flac "$TMP/${STEM}_app.flac" "$(kept_track "$TMP" "*" app)"

# The marker decides: native FLAC starts with fLaC; a CAF (or anything else) does not.
printf 'fLaC\0\0\0\x22' >"$TMP/native.flac"
printf 'caff\0\1\0\0' >"$TMP/caf.flac"
is_native_flac "$TMP/native.flac" && ok native_flac_is_native || bad native_flac_is_native "rejected"
if is_native_flac "$TMP/caf.flac"; then bad caf_is_not_native "accepted"; else ok caf_is_not_native; fi
if is_native_flac "$TMP/missing.flac"; then bad missing_is_not_native "accepted"; else ok missing_is_not_native; fi

echo "$PASSED checks passed"
COMPLETED=1
