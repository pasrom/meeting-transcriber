#!/usr/bin/env bash
# Regression test for scripts/ci/test-shards.sh.
#
# What this pins is that a shard run cannot pass while running less than
# `swift test` would: a test the runner silently drops, a shard that exits
# non-zero, a shard that dies without a summary, a shard whose log ends without
# a summary although it exited 0, a plan with an idle shard, a test that ran
# without being planned, and a shard that left no coverage profile each turn
# the run red, while a run that executes exactly the plan is green and merges
# one profile per shard. The planner is pinned too: deterministic, balanced on
# the weights file, and listing a partly skipped class test by test.
#
# `swift`, `xcrun` and `xctest` are fakes on PATH. The fake xctest executes the
# specifiers it is given against a fixed test list and prints what XCTest
# prints, with one behaviour per case: run them all, drop one, fail one, die,
# stop short of the summary, write no profile, or run one more than asked.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/test-shards.sh"

FAILED=0
TMP=$(mktemp -d)
COMPLETED=0
finish() {
    local rc=$?
    rm -rf "$TMP"
    if [ "$COMPLETED" -ne 1 ]; then
        echo "FAIL: the test aborted before reaching its end" >&2
        exit 1
    fi
    exit "$rc"
}
trap finish EXIT

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$name"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

mkdir -p "$TMP/bin" "$TMP/pkg/bin/Fake.xctest"
export FAKE_LIST="$TMP/list.txt" FAKE_BIN="$TMP/pkg/bin" FAKE_CALLS="$TMP/calls" FAKE_MODE="$TMP/mode"

# Six classes; C is the heavy one in the weights file.
cat > "$FAKE_LIST" <<'EOF'
M.A/t1
M.A/t2
M.B/t1
M.C/t1
M.C/t2
M.C/t3
M.D/t1
M.E/t1
M.F/t1
EOF
printf 'M.C\t10.0\nM.A\t0.5\nM.B\t0.5\nM.D\t0.5\nM.E\t0.5\nM.F\t0.5\n' > "$TMP/weights.tsv"

cat > "$TMP/bin/swift" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "test list") cat "$FAKE_LIST" ;;
    "build --show-bin-path") echo "$FAKE_BIN" ;;
    *) echo "fake swift: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat > "$TMP/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "--find xctest") echo "$FAKE_XCTEST" ;;
    "llvm-profdata merge")
        shift 2
        out=""
        while [ $# -gt 0 ]; do
            case "$1" in -o) out=$2; shift 2 ;; -sparse) shift ;; *) echo "$1" >> "$FAKE_CALLS/merged"; shift ;; esac
        done
        echo merged > "$out" ;;
    *) echo "fake xcrun: unexpected $*" >&2; exit 99 ;;
esac
EOF
# The fake xctest: `xctest -XCTest spec bundle`. Expands each comma-separated
# entry (a class, or Class/test) against the list, prints XCTest's lines, and
# writes the profile LLVM_PROFILE_FILE names. $FAKE_MODE selects the deviation;
# the ones tied to a test deviate on M.C/t2, the ones tied to a shard on the
# shard that runs M.B alone (every shard count the harness uses puts it alone).
cat > "$TMP/bin/xctest" <<'EOF'
#!/usr/bin/env bash
spec=$2
echo "$spec" >> "$FAKE_CALLS/specs"
mode=$(cat "$FAKE_MODE")
tests=""
IFS=, read -ra entries <<< "$spec"
for e in "${entries[@]}"; do
    case "$e" in
        */*) tests="$tests $e" ;;
        *) tests="$tests $(grep "^$e/" "$FAKE_LIST" | tr '\n' ' ')" ;;
    esac
done
n=0; failures=0
for t in $tests; do
    cls=${t%/*}; m=${t#*/}
    if [ "$mode" = drop ] && [ "$t" = M.C/t2 ]; then continue; fi
    if [ "$mode" = die ] && [ "$t" = M.C/t2 ]; then exit 139; fi
    echo "Test Case '-[$cls $m]' started."
    # A test's block-buffered stdout flushing mid-string, right before XCTest's line.
    if [ "$mode" = fragment ] && [ "$t" = M.C/t2 ]; then printf 'partial output of the tes'; fi
    if [ "$mode" = fail ] && [ "$t" = M.C/t2 ]; then
        echo "/w/Tests/C.swift:9: error: -[$cls $m] : XCTAssertTrue failed"
        echo "Test Case '-[$cls $m]' failed (0.002 seconds)."
        failures=$((failures + 1))
    elif [ "$t" = M.E/t1 ]; then
        echo "Test Case '-[$cls $m]' skipped (0.001 seconds)."
    elif [ "$mode" = heavy ] && [ "$cls" = M.C ]; then
        echo "Test Case '-[$cls $m]' passed (0.700 seconds)."
    else
        echo "Test Case '-[$cls $m]' passed (0.001 seconds)."
    fi
    n=$((n + 1))
done
if [ "$spec" = M.B ]; then
    case "$mode" in
        extra) echo "Test Case '-[M.Z tUnplanned]' passed (0.001 seconds)." ;;
        # Every test line is there, the log just ends: a log that was cut off
        # or a process that stopped short of its summary while exiting 0.
        nosummary) exit 0 ;;
    esac
fi
printf '\t Executed %d tests, with %d failures (0 unexpected) in 0.1 (0.1) seconds\n' "$n" "$failures"
if [ "$spec" = M.B ] && [ "$mode" = noprofile ]; then exit 0; fi
echo "profile" > "${LLVM_PROFILE_FILE//%p/$$}"
[ "$failures" -eq 0 ]
EOF
chmod +x "$TMP/bin/swift" "$TMP/bin/xcrun" "$TMP/bin/xctest"
export FAKE_XCTEST="$TMP/bin/xctest"
export PATH="$TMP/bin:$PATH"

setup() {
    rm -rf "$FAKE_CALLS" "$TMP/out" "$FAKE_BIN/codecov"
    mkdir -p "$FAKE_CALLS"
    echo "${1:-all}" > "$FAKE_MODE"
}

# Later options win in the script, so a test can override --weights.
run_shards() {
    bash "$SCRIPT" run --out "$TMP/out" --weights "$TMP/weights.tsv" "$@" > "$TMP/run.log" 2>&1
}

# The run must pass, else its output is shown.
expect_pass() {
    run_shards "$@" || { cat "$TMP/run.log"; return 1; }
}

# The run must fail; $1 says what passing would have meant.
expect_fail() {
    local meaning=$1
    shift
    if run_shards "$@"; then echo "passed although $meaning"; return 1; fi
}

# The run's output must contain $1, else it is shown.
log_has() {
    grep -q -- "$1" "$TMP/run.log" || { cat "$TMP/run.log"; return 1; }
}

# Every entry the fake xctest was handed, one per line.
spec_entries() {
    tr ',' '\n' < "$FAKE_CALLS/specs"
}

test_plan_is_deterministic_and_balanced_on_weights() {
    local a b
    a=$(bash "$SCRIPT" plan --shards 2 --weights "$TMP/weights.tsv") || return 1
    b=$(bash "$SCRIPT" plan --shards 2 --weights "$TMP/weights.tsv") || return 1
    [ "$a" = "$b" ] || { echo "two plans differ"; return 1; }
    # C (10 s) alone, the five light classes (2.5 s) together.
    [ "$(printf '%s\n' "$a" | awk -F'\t' '$1 == 1 { print $2 }' | paste -sd, -)" = "M.C" ] || { echo "$a"; return 1; }
    [ "$(printf '%s\n' "$a" | awk -F'\t' '$1 == 2' | grep -c .)" = "5" ] || { echo "$a"; return 1; }
}

test_plan_without_weights_balances_on_test_count() {
    local plan
    : > "$TMP/no-weights.tsv"
    plan=$(bash "$SCRIPT" plan --shards 2 --weights "$TMP/no-weights.tsv") || return 1
    # C has three tests, A two, the rest one each. Heaviest first, each to the
    # lighter shard, ties to the first: C, D, F (5 tests) against A, B, E (4).
    [ "$(printf '%s\n' "$plan" | awk -F'\t' '$1 == 1 { print $2 }' | paste -sd, -)" = "M.C,M.D,M.F" ] || { echo "$plan"; return 1; }
}

test_skip_removes_a_class_and_lists_a_partly_skipped_class_test_by_test() {
    setup
    expect_pass --shards 2 --skip 'M.A/t2' --skip 'M.D' || return 1
    spec_entries | grep -qx 'M.A/t1' || { echo "A was not listed test by test:"; cat "$FAKE_CALLS/specs"; return 1; }
    if spec_entries | grep -q 'M.D'; then echo "D ran although skipped"; return 1; fi
    spec_entries | grep -qx 'M.C' || { echo "C was not listed as a class:"; cat "$FAKE_CALLS/specs"; return 1; }
    [ "$(sort "$TMP/out/executed-tests.txt" | paste -sd' ' -)" = "M.A/t1 M.B/t1 M.C/t1 M.C/t2 M.C/t3 M.E/t1 M.F/t1" ] \
        || { cat "$TMP/out/executed-tests.txt"; return 1; }
}

test_a_run_that_executes_the_plan_passes_and_merges_one_profile_per_shard() {
    setup
    expect_pass --shards 2 --coverage || return 1
    [ "$(grep -c . "$FAKE_CALLS/specs")" = "2" ] || { echo "expected 2 shards"; return 1; }
    [ -f "$FAKE_BIN/codecov/default.profdata" ] || { echo "no merged profile"; return 1; }
    [ "$(grep -c . "$FAKE_CALLS/merged")" = "2" ] || { echo "merged $(cat "$FAKE_CALLS/merged")"; return 1; }
    local raw
    for raw in "$TMP"/out/shard-*.profraw; do
        [ -e "$raw" ] && { echo "raw profile left behind: $raw"; return 1; }
    done
    log_has '9 of 9 planned tests ran'
}

test_a_shard_without_a_profile_fails_the_coverage_run() {
    setup noprofile
    expect_fail "a shard left no profile to merge" --shards 6 --coverage || return 1
    log_has 'expected one profile per shard'
}

test_a_silently_dropped_test_fails_the_run() {
    setup drop
    expect_fail "M.C/t2 never ran" --shards 2 || return 1
    log_has 'planned tests never ran' && log_has '^M.C/t2$'
}

test_a_failing_test_fails_the_run_and_names_it() {
    setup fail
    expect_fail "a test failed" --shards 2 || return 1
    log_has "Test Case '-\[M.C t2\]' failed"
}

test_a_shard_that_dies_fails_the_run() {
    setup die
    expect_fail "a shard died" --shards 2 || return 1
    log_has 'process died'
}

test_a_shard_that_exits_0_without_a_summary_fails_the_run() {
    setup nosummary
    expect_fail "a shard's log ends without the XCTest summary" --shards 6 || return 1
    log_has 'exit 0, no XCTest summary line'
}

test_an_unplanned_test_fails_the_run() {
    setup extra
    expect_fail "a test outside the plan ran" --shards 6 || return 1
    log_has 'not planned'
}

test_more_shards_than_classes_is_refused() {
    setup
    expect_fail "a shard was idle" --shards 7 || return 1
    log_has 'nothing to run'
}

test_a_test_line_behind_a_stdout_fragment_still_counts() {
    setup fragment
    expect_pass --shards 2 || return 1
    log_has '9 of 9 planned tests ran'
}

test_a_skip_pattern_that_does_not_parse_is_refused() {
    setup
    expect_fail "the --skip regex is broken" --shards 2 --skip 'M.C(' || return 1
    log_has 'not a valid regex'
}

test_a_heavy_class_missing_from_the_weights_is_named() {
    setup heavy
    # C takes 0.7 s per test in this mode; the file knows only A.
    printf 'M.A\t0.5\n' > "$TMP/partial-weights.tsv"
    expect_pass --shards 2 --weights "$TMP/partial-weights.tsv" || return 1
    log_has 'does not list.*M.C'
    if grep -q 'does not list.*M.A' "$TMP/run.log"; then echo "A is listed and must not be named"; return 1; fi
}

test_no_coverage_merge_without_the_flag() {
    setup
    expect_pass --shards 2 || return 1
    [ ! -e "$FAKE_CALLS/merged" ] || { echo "merged without --coverage"; return 1; }
}

test_weights_sums_the_seconds_per_class_and_drops_the_light_ones() {
    printf "Test Case '-[M.A t1]' passed (0.250 seconds).\nTest Case '-[M.A t2]' skipped (0.250 seconds).\nTest Case '-[M.B t1]' failed (1.000 seconds).\nTest Case '-[M.C t1]' passed (0.400 seconds).\n" > "$TMP/w.log"
    [ "$(bash "$SCRIPT" weights "$TMP/w.log" | paste -sd' ' -)" = "$(printf 'M.A\t0.500 M.B\t1.000')" ] \
        || { bash "$SCRIPT" weights "$TMP/w.log"; return 1; }
}

# Every test_* function above, so a new one cannot be forgotten in a list.
for t in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
    run_test "$t"
done

COMPLETED=1
exit "$FAILED"
