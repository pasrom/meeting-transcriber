#!/bin/bash
# Regression test: every SwiftPM package in this repository that declares a
# test target must have those tests run by CI, and mt-cli's must run inside a
# REQUIRED check.
#
# `tools/mt-cli` carried 31 tests that no gate compiled. `swift build` does not
# build a test target, and the only mention of that directory anywhere in CI was
# scripts/lint.sh, which formats and lints the files without ever type-checking
# them against the code they test. The tests were written, reviewed, committed
# and counted, and could not have failed.
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
STEP_NAME="mt-cli tests"
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
    if grep -q "cd $rel && swift test" "$CI"; then
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
count="$(grep -h 'func test' "$ROOT"/tools/mt-cli/Tests/*.swift 2>/dev/null | wc -l | tr -d ' ')"
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

# 4. And the step has to be REACHABLE. Gating it to one matrix leg is house
#    style here, but it is a bare string match with nothing to check it against:
#    renaming the leg makes the condition evaluate false forever, with no error
#    and no annotation, and a check that only greps for the command still
#    passes. Measured before this check existed.
step_if="$(ci_step_condition "$CI" "$REQUIRED_JOB" "$STEP_NAME")"
if [ -z "$step_if" ]; then
    ok "the mt-cli step is unconditional"
else
    leg="$(printf '%s' "$step_if" | sed -n "s/.*matrix\.variant[[:space:]]*==[[:space:]]*'\([^']*\)'.*/\1/p")"
    if [ -z "$leg" ]; then
        bad "the mt-cli step is reachable" "its condition is \`$step_if\`, which this test cannot resolve to a matrix leg. If the gating changed shape, teach this check the new shape rather than leaving a condition nothing verifies."
    elif printf '%s\n' "$body" | grep -qE "variant:[[:space:]]*\[.*\b$leg\b.*\]"; then
        ok "the mt-cli step's leg \`$leg\` is in the matrix"
    else
        bad "the mt-cli step's leg \`$leg\` is in the matrix" "the step runs only on \`$leg\` and the \`$REQUIRED_JOB\` job's matrix has no such leg, so the step never runs on any leg. Renaming a leg does this silently: no error, no annotation, the tests simply stop."
    fi
fi

summary
