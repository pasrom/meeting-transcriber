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
#   WORKFLOW           default: ci.yml
#   BRANCH             default: main
#   LIMIT              default: 50
#   ALERT_PCT          default: 20
#   MIN_DELTA_SECONDS  default: 10  (absolute floor; see build_perf_report.py)
#
# Requires: gh, jq, python3 (all preinstalled on GitHub-hosted runners).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKFLOW="${WORKFLOW:-ci.yml}"
BRANCH="${BRANCH:-main}"
LIMIT="${LIMIT:-50}"
ALERT_PCT="${ALERT_PCT:-20}"
MIN_DELTA_SECONDS="${MIN_DELTA_SECONDS:-10}"

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

# Keep this the terminal command and unwrapped (no if/||/pipe): the report
# module exits 1 on a detected slowdown, and `set -e` + this being the last
# command is what propagates that exit 1 out to the workflow step.
python3 "$SCRIPT_DIR/build_perf_report.py" \
    "$WORK/jobs.jsonl" "$ALERT_PCT" "$BRANCH" "$WORKFLOW" "$MIN_DELTA_SECONDS"
