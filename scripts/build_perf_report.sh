#!/usr/bin/env bash
# Build Performance Tracking
#
# Pulls the last $LIMIT successful CI runs on $BRANCH, computes per-job
# duration trends, and emits a Markdown summary. Flags any job whose
# last-7-day median is >$ALERT_PCT% slower than the prior 28-day median.
#
# Exits 0 normally, 1 when at least one slowdown is detected — so the
# workflow run is visibly red in the Actions list.
#
# Inputs (env vars):
#   WORKFLOW   default: ci.yml
#   BRANCH     default: main
#   LIMIT      default: 50
#   ALERT_PCT  default: 20
#
# Requires: gh, jq, python3 (all preinstalled on GitHub-hosted runners).

set -euo pipefail

WORKFLOW="${WORKFLOW:-ci.yml}"
BRANCH="${BRANCH:-main}"
LIMIT="${LIMIT:-50}"
ALERT_PCT="${ALERT_PCT:-20}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "::group::Fetching last $LIMIT successful $WORKFLOW runs on $BRANCH" >&2
gh run list \
    --workflow="$WORKFLOW" \
    --branch="$BRANCH" \
    --status=success \
    --limit="$LIMIT" \
    --json databaseId,createdAt \
    > "$WORK/runs.json"

run_count=$(jq 'length' "$WORK/runs.json")
echo "Got $run_count runs." >&2
echo "::endgroup::" >&2

if [ "$run_count" -lt 10 ]; then
    cat <<EOF
# Build Performance Tracking

Insufficient data: only $run_count successful runs found on \`$BRANCH\`
(need at least 10 for a meaningful trend).
EOF
    exit 0
fi

echo "::group::Collecting per-job timings" >&2
: > "$WORK/jobs.jsonl"
while IFS=$'\t' read -r run_id created_at; do
    if ! gh run view "$run_id" --json jobs > "$WORK/run-$run_id.json" 2>/dev/null; then
        echo "  skipping run $run_id (view failed)" >&2
        continue
    fi
    jq -c \
       --arg created "$created_at" \
       --arg rid "$run_id" \
       '.jobs[] | select(.conclusion == "success") |
        select(.startedAt and .completedAt) |
        {
          run_id: $rid,
          run_created: $created,
          job: .name,
          duration_seconds: (
              (.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601)
          )
        }' "$WORK/run-$run_id.json" >> "$WORK/jobs.jsonl"
done < <(jq -r '.[] | "\(.databaseId)\t\(.createdAt)"' "$WORK/runs.json")
echo "::endgroup::" >&2

python3 - "$WORK/jobs.jsonl" "$ALERT_PCT" "$BRANCH" "$WORKFLOW" <<'PY'
import json, statistics, sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

path, alert_pct, branch, workflow = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
now = datetime.now(timezone.utc)
recent_cutoff = now - timedelta(days=7)
baseline_cutoff = now - timedelta(days=35)

by_job = defaultdict(lambda: {"recent": [], "baseline": []})
with open(path) as f:
    for line in f:
        rec = json.loads(line)
        ts = datetime.fromisoformat(rec["run_created"].replace("Z", "+00:00"))
        if ts >= recent_cutoff:
            by_job[rec["job"]]["recent"].append(rec["duration_seconds"])
        elif ts >= baseline_cutoff:
            by_job[rec["job"]]["baseline"].append(rec["duration_seconds"])

print(f"# Build Performance Tracking — `{workflow}` on `{branch}`")
print()
print(f"Generated {now:%Y-%m-%d %H:%M UTC}. Alert threshold: **>{alert_pct}%**.")
print()
print("| Job | n (last 7d) | median (7d) | n (prior 28d) | median (28d) | Δ |")
print("| --- | ---: | ---: | ---: | ---: | ---: |")

slowdowns = []
for job, w in sorted(by_job.items()):
    rn, bn = len(w["recent"]), len(w["baseline"])
    rm = statistics.median(w["recent"]) if w["recent"] else 0.0
    bm = statistics.median(w["baseline"]) if w["baseline"] else 0.0
    if bm > 0 and rn > 0:
        delta_pct = (rm - bm) / bm * 100
        delta_str = f"{delta_pct:+.1f}%"
        if delta_pct > alert_pct:
            slowdowns.append((job, rm, bm, delta_pct))
            delta_str = f"⚠️ {delta_str}"
    else:
        delta_str = "—"
    print(f"| {job} | {rn} | {rm:.1f}s | {bn} | {bm:.1f}s | {delta_str} |")

print()
if slowdowns:
    print(f"## ⚠️ {len(slowdowns)} slowdown(s) detected")
    print()
    for job, rm, bm, pct in slowdowns:
        print(f"- **{job}**: {rm:.1f}s recent vs {bm:.1f}s baseline (+{pct:.1f}%)")
    sys.exit(1)
print("✅ No slowdowns detected.")
PY
