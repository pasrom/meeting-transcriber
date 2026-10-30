#!/bin/bash
# Regression test for host_skip and fail_on_host_skips, the pair that lets a
# lane pass on a host condition without that pass reading as coverage.
#
# Both directions matter: a skip must stay a pass (status 0) and must still
# reach the list e2e-app.yml's last step fails scheduled and dispatched runs
# on, and an empty list must not fail anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSED=0
ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }

# Outside CI: a log line, nothing written anywhere.
out="$(GITHUB_ACTIONS='' RUNNER_TEMP="$TMP" host_skip lane-a "cause a")"
[ "$out" = "[lane-a]: SKIP — cause a" ] && [ ! -e "$TMP/e2e-host-skips" ] \
    && ok outside_ci_only_logs || bad outside_ci_only_logs "'$out'"

# CI without the runner's variables (exported by hand): still a pass, no crash.
GITHUB_ACTIONS=true RUNNER_TEMP='' GITHUB_STEP_SUMMARY='' host_skip lane-b "cause b" >/dev/null \
    && ok ci_without_runner_vars_is_a_pass || bad ci_without_runner_vars_is_a_pass "non-zero"

# CI: annotated, summarised, listed.
out="$(GITHUB_ACTIONS=true RUNNER_TEMP="$TMP" GITHUB_STEP_SUMMARY="$TMP/summary" host_skip lane-c "cause c")"
grep -qx '::warning title=lane-c lane skipped::cause c' <<<"$out" \
    && grep -qx '### lane-c lane skipped' "$TMP/summary" \
    && [ "$(cat "$TMP/e2e-host-skips")" = lane-c ] \
    && ok ci_skip_is_annotated_summarised_and_listed || bad ci_skip_is_annotated_summarised_and_listed "'$out'"

# Unwritable summary and skip list: still a pass, and the lost list entry is
# reported as an error annotation.
mkdir -p "$TMP/ro"
status=0
out="$(GITHUB_ACTIONS=true RUNNER_TEMP="$TMP/missing-dir" GITHUB_STEP_SUMMARY="$TMP/ro" host_skip lane-d "cause d")" || status=$?
[ "$status" -eq 0 ] && grep -q '^::error title=lane-d skip not recorded::' <<<"$out" \
    && ok failed_writes_still_pass_and_are_reported || bad failed_writes_still_pass_and_are_reported "status $status: '$out'"

# The gate fails on a listed lane, one error per lane.
status=0
out="$(RUNNER_TEMP="$TMP" fail_on_host_skips)" || status=$?
[ "$status" -eq 1 ] && grep -q '^::error title=lane-c lane skipped::' <<<"$out" \
    && ok gate_fails_on_a_listed_lane || bad gate_fails_on_a_listed_lane "status $status: '$out'"

# And passes on an empty or missing list.
rm -f "$TMP/e2e-host-skips"
RUNNER_TEMP="$TMP" fail_on_host_skips && ok gate_passes_without_skips || bad gate_passes_without_skips "non-zero"

echo "$PASSED passed"
