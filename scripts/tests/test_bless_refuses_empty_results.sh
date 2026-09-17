#!/bin/bash
# Regression test: blessing a results file with no rows must not empty the
# committed quality baseline.
#
# The quality gate compares the current run against that baseline, and both
# sides being empty satisfies "no regressions and nothing missing". An empty
# baseline therefore used to pass, having compared nothing, and the required
# check would have stayed green from then on with no diff in any later run to
# notice it.
#
# Reaching that state needs no bad faith. The gate's own failure message says
# to re-bless; an operator following it after a run that died early hands this
# script a results file with zero rows. So the refusal is checked here, and so
# is the other direction, because a guard that refuses everything would pass a
# test that only looked at the refusal.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/bless_quality_baseline.sh"
BASELINE_REL="app/MeetingTranscriber/Tests/Fixtures/quality/quality-baseline.json"
PASSED=0
FAILED=0

ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; FAILED=1; }

[ -f "$SCRIPT" ] || { echo "bless script not found at $SCRIPT"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }

# A throwaway copy of the project layout the script writes into, so the real
# baseline in the working tree is never a participant in this test.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/scripts" "$WORK/$(dirname "$BASELINE_REL")"
cp "$SCRIPT" "$WORK/scripts/"
SENTINEL='[{"engine":"sentinel","fixture":"untouched","wer":0.5}]'
printf '%s\n' "$SENTINEL" > "$WORK/$BASELINE_REL"

echo '[]' > "$WORK/empty.json"
printf '%s\n' '[{"engine":"parakeet","fixture":"two","wer":0.2,"timestamp":"x","appVersion":"0"}]' > "$WORK/one.json"

# An empty results file is refused, and the baseline is left exactly as it was.
if bash "$WORK/scripts/bless_quality_baseline.sh" "$WORK/empty.json" >/dev/null 2>&1; then
    bad "empty results refused" "the script accepted a results file with no rows and would have written an empty baseline"
else
    ok "empty results refused"
fi
if [ "$(cat "$WORK/$BASELINE_REL")" = "$SENTINEL" ]; then
    ok "baseline untouched after the refusal"
else
    bad "baseline untouched after the refusal" "the committed baseline was modified by a run that was supposed to be refused: $(cat "$WORK/$BASELINE_REL")"
fi

# The control: a results file with rows is still written. Without this a guard
# that refused everything would pass the two checks above.
if bash "$WORK/scripts/bless_quality_baseline.sh" "$WORK/one.json" >/dev/null 2>&1; then
    ok "a populated results file is still blessed"
else
    bad "a populated results file is still blessed" "the guard refuses input it should accept, so nobody can re-bless an intended change"
fi
if grep -q '"parakeet"' "$WORK/$BASELINE_REL" 2>/dev/null; then
    ok "the blessed row reached the baseline"
else
    bad "the blessed row reached the baseline" "the script reported success but the baseline does not contain the row: $(cat "$WORK/$BASELINE_REL")"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "$PASSED checks passed"
else
    echo "Some checks FAILED."
fi
exit "$FAILED"
