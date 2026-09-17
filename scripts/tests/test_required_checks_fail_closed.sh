#!/bin/bash
# Regression test: a required check may not pass by being skipped.
#
# Four checks are required to merge into main and nine to move a stable tag.
# All four of the first, and those same four among the nine, live in ci.yml and
# depend on `changes`, a one-minute job whose only purpose is to notice a
# docs-only pull request. When `changes` does not SUCCEED, its outputs are empty
# and a condition of the form `needs.changes.outputs.code == 'true'` is false,
# so the job is skipped -- and both branch protection and the tag ruleset count
# a skipped required check as a pass.
#
# So a timeout, an outage of the third-party filter action, or a GitHub API
# hiccup in that one minute turns those required checks green without one of
# them having run. The remedy is not a longer timeout, which only narrows the
# window: the condition has to tell "the filter said no code" apart from "the
# filter never answered", and run the full suite for the second.
#
# `!cancelled()` is load-bearing and not decoration. A job whose `needs` failed
# is skipped no matter what its `if` says, UNLESS that `if` calls a status
# function; without it the fail-closed arm below could never be reached.
#
# The condition is compared BYTE FOR BYTE against the one expected form rather
# than searched for tokens. Token matching cannot do this job: the shape
# `!cancelled() && needs.changes.result == 'success' && ...` contains both
# `needs.changes.result` and `cancelled()` and is exactly the hole this test
# exists to prevent. All guarded jobs carry the identical line, so the strict
# comparison costs nothing and is the only form that refuses the near-miss.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASSED=0
FAILED=0

ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; FAILED=1; }

# The one accepted condition. Single-quoted, so it is the literal text.
EXPECTED="\${{ !cancelled() && (needs.changes.result != 'success' || needs.changes.outputs.code == 'true') }}"

# The jobs that must carry it, named per workflow. An explicit list is what
# makes a job DISAPPEARING from the scan a failure: a parser that simply walks
# whatever it recognises reports "all found jobs pass" after a job is renamed,
# rewritten to the `needs: [changes]` list form, or given a trailing comment.
CI_GUARDED="lint analyze test audiotap-coverage"
RELEASE_GUARDED="build"

# The `if:` of job $2 in file $1, or the empty string. Jobs are two-space
# indented keys; a job's body runs to the next such key, which is what keeps
# this from reading the following job's condition.
job_condition() {
    awk -v want="$2" '
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            job = $1; sub(/:$/, "", job); next
        }
        /^[^[:space:]]/ { job = ""; next }
        job == want && /^[[:space:]]*if:/ && cond == "" {
            cond = $0; sub(/^[[:space:]]*if:[[:space:]]*/, "", cond)
        }
        END { print cond }
    ' "$1"
}

# Every job in $1 that declares ANY dependency on `changes`, in any spelling:
# the bare scalar, the `[changes]` list form, or a line carrying a comment.
# Deliberately broader than the expected spelling, so a job that moves to a
# form the scan above does not recognise still has to appear in the list below.
jobs_depending_on_changes() {
    awk '
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            job = $1; sub(/:$/, "", job); next
        }
        /^[^[:space:]]/ { job = ""; next }
        /^[[:space:]]*needs:[^#]*changes/ && job != "" { print job }
    ' "$1" | sort -u
}

check_workflow() {
    local wf="$1" expected_jobs="$2"
    local file="$ROOT/.github/workflows/$wf"
    [ -f "$file" ] || { bad "$wf" "workflow not found"; return; }

    local job cond actual
    for job in $expected_jobs; do
        cond="$(job_condition "$file" "$job")"
        if [ -z "$cond" ]; then
            bad "$wf:$job" "this job is required to carry the fail-closed condition but has no \`if:\` at all, or no longer exists under this name. If it was renamed, rename it here too; do not drop it."
            continue
        fi
        if [ "$cond" != "$EXPECTED" ]; then
            bad "$wf:$job" "its condition is not the fail-closed one, so a \`changes\` that times out or errors would skip this required check and branch protection would count the skip as a pass.
    expected: $EXPECTED
    actual:   $cond"
            continue
        fi
        ok "$wf:$job"
    done

    # The reverse direction: a NEW job that depends on `changes` and is not in
    # the list above is unreviewed, and a job that vanished from the file while
    # staying in the list is caught by the loop. Together these two make the
    # list and the workflow hold each other accountable.
    actual="$(jobs_depending_on_changes "$file" | tr '\n' ' ')"
    local expected_sorted
    expected_sorted="$(printf '%s\n' $expected_jobs | sort -u | tr '\n' ' ')"
    if [ "$actual" != "$expected_sorted" ]; then
        bad "$wf" "the jobs depending on \`changes\` are not the ones this test guards. If a job was added, give it the fail-closed condition and list it here; if one was removed, remove it here.
    guarded:  $expected_sorted
    in file:  $actual"
    else
        ok "$wf:job-list"
    fi
}

check_workflow ci.yml "$CI_GUARDED"
check_workflow release.yml "$RELEASE_GUARDED"

# The two sanitizer legs are required to move a stable tag and depend on a
# `changes` job of their own, in quality-and-safety.yml, through conditions
# that carry no status function -- the same construction as above. They are not
# fixed the same way, because their conditions also carry the fork exclusion
# and rewriting them risks drifting from the mirror in `sanitizer-gate`. What
# closes the hole there is `sanitizer-gate` itself: it runs on `always()` and
# fails when the `changes` it needed did not succeed, so a skipped leg cannot
# pass unnoticed. That protection is load-bearing and untested, which is what
# this section fixes. It is not a substitute for making `sanitizer-gate` a
# required check, which it is not today.
qs="$ROOT/.github/workflows/quality-and-safety.yml"
if [ ! -f "$qs" ]; then
    bad "quality-and-safety.yml" "workflow not found"
else
    gate_cond="$(job_condition "$qs" "sanitizer-gate")"
    if [ "$gate_cond" != "always()" ]; then
        bad "quality-and-safety.yml:sanitizer-gate" "must run on always(), or a failed \`changes\` skips the very job that reports the skipped legs: $gate_cond"
    else
        ok "quality-and-safety.yml:sanitizer-gate runs on always()"
    fi

    if grep -q 'CHANGES_RESULT: ${{ needs.changes.result }}' "$qs" \
        && grep -qE 'if \[ "\$CHANGES_RESULT" != "success" \]; then' "$qs"; then
        ok "quality-and-safety.yml:sanitizer-gate inspects the changes result"
    else
        bad "quality-and-safety.yml:sanitizer-gate" "no longer fails when the \`changes\` job it needs did not succeed. Without that arm the two sanitizer legs skip through \`needs\`, and both are required checks that count a skip as a pass."
    fi

    # The arm has to set the failure flag, not only print a row.
    if awk '/if \[ "\$CHANGES_RESULT" != "success" \]; then/,/fi/' "$qs" | grep -q 'failed=1'; then
        ok "quality-and-safety.yml:sanitizer-gate fails on that result"
    else
        bad "quality-and-safety.yml:sanitizer-gate" "reports a non-successful \`changes\` but does not set the failure flag, so the gate stays green while nothing was checked."
    fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "$PASSED checks passed"
else
    echo "Some checks FAILED."
fi
exit "$FAILED"
