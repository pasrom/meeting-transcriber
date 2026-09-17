#!/bin/bash
# Regression test: the mt-cli test target must be built and run by a REQUIRED
# check.
#
# `tools/mt-cli` carries 31 tests in a real test target, and for a long time no
# gate compiled them. `swift build` does not build a test target, and the only
# mention of that directory in CI was `scripts/lint.sh`, which formats and lints
# the files without ever type-checking them against the code they test. So the
# tests were reviewed, committed and counted, and could not have failed.
#
# Where they run matters as much as that they run. `audiotap-coverage` is the
# obvious template, and it is NOT a required check: it leans on
# `cancel-on-failure` to take the run down with it, which only reaches jobs that
# are still running. A leg that already reported success keeps that conclusion,
# so a failure arriving late blocks nothing. The mt-cli tests therefore hang off
# the `test` job, which branch protection requires, on the homebrew leg so the
# work is not done twice for a tool that has no App Store variant.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
PASSED=0
FAILED=0

ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; FAILED=1; }

[ -f "$CI" ] || { echo "ci.yml not found"; exit 1; }

# The package still has to have a test target; the rest of this test is about
# where it runs, and would happily guard an empty one.
if grep -q 'testTarget' "$ROOT/tools/mt-cli/Package.swift"; then
    ok "mt-cli declares a test target"
else
    bad "mt-cli declares a test target" "tools/mt-cli/Package.swift no longer declares one, so the step below runs nothing"
fi

count="$(grep -ch 'func test' "$ROOT"/tools/mt-cli/Tests/*.swift 2>/dev/null | awk '{s+=$1} END {print s+0}')"
if [ "${count:-0}" -gt 0 ]; then
    ok "mt-cli has $count test functions"
else
    bad "mt-cli has test functions" "no test functions found under tools/mt-cli/Tests, so a green run proves nothing"
fi

# The body of the `test` job, which is what branch protection requires.
test_job_body() {
    awk '
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); next }
        /^[^[:space:]]/ { job = ""; next }
        job == "test" && $0 !~ /^[[:space:]]*#/ { print }
    ' "$CI"
}

body="$(test_job_body)"
if [ -z "$body" ]; then
    bad "ci.yml has a \`test\` job" "no job named \`test\` was found, so the required check this relies on is gone or renamed"
elif printf '%s\n' "$body" | grep -qE 'cd tools/mt-cli && swift test'; then
    ok "the required test job runs the mt-cli tests"
else
    bad "the required test job runs the mt-cli tests" "the \`test\` job does not run them. Putting them in a job branch protection does not require is not equivalent: a late failure there cancels the run but leaves already-successful required checks green, so the pull request stays mergeable."
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "$PASSED checks passed"
else
    echo "Some checks FAILED."
fi
exit "$FAILED"
