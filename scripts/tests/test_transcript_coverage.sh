#!/bin/bash
# Regression test for the e2e transcript time-coverage gate.
#
# The live lanes require a transcript to reach a floor in time, so a pipeline
# that transcribes only the opening of a recording stops passing on a
# transcript that is German and long enough. The app writes each line as
# `[MM:SS] Label: text` below an hour and `[H:MM:SS] ...` from an hour on
# (TimestampedSegment), so the parser has to read both and must not be fooled by
# a bracketed time inside the spoken text. A line is a BLOCK, consecutive
# segments of one speaker merged (mergeConsecutiveSpeakers), and keeps only the
# first one's start, so a complete transcript whose diarization heard one
# voice is a single line stamped [00:00]. The helper therefore estimates where
# each block ends from its word count, at four words a second, which is faster
# than anyone speaks and so never overstates the coverage.
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

# check <name> <expected seconds | none> <body>
check() {
    local name="$1" expected="$2" body="$3" file="$TMP/$1.txt" got status=0
    printf '%s\n' "$body" >"$file"
    got="$(transcript_covered_seconds "$file")" || status=$?
    if [ "$expected" = none ]; then
        [ "$status" -ne 0 ] && [ -z "$got" ] && ok "$name" || bad "$name" "expected no stamp, got '$got' (status $status)"
    else
        [ "$status" -eq 0 ] && [ "$got" = "$expected" ] && ok "$name" || bad "$name" "expected $expected, got '$got' (status $status)"
    fi
}

# 41 s plus nine words, two seconds at four a second.
check minutes_and_seconds 43 \
"[00:00] S1: Guten Tag, willkommen zum Projekt Meeting.
[00:12] S2: Danke. Ich möchte den aktuellen Status berichten.
[00:41] S1: Ja, wir haben noch ein Problem mit der Datenbankanbindung."

check past_an_hour 3726 \
"[59:58] S1: Noch ein Punkt.
[1:02:05] S2: Dann machen wir Schluss."

# The latest block end, not the last line's: a merged dual-track transcript
# is not promised to be in time order.
check largest_not_last_line 76 \
"[01:15] R_SPEAKER_00: Das ist der letzte Satz.
[00:30] M_SPEAKER_00: Und das kam vorher."

# A time inside the spoken text is not a segment stamp.
check stamp_in_text_is_ignored 6 \
"[00:05] S1: Wir treffen uns um [10:30] im Büro."

# One voice for the whole meeting: a single block stamped at the start, whose
# 120 words put its end at 30 s at least.
check one_block_for_the_whole_meeting 30 \
"[00:00] SPEAKER_0: $(for _ in $(seq 1 20); do printf 'wir haben noch ein Problem hier '; done)"

# What a truncated transcript looks like: the opening sentence only.
check opening_sentence_only 1 \
"[00:00] S1: Guten Tag, willkommen zum Projekt Meeting."

check no_stamp none "S1: Kein Zeitstempel hier."
check empty_file none ""
got="" status=0
got="$(transcript_covered_seconds "$TMP/missing_file.txt")" || status=$?
[ "$status" -ne 0 ] && [ -z "$got" ] && ok missing_file_reports_none || bad missing_file_reports_none "got '$got' (status $status)"

COMPLETED=1
echo "All $PASSED tests passed."
