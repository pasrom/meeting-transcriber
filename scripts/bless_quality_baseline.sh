#!/usr/bin/env bash
# Project a full `quality-results.json` (array of QualityResult rows, as
# produced by the quality-and-safety workflow) into the slim, reviewable
# `quality-baseline.json` that the CI regression gate diffs against.
#
# The slim baseline keeps only the comparison surface — engine, fixture,
# modelVariant, wer, der — and drops the volatile fields (timestamp,
# durationSeconds, appVersion, breakdowns) so a re-bless produces a clean diff.
# Metric/variant keys that are null are omitted, matching the writer's output.
# Values are rounded to 4 decimals (far finer than the gate tolerance).
#
# Re-bless workflow when a quality change is intended:
#   1. Download the latest main `quality-results.json` artifact, OR run the
#      quality suite locally with QUALITY_RESULTS_PATH set.
#   2. ./scripts/bless_quality_baseline.sh path/to/quality-results.json
#   3. Review + commit the updated baseline in the SAME PR as the change.
#
# Usage: scripts/bless_quality_baseline.sh <quality-results.json>

set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required"; exit 1; }

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <quality-results.json>" >&2
    exit 2
fi

RESULTS="$1"
[ -f "$RESULTS" ] || { echo "ERROR: results file not found: $RESULTS" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT="$PROJECT_DIR/app/MeetingTranscriber/Tests/Fixtures/quality/quality-baseline.json"

python3 - "$RESULTS" "$OUT" <<'PY'
import json, sys

results_path, out_path = sys.argv[1], sys.argv[2]
with open(results_path) as f:
    rows = json.load(f)

def slim(row):
    out = {"engine": row["engine"], "fixture": row["fixture"]}
    if row.get("modelVariant") is not None:
        out["modelVariant"] = row["modelVariant"]
    for metric in ("wer", "der"):
        if row.get(metric) is not None:
            out[metric] = round(row[metric], 4)
    return out

baseline = [slim(r) for r in rows]
baseline.sort(key=lambda r: (r["engine"], r["fixture"], r.get("modelVariant") or ""))

with open(out_path, "w") as f:
    json.dump(baseline, f, indent=2, sort_keys=True)
    f.write("\n")

print(f"Wrote {len(baseline)} baseline rows to {out_path}")
PY
