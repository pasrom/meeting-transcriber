#!/usr/bin/env python3
"""Analyze per-job CI timings and emit a Markdown trend report.

Reads a JSON-lines file of per-job timings (one record per line, with
``job``, ``run_created`` ISO-8601 timestamp, and ``duration_seconds``) and
prints a Markdown summary comparing each job's last-7-day median against its
prior-28-day median.

A job is flagged as a slowdown only when it clears BOTH gates:
  * relative: the median grew by more than ``alert_pct`` percent, AND
  * absolute: the median grew by at least ``min_delta_seconds`` seconds.

The absolute floor exists because a percentage on a tiny baseline is
meaningless — a job that runs in ~3s jitters by a second between runs, which
is +33% but not a real regression. Without the floor, runner scheduling
noise on fast jobs reds the whole weekly cron.

Exits 0 normally, 1 when at least one slowdown is detected — so the workflow
run is visibly red in the Actions list.

Usage:
    build_perf_report.py <jobs.jsonl> <alert_pct> <branch> <workflow> <min_delta_seconds>

The clock can be pinned via the ``SOURCE_DATE_EPOCH`` environment variable
(seconds since the Unix epoch) for deterministic output in tests.
"""

import json
import os
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone


def current_time() -> datetime:
    """Now in UTC, overridable via SOURCE_DATE_EPOCH for reproducible tests."""
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if epoch:
        return datetime.fromtimestamp(int(epoch), tz=timezone.utc)
    return datetime.now(timezone.utc)


def main() -> int:
    path = sys.argv[1]
    alert_pct = int(sys.argv[2])
    branch = sys.argv[3]
    workflow = sys.argv[4]
    min_delta_seconds = float(sys.argv[5])

    now = current_time()
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
    print(
        f"Generated {now:%Y-%m-%d %H:%M UTC}. "
        f"Alert threshold: **>{alert_pct}%** and **≥{min_delta_seconds:g}s** absolute."
    )
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
            if delta_pct > alert_pct and (rm - bm) >= min_delta_seconds:
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
        return 1
    print("✅ No slowdowns detected.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
