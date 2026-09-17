#!/bin/bash
# Regression test: every SwiftPM package in this repository that declares a
# test target must have those tests run by CI, and mt-cli's must run inside a
# REQUIRED check.
#
# `tools/mt-cli` carried 31 tests that no gate compiled. `swift build` does not
# build a test target, and the only gate that touched the test FILES was
# scripts/lint.sh, which formats and lints them without ever type-checking them
# against the code they test. Other lanes build the package, none with
# `swift test` or `--build-tests`. So the tests were written, reviewed,
# committed and counted, and could not have failed.
#
# The general check below exists because naming one package would fix the
# instance and not the class: the next `tools/*` package to grow a test target
# would repeat it exactly, and nothing would say so.
#
# Where they run matters as much as that they run. `audiotap-coverage` is the
# obvious template and it is NOT a required check: it leans on
# `cancel-on-failure`, which cancels sibling jobs still in flight and cannot
# retract a conclusion a job already reported. A failure arriving after the
# required legs have gone green therefore blocks nothing. So the mt-cli tests
# hang off `test`, which branch protection requires.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/ci-yaml.sh
source "$ROOT/scripts/lib/ci-yaml.sh"

CI="$ROOT/.github/workflows/ci.yml"
REQUIRED_JOB="test"
STEP_RUN="cd tools/mt-cli && swift test"
PASSED=0
FAILED=0

ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; FAILED=1; }
summary() {
    echo
    if [ "$FAILED" -eq 0 ]; then echo "$PASSED checks passed"; else echo "Some checks FAILED."; fi
    exit "$FAILED"
}

if [ ! -f "$CI" ]; then
    bad "ci.yml exists" "the workflow this test reads is gone; a missing file must not read as nothing to check"
    summary
fi

# 1. Every package that declares a test target is run somewhere in ci.yml.
#    Deliberately not restricted to mt-cli: the defect being guarded is
#    "a test target nobody builds", and that is a property of the repository.
found_any=0
while IFS= read -r manifest; do
    pkg_dir="$(dirname "$manifest")"
    rel="${pkg_dir#"$ROOT"/}"
    grep -q 'testTarget' "$manifest" || continue
    found_any=1
    if ci_without_comments "$CI" | grep -q "cd $rel && swift test"; then
        ok "ci.yml runs the tests of $rel"
    else
        bad "ci.yml runs the tests of $rel" "this package declares a test target that no job in ci.yml builds. \`swift build\` does not build test targets, so those tests cannot fail and cannot be trusted."
    fi
done <<EOF
$(find "$ROOT/app" "$ROOT/tools" -maxdepth 2 -name Package.swift 2>/dev/null | sort)
EOF

if [ "$found_any" -eq 0 ]; then
    bad "packages with test targets were found" "no Package.swift declaring a test target was found under app/ or tools/, so this test inspected nothing. If the layout moved, move this scan with it rather than leaving a check that cannot fail."
fi

# 2. mt-cli specifically has to keep its test functions. A step that runs an
#    emptied target is green and proves nothing.
# `|| true`: with no match, grep exits 1 and `set -e` kills the script here,
# which produced an exit code with no FAIL line and no summary, indistinguishable
# from a truncated run. Measured, with every `func test` renamed away.
count="$( { grep -h 'func test' "$ROOT"/tools/mt-cli/Tests/*.swift 2>/dev/null || true; } | wc -l | tr -d ' ')"
if [ "${count:-0}" -gt 0 ]; then
    ok "mt-cli has $count test functions"
else
    bad "mt-cli has test functions" "no test functions found under tools/mt-cli/Tests, so a green step proves nothing"
fi

# 3. mt-cli's tests run inside the job branch protection requires, not merely
#    somewhere in the file.
body="$(ci_job_body "$CI" "$REQUIRED_JOB")"
if [ -z "$body" ]; then
    bad "ci.yml has a \`$REQUIRED_JOB\` job" "no job named \`$REQUIRED_JOB\` was found, so the required check this relies on is gone or renamed"
    summary
fi
if printf '%s\n' "$body" | grep -q 'cd tools/mt-cli && swift test'; then
    ok "the required $REQUIRED_JOB job runs the mt-cli tests"
else
    bad "the required $REQUIRED_JOB job runs the mt-cli tests" "the \`$REQUIRED_JOB\` job does not run them. A job branch protection does not require is not equivalent: cancel-on-failure cannot retract a conclusion an already-finished required leg reported, so a late failure there leaves the pull request mergeable."
fi

# 4. And the step has to EXIST and be REACHABLE. Two separate things, and
#    conflating them is how the first version of this check let a step that had
#    been renamed away and gated to a leg that does not exist report as fine:
#    the reader returned the empty string both for "no condition" and for "no
#    such step", and the caller read empty as harmless.
#
#    Gating to a matrix leg is house style here, but it is a bare string with
#    nothing to check it against: rename the leg and the condition evaluates
#    false forever, with no error and no annotation in the run. The leg is
#    therefore compared against the job's actual matrix values, as whole
#    strings rather than through a regex, so a leg containing a `.` cannot match
#    a different one and a leg containing a `+` cannot make the comparison error
#    out and be blamed on the matrix.
step_if="$(ci_step_condition_for_run "$CI" "$REQUIRED_JOB" "$STEP_RUN")"
if [ -z "$step_if" ]; then
    bad "the mt-cli step exists in the \`$REQUIRED_JOB\` job" "no step in that job runs \`$STEP_RUN\`. If the command moved or changed shape, move this check with it; an absent step must never read as an unconditional one."
elif [ "$step_if" = "__NO_CONDITION__" ]; then
    ok "the mt-cli step is unconditional"
else
    leg="$(printf '%s' "$step_if" | sed -n "s/.*matrix\.variant[[:space:]]*==[[:space:]]*'\([^']*\)'.*/\1/p")"
    if [ -z "$leg" ]; then
        bad "the mt-cli step is reachable" "its condition is \`$step_if\`, which this test cannot resolve to a matrix leg. If the gating changed shape, teach this check the new shape rather than leaving a condition nothing verifies."
    elif ci_matrix_values "$CI" "$REQUIRED_JOB" variant | grep -qxF "$leg"; then
        ok "the mt-cli step's leg \`$leg\` is in the matrix"
    else
        bad "the mt-cli step's leg \`$leg\` is in the matrix" "the step runs only on \`$leg\` and the \`$REQUIRED_JOB\` job's matrix has no such leg, so the step never runs on any leg. The run itself reports no error and no annotation for that. Renaming a leg also renames the required check built from it, which blocks every pull request until branch protection is updated to match; update both and the step stops running with nothing left to say so."
    fi
fi

summary
