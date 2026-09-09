#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2064,SC2329
# SC2016: the expected Markdown carries literal backticks. SC2064: the RETURN
# traps expand now on purpose, capturing this call's temp path. SC2329: the
# test functions are invoked by name through run_test.
# Regression test for scripts/ci/type-check-timings.sh, the non-gating report of
# the slowest type-checked function bodies in the analyze lane.
#
# What it pins, and why each matters:
#   - A body measured by several compiler jobs appears once, with its slowest
#     measurement. The 300 ms gate fires on any single measurement, so a table
#     that averaged or took the first would understate the risk.
#   - Lines outside the repository root (dependencies), macro expansion buffers
#     and `<invalid loc>` declarations are skipped: none of them is a place a
#     reader can act on, and the gate that matters runs on our targets.
#   - Ordering is by time, then location, so equal times render identically
#     from one run to the next.
#   - The limit is attributed per module, from that module's own compile
#     commands. Every package in this repository sets its own
#     -warn-long-function-bodies, so a flag found anywhere in the log proves
#     nothing about the module a body belongs to: a report that took the first
#     flag it saw would still print "300 ms" after the app package lost its
#     gate, because the local audiotap package still carries one.
#   - A log with no timings under the root produces a warning and exit 1, not
#     an empty table. An empty table reads as "nothing is close to the limit",
#     which is the one thing the report must never say by accident.
#   - `strip` removes exactly the timing lines, exits 0, and keeps everything
#     the console must still show: the gate's own diagnostic, source excerpts,
#     SwiftLint annotations. It runs inside the Build & Analyze pipeline under
#     pipefail, where an overbroad filter would hide the very error that
#     failed the build and a non-zero exit would fail a green one. That step
#     has no continue-on-error, so this is the one part of the report that
#     can turn the job red.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/type-check-timings.sh"

FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$name"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

# The analyze lane's log as one tagged list: `T<TAB>line` for a timing line,
# `K<TAB>line` for everything else. write_fixture drops the tag;
# strip_survivors keeps the K lines. One list, so the strip test and the
# report tests cannot disagree about which lines are timings. Tabs inside the
# lines are real, as the compiler prints them.
FAKE_ROOT="/w/repo"
fixture_lines() {
    local r="$FAKE_ROOT"
    printf 'K\tBuild settings from command line:\n'
    # Compile commands as xcodebuild prints them, shell-escaped (hence `\=`).
    # The local audiotap package comes first on purpose: a report that took
    # the first gate flag in the log would read the app's limit off it. The
    # frontend line carries the flag unwrapped, the driver line still inside
    # -Xfrontend; both shapes occur. FluidAudio is a dependency built without
    # the gate and must not be reported as ungated: none of its bodies are in
    # the repository.
    printf 'K\t    builtin-swiftTaskExecution -- /Applications/Xcode.app/x/swift-frontend -frontend -c -primary-file %s/tools/audiotap/Sources/Tap.swift -module-name AudioTapLib -warn-long-function-bodies\\=300 -debug-time-function-bodies\n' "$r"
    printf 'K\t    builtin-SwiftDriver -- /Applications/Xcode.app/x/swiftc -module-name MeetingTranscriber -Onone -Xfrontend -warn-long-function-bodies\\=300 -Xfrontend -debug-time-function-bodies\n'
    printf 'K\t    builtin-SwiftDriver -- /Applications/Xcode.app/x/swiftc -module-name FluidAudio -Onone -Xfrontend -debug-time-function-bodies\n'
    # The same body seen by two compiler jobs; the slower one must win.
    printf 'T\t40.00ms\t%s/app/Sources/AppState.swift:213:5\tinitializer MeetingTranscriber.(file).AppState.init(settings:)@%s/app/Sources/AppState.swift:213:5\n' "$r" "$r"
    printf 'T\t151.67ms\t%s/app/Sources/AppState.swift:213:5\tinitializer MeetingTranscriber.(file).AppState.init(settings:)@%s/app/Sources/AppState.swift:213:5\n' "$r" "$r"
    # Slower than anything under the root, but a dependency: must not appear.
    printf 'T\t999.00ms\t/Users/runner/Library/Developer/Xcode/DerivedData/M-abc/SourcePackages/checkouts/FluidAudio/Sources/A.swift:1:1\tglobal function FluidAudio.(file).f()@/Users/runner/Library/Developer/Xcode/DerivedData/M-abc/SourcePackages/checkouts/FluidAudio/Sources/A.swift:1:1\n'
    # Synthesized conformance without a file, and a macro expansion buffer.
    printf 'T\t20.61ms\t<invalid loc>\toperator function WhisperKit.(file).TranscriptionSegment.==\n'
    printf 'T\t3.44ms\t@__swiftmacro_18MeetingTranscriber11AppSettingsC12pollInterval18ObservationTrackedfMp_.swift:7:9\tdidSet observer MeetingTranscriber.(file).AppSettings._pollInterval.didSet observer@@__swiftmacro_18MeetingTranscriber11AppSettingsC12pollInterval18ObservationTrackedfMp_.swift:7:9\n'
    # Lines under the root that look like measurements and are not. Each must
    # survive `strip` and stay out of the table. First the gate's own
    # diagnostic with its source excerpt, in the compiler's current layout:
    # the one line a reader of a red build needs, and the one an overbroad
    # filter (anything on "ms") would swallow.
    printf 'K\t%s/app/Sources/Slow.swift:40:5: error: instance method '\''render()'\'' took 327ms to type-check (limit: 300ms)\n' "$r"
    printf 'K\t40 |     func render() -> some View {\n'
    printf 'K\t   |          `- error: instance method '\''render()'\'' took 327ms to type-check (limit: 300ms)\n'
    # SwiftLint's github-actions-logging reporter, whose output passes through
    # the same filter after `swiftlint analyze`.
    printf 'K\t::error file=%s/app/Sources/Slow.swift,line=40,col=5::Function Body Length Violation: Function body should span 50 lines or less (function_body_length)\n' "$r"
    printf 'K\t::warning file=%s/app/Sources/AppState.swift,line=213,col=5::Cyclomatic Complexity Violation: Function should have complexity 10 or less (cyclomatic_complexity)\n' "$r"
    # A timing line without its declaration field: the report cannot place it
    # in the table, so the console keeps it rather than losing it.
    printf 'K\t12.34ms\t%s/app/Sources/Cut.swift:1:1\n' "$r"
    # A tie, listed in reverse location order so the sort has to fix it.
    printf 'T\t50.00ms\t%s/app/Sources/Zeta.swift:1:1\tgetter MeetingTranscriber.(file).Zeta.body.getter@%s/app/Sources/Zeta.swift:1:1\n' "$r" "$r"
    printf 'T\t50.00ms\t%s/app/Sources/Alpha.swift:9:9\tgetter MeetingTranscriber.(file).Alpha.body.getter@%s/app/Sources/Alpha.swift:9:9\n' "$r" "$r"
    # The local audiotap package lives in the repository too.
    printf 'T\t12.00ms\t%s/tools/audiotap/Sources/Tap.swift:5:5\tinstance method AudioTapLib.(file).Tap.start()@%s/tools/audiotap/Sources/Tap.swift:5:5\n' "$r" "$r"
    printf 'K\t** TEST BUILD SUCCEEDED **\n'
}
write_fixture() { fixture_lines | cut -f 2- > "$1"; }
strip_survivors() { fixture_lines | grep $'^K\t' | cut -f 2-; }

# The table the full fixture must render, top to bottom.
EXPECTED_ROWS='| 151.67 | `app/Sources/AppState.swift:213` | `initializer AppState.init(settings:)` |
| 50.00 | `app/Sources/Alpha.swift:9` | `getter Alpha.body` |
| 50.00 | `app/Sources/Zeta.swift:1` | `getter Zeta.body` |
| 12.00 | `tools/audiotap/Sources/Tap.swift:5` | `instance method Tap.start()` |'

# run_report <log> [args...] -> sets REPORT_OUT, REPORT_RC (no step summary, not on Actions)
run_report() {
    REPORT_OUT=$(env -u GITHUB_STEP_SUMMARY -u GITHUB_ACTIONS bash "$SCRIPT" report "$@")
    REPORT_RC=$?
}

# table_rows <report> -> the data rows of the Markdown table, in order
table_rows() {
    printf '%s\n' "$1" | grep -E '^\| [0-9]+\.[0-9]+ \|'
}

# expect_in <haystack> <pattern> <what> -> 0 when grep finds it, else prints why
expect_in() {
    if printf '%s\n' "$1" | grep -q -- "$2"; then return 0; fi
    echo; echo "  $3"; echo "$1"; return 1
}
expect_not_in() {
    if ! printf '%s\n' "$1" | grep -q -- "$2"; then return 0; fi
    echo; echo "  $3"; echo "$1"; return 1
}

test_dedupes_filters_and_orders() {
    local fx; fx=$(mktemp)
    trap "rm -f -- '$fx'" RETURN
    write_fixture "$fx"
    run_report "$fx" --root "$FAKE_ROOT"
    if [ "$REPORT_RC" -ne 0 ]; then
        echo; echo "  expected exit 0, got $REPORT_RC"; echo "$REPORT_OUT"; return 1
    fi
    local rows; rows=$(table_rows "$REPORT_OUT")
    if [ "$rows" != "$EXPECTED_ROWS" ]; then
        echo; echo "  table differs from expected:"; echo "$rows"; echo "  expected:"; echo "$EXPECTED_ROWS"; return 1
    fi
    # The counts name what was skipped. "8 timings" also pins the recogniser:
    # the diagnostic, the excerpt and the truncated line under the root would
    # make it 9 or more.
    expect_in "$REPORT_OUT" "4 slowest of 4 function bodies in this repository, out of 8 timings (the other 3 are" \
        "counts sentence missing or wrong" || return 1
    # Both modules with bodies in the repository are named with their limit,
    # and the headroom is the slowest body's distance to its own module's.
    expect_in "$REPORT_OUT" 'Limit (`-warn-long-function-bodies`, read from each module.s compile commands): AudioTapLib 300 ms, MeetingTranscriber 300 ms\.' \
        "per-module limit sentence missing or wrong" || return 1
    expect_in "$REPORT_OUT" "The slowest body leaves 148 ms of headroom" "headroom sentence missing or wrong" || return 1
    expect_not_in "$REPORT_OUT" "FluidAudio" "a dependency module leaked into the gate sentence" || return 1
    expect_not_in "$REPORT_OUT" "did not report success" "partial-build note shown for a successful build" || return 1
    return 0
}

test_limit_truncates() {
    local fx; fx=$(mktemp)
    trap "rm -f -- '$fx'" RETURN
    write_fixture "$fx"
    run_report "$fx" --root "$FAKE_ROOT" --limit 2
    if [ "$REPORT_RC" -ne 0 ]; then
        echo; echo "  expected exit 0, got $REPORT_RC"; echo "$REPORT_OUT"; return 1
    fi
    # The two rows are the top two, not any two.
    local rows; rows=$(table_rows "$REPORT_OUT")
    if [ "$rows" != "$(printf '%s\n' "$EXPECTED_ROWS" | head -n 2)" ]; then
        echo; echo "  expected the two slowest rows, got:"; echo "$rows"; return 1
    fi
    expect_in "$REPORT_OUT" "The 2 slowest of 4 function bodies" "shown count not reported as 2" || return 1
    return 0
}

test_no_timings_is_loud_not_empty() {
    local fx summary; fx=$(mktemp); summary=$(mktemp)
    trap "rm -f -- '$fx' '$summary'" RETURN
    printf 'Build settings from command line:\n** TEST BUILD SUCCEEDED **\n' > "$fx"
    run_report "$fx" --root "$FAKE_ROOT"
    if [ "$REPORT_RC" -ne 1 ]; then
        echo; echo "  expected exit 1 for a log without timings, got $REPORT_RC"; echo "$REPORT_OUT"; return 1
    fi
    expect_in "$REPORT_OUT" "No type-check timings were found" "missing the loud warning" || return 1
    expect_not_in "$REPORT_OUT" '^| ms |' "an empty table was printed" || return 1
    # On Actions the same case raises a workflow annotation on the console and
    # lands in the step summary, where a reader looks for the table.
    local out
    out=$(GITHUB_STEP_SUMMARY="$summary" GITHUB_ACTIONS=1 bash "$SCRIPT" report "$fx" --root "$FAKE_ROOT")
    expect_in "$out" '^::warning title=Type-check timings missing::' "no ::warning annotation under GITHUB_ACTIONS" || return 1
    if ! grep -q "No type-check timings were found" "$summary"; then
        echo; echo "  the step summary did not receive the loud warning"; cat "$summary"; return 1
    fi
    if grep -q '^::warning' "$summary"; then
        echo; echo "  the console annotation leaked into the step summary"; cat "$summary"; return 1
    fi
    return 0
}

test_timings_only_outside_root_name_the_count() {
    local fx; fx=$(mktemp)
    trap "rm -f -- '$fx'" RETURN
    write_fixture "$fx"
    run_report "$fx" --root /nowhere/else
    if [ "$REPORT_RC" -ne 1 ]; then
        echo; echo "  expected exit 1 when nothing is under the root, got $REPORT_RC"; echo "$REPORT_OUT"; return 1
    fi
    # "8" counts the timing lines only; the diagnostic and the truncated line
    # under the fake root do not raise it.
    expect_in "$REPORT_OUT" "The log has 8 such lines, none of them for a file under that root" \
        "the outside-root case does not name the count" || return 1
    expect_not_in "$REPORT_OUT" '^| ms |' "an empty table was printed" || return 1
    return 0
}

test_partial_build_and_missing_gate_are_named() {
    local fx; fx=$(mktemp)
    trap "rm -f -- '$fx'" RETURN
    write_fixture "$fx"
    # Drop the success marker and every compile command that carries the gate.
    grep -v 'BUILD SUCCEEDED\|warn-long-function-bodies' "$fx" > "$fx.edited" && mv "$fx.edited" "$fx"
    run_report "$fx" --root "$FAKE_ROOT"
    if [ "$REPORT_RC" -ne 0 ]; then
        echo; echo "  expected exit 0 (timings exist), got $REPORT_RC"; echo "$REPORT_OUT"; return 1
    fi
    expect_in "$REPORT_OUT" "The build did not report success" "partial-build note missing" || return 1
    expect_in "$REPORT_OUT" 'No `-warn-long-function-bodies` limit on any compile command of AudioTapLib, MeetingTranscriber\*\*' \
        "missing-gate note does not name both modules" || return 1
    expect_not_in "$REPORT_OUT" "Limit (" "a limit was claimed with no gate in the log" || return 1
    expect_not_in "$REPORT_OUT" "headroom" "headroom was computed against no limit" || return 1
    return 0
}

test_gate_is_read_per_module() {
    local fx; fx=$(mktemp)
    trap "rm -f -- '$fx*'" RETURN
    local mt='-module-name MeetingTranscriber'

    # Different limits per module, audiotap's first in the log: each value
    # goes to its module, and the headroom (148) is measured against the
    # slowest body's own module, not the first flag seen (200 would give 48).
    write_fixture "$fx"
    sed -i.bak 's/AudioTapLib -warn-long-function-bodies\\=300/AudioTapLib -warn-long-function-bodies\\=200/' "$fx"
    run_report "$fx" --root "$FAKE_ROOT"
    expect_in "$REPORT_OUT" "compile commands): AudioTapLib 200 ms, MeetingTranscriber 300 ms\." "per-module limits not attributed" || return 1
    expect_in "$REPORT_OUT" "leaves 148 ms of headroom" "headroom not taken from the slowest body's own module" || return 1

    # The app module lost its gate while audiotap kept it: the report must say
    # which module is ungated instead of announcing audiotap's 300 for all,
    # and must not give a headroom for a body that has no limit.
    write_fixture "$fx"
    grep -v -- "$mt" "$fx" > "$fx.edited" && mv "$fx.edited" "$fx"
    run_report "$fx" --root "$FAKE_ROOT"
    expect_in "$REPORT_OUT" 'No `-warn-long-function-bodies` limit on any compile command of MeetingTranscriber\*\*' "ungated app module not named" || return 1
    expect_in "$REPORT_OUT" "compile commands): AudioTapLib 300 ms\." "audiotap's own limit not kept" || return 1
    expect_not_in "$REPORT_OUT" "headroom" "headroom given for a body whose module has no limit" || return 1
    expect_not_in "$REPORT_OUT" "FluidAudio" "a dependency was reported as ungated" || return 1

    # The flag twice on one command line: the compiler applies the last one
    # (checked on Xcode 26.6), so the report must too.
    write_fixture "$fx"
    sed -i.bak "s/\($mt .*\)-warn-long-function-bodies\\\\=300/\1-warn-long-function-bodies\\\\=300 -Xfrontend -warn-long-function-bodies\\\\=500/" "$fx"
    if ! grep -q 'bodies\\=300 -Xfrontend -warn-long-function-bodies\\=500' "$fx"; then
        echo; echo "  fixture edit for the duplicate flag did not apply"; return 1
    fi
    run_report "$fx" --root "$FAKE_ROOT"
    expect_in "$REPORT_OUT" "MeetingTranscriber 500 ms\." "last flag on the command line not taken" || return 1
    expect_in "$REPORT_OUT" "leaves 348 ms of headroom" "headroom not against the effective limit" || return 1

    # Two compile commands of one module with different limits: say so, and
    # give no headroom against a value the report cannot pick.
    write_fixture "$fx"
    local second; second=$(grep -- "$mt" "$fx" | sed 's/bodies\\=300/bodies\\=500/')
    printf '%s\n' "$second" >> "$fx"
    run_report "$fx" --root "$FAKE_ROOT"
    expect_in "$REPORT_OUT" 'Conflicting limits on the compile commands of MeetingTranscriber (300 and 500 ms)\.\*\*' "conflicting limits not named" || return 1
    expect_in "$REPORT_OUT" "compile commands): AudioTapLib 300 ms\." "audiotap's own limit not kept beside the conflict" || return 1
    expect_not_in "$REPORT_OUT" "headroom" "headroom given against one of two conflicting limits" || return 1
    return 0
}

test_step_summary_receives_the_report() {
    local fx summary; fx=$(mktemp); summary=$(mktemp)
    trap "rm -f -- '$fx' '$summary'" RETURN
    write_fixture "$fx"
    printf 'earlier content\n' > "$summary"
    local out
    out=$(GITHUB_STEP_SUMMARY="$summary" bash "$SCRIPT" report "$fx" --root "$FAKE_ROOT")
    if [ "$(head -n 1 "$summary")" != "earlier content" ]; then
        echo; echo "  summary file was overwritten instead of appended"; return 1
    fi
    # The whole report, heading and sentences included, not just the rows.
    if [ "$(tail -n +2 "$summary")" != "$out" ]; then
        echo; echo "  summary file and stdout differ:"; diff <(tail -n +2 "$summary") <(printf '%s\n' "$out"); return 1
    fi
    return 0
}

test_strip_removes_exactly_the_timing_lines() {
    local fx; fx=$(mktemp)
    trap "rm -f -- '$fx' '$fx.stripped' '$fx.keep'" RETURN
    write_fixture "$fx"
    bash "$SCRIPT" strip < "$fx" > "$fx.stripped"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo; echo "  strip exited $rc; under pipefail that fails the Build & Analyze step"; return 1
    fi
    # Byte-exact against the tagged list: every K line in order, including
    # the compile commands, the gate diagnostic and its excerpt, the SwiftLint
    # annotations and the truncated timing line; no T line.
    strip_survivors > "$fx.keep"
    if ! cmp -s "$fx.stripped" "$fx.keep"; then
        echo; echo "  strip output differs from the non-timing lines:"; diff "$fx.keep" "$fx.stripped"; return 1
    fi
    return 0
}

test_usage_errors_exit_2() {
    local rc out err
    bash "$SCRIPT" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 2 ] || { echo; echo "  no arguments: expected exit 2, got $rc"; return 1; }
    bash "$SCRIPT" report /nonexistent/log >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 2 ] || { echo; echo "  unreadable log: expected exit 2, got $rc"; return 1; }
    bash "$SCRIPT" strip extra </dev/null >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 2 ] || { echo; echo "  strip with an argument: expected exit 2, got $rc"; return 1; }
    # Usage goes to stderr, and nothing that could pass for a report to stdout.
    out=$(bash "$SCRIPT" report /dev/null --limit ten 2>/dev/null); rc=$?
    err=$(bash "$SCRIPT" report /dev/null --limit ten 2>&1 >/dev/null)
    [ "$rc" -eq 2 ] || { echo; echo "  non-numeric limit: expected exit 2, got $rc"; return 1; }
    [ -z "$out" ] || { echo; echo "  usage error wrote to stdout:"; echo "$out"; return 1; }
    printf '%s' "$err" | grep -q '^usage:' || { echo; echo "  usage text missing from stderr:"; echo "$err"; return 1; }
    return 0
}

run_test test_dedupes_filters_and_orders
run_test test_limit_truncates
run_test test_no_timings_is_loud_not_empty
run_test test_timings_only_outside_root_name_the_count
run_test test_partial_build_and_missing_gate_are_named
run_test test_gate_is_read_per_module
run_test test_step_summary_receives_the_report
run_test test_strip_removes_exactly_the_timing_lines
run_test test_usage_errors_exit_2

exit "$FAILED"
