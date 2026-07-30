#!/bin/bash
# Regression test for the e2e transcript language gate.
#
# The gate exists to reject an English hallucination or garbage that slipped
# past the >100-byte size check. It has to do that while accepting whatever
# slice of the meeting the live lane happened to capture: recording starts only
# once the app has DETECTED the meeting, so the opening seconds are never in the
# transcript, and which sentences land varies run to run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSED=0

check() {
    local name="$1" expected="$2" body="$3"
    local file="$TMP/${name}.txt"
    printf '%s\n' "$body" > "$file"
    local actual=pass
    transcript_is_german "$file" >/dev/null 2>&1 || actual=fail
    if [ "$actual" = "$expected" ]; then
        echo "$name ... PASS"
        PASSED=$(( PASSED + 1 ))
    else
        echo "$name ... FAIL (expected $expected, got $actual)"
        exit 1
    fi
}

# What the live lane actually produces. Taken from a real CI transcript: the
# capture starts mid-meeting, so none of the fixture's opening words are in it.
# The old content-keyword gate scored this 1/5 against a floor of 2 and failed
# the lane, with nothing wrong in the recording or the transcription.
check live_capture_slice pass \
"[00:00] S1: Ich kann berichten, dass die Entwicklung gut voranschreitet.
[00:10] S1: Wir haben letzte Woche drei wichtige Features abgeschlossen.
[00:21] S1: Ja, wir haben noch ein Problem mit der Datenbankanbindung."

# The other slice, containing the fixture's scripted sentences.
check fixture_opening_slice pass \
"[00:00] S1: Guten Tag, willkommen zum Projekt Meeting.
[00:04] S2: Danke. Ich möchte den aktuellen Status berichten.
[00:09] S2: Die Entwicklung läuft nach Plan. Wir sind im Zeitplan."

# The failure this gate is for: the engine ran on the wrong language and
# produced fluent English.
check english_hallucination fail \
"[00:00] S1: I can report that development is progressing well.
[00:10] S1: We completed three important features last week.
[00:21] S1: There is still a problem with the database connection."

# Substring matching would score this as German: 'submit' contains 'mit',
# 'listed' contains 'ist', 'sound' contains 'und', 'diet' contains 'die'.
check english_containing_german_substrings fail \
"[00:00] S1: Please submit the listed items and the sound diet plan.
[00:10] S1: The auditor understood the founder was under a bundle."

check garbage fail "[00:00] S1: ▓▒░ ┤├ ╪╪╪ ░▒▓"

check empty_ish fail "[00:00] S1:"

echo "All $PASSED tests passed."
