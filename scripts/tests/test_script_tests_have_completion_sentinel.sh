#!/bin/bash
# Regression test: a script test that can abort with exit 0 carries the
# completion sentinel.
#
# On bash 3.2, the system bash these tests run under, an unbound-variable abort
# exits 0 when the script combines `set -e`, `set -u` and an EXIT trap: the
# trap sees `$? = 0` and the script ends with that. A typo in a variable name
# then reads as a pass that ran none of the remaining cases. The affected
# files set `COMPLETED=1` as their last step and their trap fails without it
# (see test_kill_and_verify_gone.sh). This test finds a file that has the
# three ingredients and no sentinel, so a new test cannot miss it unnoticed.
#
# No EXIT trap here on purpose: without one, an abort of this file exits 1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Prints the file name when it needs the sentinel and lacks it. Errexit and
# nounset are recognised as short flags, as `-o` names and on the shebang line;
# only top-level `set` lines count, since a `set -euo` inside a quoted
# `bash -c` belongs to a child. The sentinel counts only when the file both
# sets it and reads it, which is what the trap has to do.
# Not seen from here: an option switched on by a sourced file.
missing_sentinel() {
    local f="$1"
    grep -qE '^(set -[a-zA-Z]*e|set .*-o errexit|#!.*bash.* -[a-zA-Z]*e)' "$f" || return 0
    grep -qE '^(set -[a-zA-Z]*u|set .*-o nounset|#!.*bash.* -[a-zA-Z]*u)' "$f" || return 0
    grep -qE '^[[:space:]]*trap[[:space:]].*[[:space:]](EXIT|0)([[:space:]]|$)' "$f" || return 0
    if grep -qE '^COMPLETED=1$' "$f" && grep -qE '\$\{?COMPLETED' "$f"; then
        return 0
    fi
    echo "$f"
}

# Control: the detector flags a file with the three ingredients and no sentinel,
# and lets the same file through once it has one.
probe="$(mktemp)"
printf 'set -o errexit -o nounset\ntrap cleanup 0\n' > "$probe"
flagged="$(missing_sentinel "$probe")"
printf 'COMPLETED=1\n' >> "$probe"
set_only="$(missing_sentinel "$probe")"
# The probe file needs the literal text, not this script's value.
# shellcheck disable=SC2016
printf '[ "$COMPLETED" -eq 1 ] || exit 1\n' >> "$probe"
cleared="$(missing_sentinel "$probe")"
rm -f "$probe"
if [ -z "$flagged" ] || [ -z "$set_only" ] || [ -n "$cleared" ]; then
    echo "detector_control ... FAIL: flagged='$flagged' set_only='$set_only' cleared='$cleared'"
    exit 1
fi
echo "detector_control ... PASS"

offenders=""
count=0
for f in "$ROOT"/scripts/tests/test_*.sh; do
    count=$(( count + 1 ))
    hit="$(missing_sentinel "$f")"
    [ -z "$hit" ] || offenders="$offenders ${hit##*/}"
done
[ "$count" -gt 0 ] || { echo "no script tests found ... FAIL"; exit 1; }

if [ -n "$offenders" ]; then
    echo "script_tests_have_completion_sentinel ... FAIL:$offenders"
    exit 1
fi
echo "script_tests_have_completion_sentinel ... PASS ($count files)"
