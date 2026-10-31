#!/usr/bin/env bash
# Runs an SPM package's XCTest suite as a few long-lived processes instead of
# one process per test, and refuses to pass unless every planned test ran.
# Used by the `test` job of .github/workflows/ci.yml; tested by
# scripts/tests/test_test_shards.sh.
#
# Usage (from the package folder, after `swift build --build-tests`, with
# `--enable-code-coverage` when --coverage is wanted):
#   test-shards.sh run  [--shards N] [--skip REGEX]... [--weights FILE] [--out DIR] [--coverage]
#   test-shards.sh plan [--shards N] [--skip REGEX]... [--weights FILE]
#   test-shards.sh weights LOG...
#
#   --shards N      how many processes to run at once (default: hw.ncpu).
#   --skip REGEX    leave out the tests whose `Module.Class/test` specifier
#                   matches, as `swift test --skip` would. Repeatable.
#   --weights FILE  `Module.Class<TAB>seconds` lines that the partition
#                   balances on. A class missing from the file weighs 10 ms per
#                   test, which is why `weights` lists only the classes that
#                   take 0.5 s or more. Default: scripts/ci/test-shard-weights.tsv
#                   next to this script when it exists; regenerate it from the
#                   logs of a one-process run (`run --shards 1`, then
#                   `weights <out>/shard-1.log`).
#   --out DIR       where the shard logs and profiles go (default:
#                   <bin-path>/test-shards).
#   --coverage      merge the shards' profiles into <bin-path>/codecov/default.profdata,
#                   where scripts/export-lcov.sh expects `swift test
#                   --enable-code-coverage` to have left one, then delete them.
#
# Why not `swift test --parallel`: it runs every test method in a process of
# its own, and starting the xctest bundle with its ML frameworks costs more
# than most tests do. Measured on main at 755494c6 (4079 tests, M3 Max, warm
# model caches, `CFFIXED_USER_HOME` on a scratch home, `CI=1`, `--skip
# ModelPreloadTests`), wall time of the test run alone:
#   `run --shards 3`                     50 s (twice; shards took 24, 46, 43 s)
#   `run --shards 1` (one process)      126 s
#   `swift test --parallel` (16 workers) 76 s
#   `swift test --parallel --num-workers 3`, the hosted runner's count: 246 s
# With `--enable-code-coverage`, `--parallel` also leaves one profraw per test
# (3736 files, 12 GB, at 4b0af8b9) to merge; this leaves one per process.
#
# Why not `swift test --filter` per shard: SwiftPM holds the build folder's lock
# for the whole run, so concurrent invocations serialise (measured: the second
# waits with "Another instance of SwiftPM is already running"). This runs the
# bundle through `xctest` directly, which is what SwiftPM does underneath, with
# whole classes as the unit: a shard is `xctest -XCTest Module.ClassA,Module.ClassB,...`,
# and a class that `--skip` leaves only partly in is listed test by test.
#
# What makes the result trustworthy, since a shard that silently ran less than
# its share would otherwise look green:
#   - The plan is derived from `swift test list`, the same list `swift test`
#     runs, and every shard's log is read back for the tests it executed. The
#     union must equal the plan exactly, by test identifier, not by count.
#   - Every shard's exit status is collected with `wait` on its own pid; any
#     non-zero status fails the run, as does a shard whose log carries no
#     XCTest summary line (a crashed process prints none).
#   - A shard with nothing to run is an error, not a free pass: it means
#     --shards exceeds the class count and the plan is not what was asked for.
#
# Isolation changes with this, on purpose: tests of one shard share a process,
# so a test that leaks process-global state can reach a later class in the same
# shard. The partition is deterministic (same list, same weights, same shards,
# same plan), so a leak shows up reproducibly rather than as a flake. A test
# must not assert on a state only a fresh process has (`NSApp == nil`, say);
# inject that state instead, as MouseInjectionTests does.

set -uo pipefail
# `sort` and `comm` must agree on the order of the test lists, and the class
# names cut out of a sorted `Class<TAB>seconds` list must still be in order;
# both hold in the C locale and neither under a collation that ignores
# punctuation and whitespace.
export LC_ALL=C

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
default_weights="$self_dir/test-shard-weights.tsv"
tab=$(printf '\t')

usage() {
    # The header up to the first blank comment line after the options.
    sed -n '2,/^# Why not/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 2
}

err() { echo "::error::test-shards: $*" >&2; }
fail() { err "$@"; exit 1; }

# Line count of the files given, or of stdin; unpadded, unlike `wc -l` on macOS.
nlines() { awk 'END { print NR }' "$@"; }

# ---------------------------------------------------------------------------
# Reading XCTest output. One regex, so the verifier's idea of a test and the
# weights' idea of a class cannot drift: both are `Module.Class/test`.
#
# `Test Case '-[Module.Class test]' passed (0.123 seconds).` is what XCTest
# prints per test on macOS, with `failed` and `skipped` as the other outcomes.
# A skipped test counts as executed: `swift test` runs it too and reports it
# as skipped, and the plan has no way of knowing in advance which ones skip.
# ---------------------------------------------------------------------------
#
# Not anchored at the start of the line: a test's own stdout is block-buffered
# into the log file and can flush in the middle of a string, so XCTest's line
# may land behind a fragment of it (seen with the LocalVQE self-test's output).
test_lines() {
    sed -nE "s/.*Test Case '-\[([A-Za-z0-9_]+\.[A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' (passed|failed|skipped) \(([0-9.]+) seconds\)\.$/\1\/\2${tab}\4/p" "$@"
}

executed_tests() {
    test_lines "$@" | cut -f1
}

# `Module.Class<TAB>seconds` for every class that takes 0.5 s or more, summed
# over the given logs. The rest is what the planner's per-test default is for.
class_seconds() {
    test_lines "$@" \
        | awk -F'\t' '{ split($1, p, "/"); s[p[1]] += $2 } END { for (c in s) if (s[c] >= 0.5) printf "%s\t%.3f\n", c, s[c] }' \
        | sort
}

# ---------------------------------------------------------------------------
# Planning. Reads the planned tests on stdin (`Module.Class/test`, one per
# line, sorted, skips already applied) and prints
# `shard<TAB>Module.Class<TAB>spec<TAB>seconds` lines, where spec is what the
# shard passes to xctest for that class: the class itself when every one of its
# tests is planned, else its planned tests one by one; seconds is the weight the
# class was placed by. Sorted by shard, then by class, so the output is stable.
#
# Longest-processing-time first: classes in descending weight, each to the
# shard with the least weight so far, ties to the lowest shard. Deterministic
# for the same input, which is what lets a leak between two classes reproduce.
# ---------------------------------------------------------------------------
plan_shards() {
    local shards="$1" weights="$2" all_tests="$3"
    # One row per class: weight, class, spec.
    awk -F'\t' -v weights="$weights" -v alltests="$all_tests" '
        BEGIN {
            # Every test the bundle has, so a class with some tests skipped is
            # told apart from one listed whole.
            while ((getline line < alltests) > 0) { split(line, p, "/"); total[p[1]]++ }
            close(alltests)
            if (weights != "") {
                while ((getline line < weights) > 0) {
                    if (split(line, w, "\t") == 2) seconds[w[1]] = w[2] + 0
                }
                close(weights)
            }
        }
        {
            split($0, p, "/"); cls = p[1]
            count[cls]++
            tests[cls] = (cls in tests) ? tests[cls] "," $0 : $0
        }
        END {
            for (cls in count) {
                weight = (cls in seconds) ? seconds[cls] : count[cls] * 0.01
                spec = (count[cls] == total[cls]) ? cls : tests[cls]
                printf "%.3f\t%s\t%s\n", weight, cls, spec
            }
        }
    ' | sort -t "$tab" -k1,1nr -k2,2 | awk -F'\t' -v shards="$shards" '
        BEGIN { for (s = 1; s <= shards; s++) load[s] = 0 }
        {
            best = 1
            for (s = 2; s <= shards; s++) if (load[s] < load[best]) best = s
            load[best] += $1
            printf "%d\t%s\t%s\t%s\n", best, $2, $3, $1
        }
    ' | sort -t "$tab" -k1,1n -k2,2
}

# ---------------------------------------------------------------------------
# Options shared by `run` and `plan`.
# ---------------------------------------------------------------------------
shards=""
skips=()
weights=""
out=""
coverage=0

parse_options() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --shards) [ $# -ge 2 ] || usage; shards=$2; shift 2 ;;
            --skip) [ $# -ge 2 ] || usage; skips+=(-e "$2"); shift 2 ;;
            --weights) [ $# -ge 2 ] || usage; weights=$2; shift 2 ;;
            --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
            --coverage) coverage=1; shift ;;
            *) usage ;;
        esac
    done
    shards=${shards:-$(sysctl -n hw.ncpu 2>/dev/null || echo 1)}
    case "$shards" in
        '' | *[!0-9]* | 0) fail "--shards must be a positive integer, got '$shards'" ;;
    esac
    if [ -z "$weights" ] && [ -f "$default_weights" ]; then
        weights=$default_weights
    fi
    if [ -n "$weights" ] && [ ! -f "$weights" ]; then
        fail "weights file not found: $weights"
    fi
}

# The planned tests: `swift test list` with the skips taken out. Written to
# $1 (every test) and $2 (planned tests, sorted).
list_tests() {
    local all="$1" planned="$2"
    # Listing loads the instrumented bundle, which on exit writes a profile
    # into the working directory unless told where else; it is not wanted.
    LLVM_PROFILE_FILE="$all.profraw" swift test list --skip-build > "$all" || fail "swift test list failed"
    rm -f "$all.profraw"
    grep -q . "$all" || fail "swift test list found no tests; is the test bundle built?"
    if [ ${#skips[@]} -gt 0 ]; then
        # Under pipefail the status is grep's: 1 when nothing is left, which is
        # a plan of nothing and is refused below rather than here; 2 is a
        # pattern that does not parse.
        grep -Ev "${skips[@]}" "$all" | sort -u > "$planned"
        [ $? -le 1 ] || fail "a --skip pattern is not a valid regex"
    else
        sort -u "$all" > "$planned"
    fi
    grep -q . "$planned" || fail "every test is skipped; nothing to run"
}

cmd_plan() {
    parse_options "$@"
    local tmp
    tmp=$(mktemp -d)
    list_tests "$tmp/all" "$tmp/planned"
    plan_shards "$shards" "$weights" "$tmp/all" < "$tmp/planned" | cut -f1,2
    rm -rf "$tmp"
}

cmd_weights() {
    [ $# -ge 1 ] || usage
    class_seconds "$@"
}

# ---------------------------------------------------------------------------
# Running.
# ---------------------------------------------------------------------------
pids=()

stop_shards() {
    local pid
    for pid in ${pids[@]+"${pids[@]}"}; do
        kill "$pid" 2>/dev/null
    done
}

group_start() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$*"; else echo "== $*"; fi; }
group_end() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi; }

cmd_run() {
    parse_options "$@"

    local bin bundle xctest
    bin=$(swift build --show-bin-path) || fail "swift build --show-bin-path failed"
    bundle=$(find "$bin" -maxdepth 1 -name '*.xctest' -type d | sort)
    [ -n "$bundle" ] || fail "no .xctest bundle in $bin; run swift build --build-tests first"
    [ "$(printf '%s\n' "$bundle" | nlines)" -eq 1 ] || fail "more than one .xctest bundle in $bin"
    xctest=$(xcrun --find xctest) || fail "xcrun cannot find xctest"
    [ -n "$out" ] || out="$bin/test-shards"
    # Only what an earlier run left: --out may name a folder the caller uses
    # for other things too. An instrumented bundle writes a profile per
    # process whether or not --coverage asked for one.
    mkdir -p "$out" || fail "cannot create $out"
    rm -f "$out"/shard-*.log "$out"/shard-*.profraw "$out"/*-tests.txt "$out/plan.tsv"

    list_tests "$out/all-tests.txt" "$out/planned-tests.txt"
    plan_shards "$shards" "$weights" "$out/all-tests.txt" < "$out/planned-tests.txt" > "$out/plan.tsv" \
        || fail "planning the shards failed"
    grep -q . "$out/plan.tsv" || fail "planning produced an empty plan from $(nlines "$out/planned-tests.txt") planned tests"

    local planned_count
    planned_count=$(nlines "$out/planned-tests.txt")
    echo "test-shards: $planned_count tests in $(nlines "$out/plan.tsv") classes across $shards shards, bundle $bundle"

    # Also on EXIT: a `fail` while shards are up must not leave them running.
    trap stop_shards EXIT INT TERM
    local i spec started
    started=$(date +%s)
    for i in $(seq 1 "$shards"); do
        spec=$(awk -F'\t' -v s="$i" '$1 == s { print $3 }' "$out/plan.tsv" | paste -sd, -)
        [ -n "$spec" ] || fail "shard $i has nothing to run: --shards $shards exceeds the class count"
        echo "  shard $i: $(awk -F'\t' -v s="$i" '$1 == s { n++; w += $4 } END { printf "%d classes, %.1f s planned", n, w }' "$out/plan.tsv")"
        LLVM_PROFILE_FILE="$out/shard-$i-%p.profraw" \
            "$xctest" -XCTest "$spec" "$bundle" > "$out/shard-$i.log" 2>&1 &
        pids[i]=$!
    done

    # One `wait` per pid: a bare `wait` would answer with the last status only.
    # Each shard is reported as its wait returns; the plan check below needs
    # every log and comes after.
    local rc status=0 summary
    for i in $(seq 1 "$shards"); do
        wait "${pids[i]}"
        rc=$?
        summary=$(grep -E "^[[:space:]]*Executed [0-9]+ tests?," "$out/shard-$i.log" | tail -n 1 | sed 's/^[[:space:]]*//')
        group_start "shard $i: exit $rc, ${summary:-no XCTest summary line (process died?)}"
        # Unanchored like test_lines: a failed test's line can sit behind a
        # fragment of the test's own output.
        grep -E "Test Case '.*' failed \(|error:|Fatal error|fatal error" "$out/shard-$i.log" | head -n 50
        if [ "$rc" -ne 0 ] || [ -z "$summary" ]; then
            status=1
            # The end of the log holds the summary, or the crash.
            echo "--- last 300 lines of shard $i ($out/shard-$i.log) ---"
            tail -n 300 "$out/shard-$i.log"
        fi
        group_end
    done
    trap - EXIT INT TERM
    pids=()
    echo "test-shards: all shards finished after $(( $(date +%s) - started )) s"

    local executed="$out/executed-tests.txt"
    executed_tests "$out"/shard-*.log | sort -u > "$executed"
    local missing extra
    missing=$(comm -23 "$out/planned-tests.txt" "$executed")
    extra=$(comm -13 "$out/planned-tests.txt" "$executed")
    if [ -n "$missing" ]; then
        status=1
        err "$(printf '%s\n' "$missing" | nlines) planned tests never ran:"
        printf '%s\n' "$missing" | head -n 50 >&2
    fi
    if [ -n "$extra" ]; then
        status=1
        err "tests ran that were not planned:"
        printf '%s\n' "$extra" | head -n 50 >&2
    fi
    echo "test-shards: $(nlines "$executed") of $planned_count planned tests ran"

    # The weights file is a snapshot. A heavy class it does not know is
    # weighed at 10 ms per test and can tilt the balance; say so, so a shard
    # that grew slow has an explanation and the file a reason to be refreshed.
    if [ -n "$weights" ]; then
        local unweighted
        unweighted=$(class_seconds "$out"/shard-*.log | cut -f1 | comm -23 - <(cut -f1 "$weights" | sort))
        [ -z "$unweighted" ] || echo "::notice::test-shards: classes above 0.5 s that $weights does not list (regenerate it with 'weights'): $(printf '%s\n' "$unweighted" | paste -sd' ' -)"
    fi

    if [ "$status" -ne 0 ]; then
        err "FAILED (logs in $out)"
        exit 1
    fi

    if [ "$coverage" -eq 1 ]; then
        local raws profile_dir="$bin/codecov"
        raws=$(find "$out" -maxdepth 1 -name 'shard-*.profraw' | sort)
        [ "$(printf '%s\n' "$raws" | grep -c .)" -ge "$shards" ] \
            || fail "expected one profile per shard in $out, found: ${raws:-none}"
        mkdir -p "$profile_dir" || fail "cannot create $profile_dir"
        # shellcheck disable=SC2086  # the paths come from find, one per line, no spaces
        xcrun llvm-profdata merge -sparse $raws -o "$profile_dir/default.profdata" \
            || fail "llvm-profdata merge failed"
        # shellcheck disable=SC2086
        rm -f $raws
        echo "test-shards: coverage merged into $profile_dir/default.profdata"
    fi
}

[ $# -ge 1 ] || usage
command=$1
shift
case "$command" in
    run) cmd_run "$@" ;;
    plan) cmd_plan "$@" ;;
    weights) cmd_weights "$@" ;;
    *) usage ;;
esac
