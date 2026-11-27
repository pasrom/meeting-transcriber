#!/bin/bash
# Regression test for live_transcript_violation, the check the live-captions
# lane applies to the live transcript file its recording wrote.
#
# Hand-made files stand in for the app's: a well-formed one must pass, and each
# way a finished file can be wrong must fail with a reason that names it.
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

START='{"at":"2026-11-27T13:30:05Z","type":"start","v":1}'
FINAL='{"at":"2026-11-27T13:30:41Z","channel":"app","offset":36.2,"seq":1,"speaker":"Remote","text":"Speaker A opens the meeting","type":"final","v":1}'
SPEAKER='{"seq":1,"speaker":"Speaker A","type":"speaker","v":1}'
END='{"at":"2026-11-27T14:02:10Z","type":"end","v":1}'

# file <name> <line>...: a transcript with those lines, each ended by a newline.
file() {
    local name="$1"
    shift
    printf '%s\n' "$@" >"$TMP/$name"
    printf '%s' "$TMP/$name"
}

passes() {
    local out
    out="$(live_transcript_violation "$2")"
    [ -z "$out" ] && ok "$1" || bad "$1" "unexpected violation: $out"
}

fails() {
    local out
    out="$(live_transcript_violation "$2")"
    [[ "$out" == *"$3"* ]] && ok "$1" || bad "$1" "expected a reason containing '$3', got '$out'"
}

passes well_formed_file_passes "$(file good "$START" "$FINAL" "$SPEAKER" "$END")"
fails missing_end_fails "$(file no-end "$START" "$FINAL")" "not end"
fails broken_line_is_named "$(file broken "$START" '{"type":"fin' "$FINAL" "$END")" "line 2 is not a JSON object"
fails missing_start_fails "$(file no-start "$FINAL" "$END")" "not start"
fails no_final_text_fails "$(file empty-final "$START" '{"type":"final","text":"","seq":1,"v":1}' "$END")" "no final event carries text"
fails other_version_fails "$(file v2 "$START" '{"type":"final","text":"hi","seq":1,"v":2}' "$END")" "line 2 has v 2"
fails missing_version_fails "$(file no-v "$START" '{"type":"final","text":"hi","seq":1}' "$END")" "line 2 has v null"
fails missing_file_fails "$TMP/absent.jsonl" "missing or empty"
: >"$TMP/empty.jsonl"
fails empty_file_fails "$TMP/empty.jsonl" "missing or empty"
# A short write leaves a fragment ended by a line break: the line is named.
fails fragment_after_end_is_named "$(file fragment "$START" "$FINAL" '{"at":"2026-11-27T14:02:10Z","ty')" "line 3 is not a JSON object"

echo "$PASSED checks passed"
COMPLETED=1
