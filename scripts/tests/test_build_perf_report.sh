#!/usr/bin/env bash
# Regression test for scripts/build_perf_report.py slowdown gating.
#
# Bug history:
#   The slowdown gate flagged any job whose median grew >ALERT_PCT%, with no
#   absolute floor. A job that runs in ~3s jitters by a second between runs
#   (+33%) and reddened the whole weekly Build Performance Tracking cron —
#   GitHub Actions run 27532027974 went red on "changes: 4.0s vs 3.0s
#   (+33.3%)". Fixed by also requiring a minimum absolute seconds delta.
#
# Feeds the analysis module fixture timings with a pinned clock
# (SOURCE_DATE_EPOCH) and asserts on its exit code + output.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT_PY="$REPO_ROOT/scripts/build_perf_report.py"

# Pinned clock: fixture timestamps are placed relative to this (2026-06-15T12:00:00Z).
NOW_EPOCH=1781524800

FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$name"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

# write_fixture <file> <job> <baseline_seconds> <recent_seconds>
# Emits 5 baseline-window + 5 recent-window records for one job.
write_fixture() {
    local file="$1"
    NOW_EPOCH="$NOW_EPOCH" JOB="$2" BASE_S="$3" RECENT_S="$4" \
        python3 - "$file" <<'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone
now = datetime.fromtimestamp(int(os.environ["NOW_EPOCH"]), tz=timezone.utc)
recent = (now - timedelta(days=1)).isoformat().replace("+00:00", "Z")   # in last-7d window
base = (now - timedelta(days=21)).isoformat().replace("+00:00", "Z")    # in prior-28d window
job = os.environ["JOB"]
samples = [(base, float(os.environ["BASE_S"]))] * 5 + [(recent, float(os.environ["RECENT_S"]))] * 5
with open(sys.argv[1], "w") as f:
    for ts, dur in samples:
        f.write(json.dumps({"run_id": "x", "run_created": ts, "job": job, "duration_seconds": dur}) + "\n")
PY
}

# run_report <fixture> <floor_seconds> -> sets REPORT_OUT, REPORT_RC
run_report() {
    REPORT_OUT=$(SOURCE_DATE_EPOCH="$NOW_EPOCH" python3 "$REPORT_PY" "$1" 20 main ci.yml "$2")
    REPORT_RC=$?
}

test_subfloor_jitter_does_not_alert() {
    local fx; fx=$(mktemp)
    trap "rm -f -- '$fx'" RETURN
    write_fixture "$fx" changes 3.0 4.0            # +33%, but only +1s absolute
    run_report "$fx" 10
    if [ "$REPORT_RC" -ne 0 ]; then
        echo; echo "  expected exit 0 (sub-floor jitter), got $REPORT_RC"; echo "$REPORT_OUT"; return 1
    fi
    if printf '%s' "$REPORT_OUT" | grep -q "slowdown(s) detected"; then
        echo; echo "  sub-floor jitter was reported as a slowdown"; echo "$REPORT_OUT"; return 1
    fi
    return 0
}

test_real_regression_alerts() {
    local fx; fx=$(mktemp)
    trap "rm -f -- '$fx'" RETURN
    write_fixture "$fx" test 300.0 400.0           # +33%, +100s absolute
    run_report "$fx" 10
    if [ "$REPORT_RC" -ne 1 ]; then
        echo; echo "  expected exit 1 (real regression), got $REPORT_RC"; echo "$REPORT_OUT"; return 1
    fi
    if ! printf '%s' "$REPORT_OUT" | grep -q "1 slowdown(s) detected"; then
        echo; echo "  real regression not reported as a slowdown"; echo "$REPORT_OUT"; return 1
    fi
    return 0
}

test_floor_boundary_is_inclusive() {
    local fx; fx=$(mktemp)
    trap "rm -f -- '$fx'" RETURN
    # +10s exactly at a 10s floor must alert (gate is >=).
    write_fixture "$fx" boundary 30.0 40.0
    run_report "$fx" 10
    if [ "$REPORT_RC" -ne 1 ]; then
        echo; echo "  +10s at floor 10 should alert (>=), got exit $REPORT_RC"; echo "$REPORT_OUT"; return 1
    fi
    # +9s just under the floor must not alert.
    write_fixture "$fx" boundary 30.0 39.0
    run_report "$fx" 10
    if [ "$REPORT_RC" -ne 0 ]; then
        echo; echo "  +9s under floor 10 should not alert, got exit $REPORT_RC"; echo "$REPORT_OUT"; return 1
    fi
    return 0
}

run_test test_subfloor_jitter_does_not_alert
run_test test_real_regression_alerts
run_test test_floor_boundary_is_inclusive

exit "$FAILED"
