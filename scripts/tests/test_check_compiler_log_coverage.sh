#!/usr/bin/env bash
# shellcheck disable=SC2329
# SC2329: the test functions are invoked by name through run_test.
# Regression test for the two guards that let the analyze job restore cached
# dependency build output without shrinking the analysis:
#   scripts/ci/check-compiler-log-coverage.sh   (log and analysed-count checks)
#   scripts/ci/prune-analyze-derived-data.sh    (own output never restored)
#
# What it pins, and why each matters:
#   - A log with a compile entry for every file passes, and one file missing
#     from AudioTapLib, the app or the tests each fails and is named. Those are
#     the three modules the analysis must keep, and a build that finds a module
#     up to date prints nothing for it.
#   - A log from a build with nothing to do (no entries at all) fails. That is
#     the exact shape a restored, up-to-date DerivedData produces, and the
#     failure mode it causes is a green job over zero analysed files.
#   - A path that merely appears in a timing or diagnostic line does not count
#     as covered: only a SwiftCompile entry means the file was compiled in this
#     build.
#   - A dependency entry is not required, and a file outside the three
#     directories is not expected.
#   - The analysed-count check passes on the matching count, fails on a smaller
#     one, and fails (not passes) when swiftlint printed no summary.
#   - An empty log or an empty source tree is a usage error, never a pass.
#   - A checkout path or file name with a space, `|`, `(` or `+` is matched
#     literally (xcodebuild writes a space as backslash-space), and a file
#     missing from such a tree is still named.
#   - The prune removes this repository's intermediates and products and keeps
#     the dependency ones.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CHECK="$REPO_ROOT/scripts/ci/check-compiler-log-coverage.sh"
PRUNE="$REPO_ROOT/scripts/ci/prune-analyze-derived-data.sh"

FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$name"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

# A throwaway repository with one file in each analysed directory, plus files
# in places that must not be expected.
make_tree() {
    local root="$1"
    mkdir -p "$root/app/MeetingTranscriber/Sources" "$root/app/MeetingTranscriber/Tests" \
        "$root/tools/audiotap/Sources" "$root/tools/audiotap/Tests" "$root/tools/mt-cli/Sources"
    : > "$root/app/MeetingTranscriber/Sources/App.swift"
    : > "$root/app/MeetingTranscriber/Tests/AppTests.swift"
    : > "$root/tools/audiotap/Sources/Tap.swift"
    : > "$root/tools/audiotap/Tests/TapTests.swift"
    : > "$root/tools/mt-cli/Sources/Cli.swift"
}

# The log of a clean build: one SwiftCompile entry per file and target, a
# dependency entry, and timing lines that mention the same files.
full_log() {
    local r="$1"
    printf 'SwiftCompile normal arm64 %s/app/MeetingTranscriber/Sources/App.swift (in target '\''MeetingTranscriber-product'\'' from project '\''MeetingTranscriber'\'')\n' "$r"
    printf 'SwiftCompile normal arm64 %s/app/MeetingTranscriber/Sources/App.swift (in target '\''MeetingTranscriber'\'' from project '\''MeetingTranscriber'\'')\n' "$r"
    printf 'SwiftCompile normal arm64 %s/app/MeetingTranscriber/Tests/AppTests.swift (in target '\''MeetingTranscriberTests-product'\'' from project '\''MeetingTranscriber'\'')\n' "$r"
    printf 'SwiftCompile normal arm64 %s/tools/audiotap/Sources/Tap.swift (in target '\''AudioTapLib'\'' from project '\''AudioTapLib'\'')\n' "$r"
    printf 'SwiftCompile normal arm64 /home/x/SourcePackages/checkouts/WhisperKit/A.swift (in target '\''WhisperKit'\'' from project '\''argmax-oss-swift'\'')\n'
    printf 'SwiftCompile normal arm64 Compiling\\ App.swift,\\ Tap.swift (in target '\''AudioTapLib'\'' from project '\''AudioTapLib'\'')\n'
    printf '0.01ms\t%s/app/MeetingTranscriber/Sources/App.swift:1:1\tgetter\n' "$r"
}

# Writes the full log minus every line that names $2.
log_without() {
    full_log "$1" | grep -vF "$2"
}

run_check() { bash "$CHECK" "$@" 2>&1; }

setup() {
    T="$(mktemp -d)"
    ROOT="$(cd "$T" && pwd -P)"
    make_tree "$ROOT"
}
teardown() { rm -rf "$T"; }

test_complete_log_passes() {
    # The fixture tree also holds mt-cli and AudioTapLib test files, which the
    # MeetingTranscriber scheme does not build: the log has no entry for them
    # and the check must still pass, and a dependency entry must not be needed.
    setup
    full_log "$ROOT" > "$T/log"
    out=$(run_check "$T/log" "$ROOT"); rc=$?
    teardown
    [ "$rc" -eq 0 ] || { echo; echo "  expected exit 0, got $rc: $out"; return 1; }
    printf '%s' "$out" | grep -q 'covers all 3 Swift files' || { echo; echo "  count missing: $out"; return 1; }
}

test_each_module_missing_fails_and_is_named() {
    local rel
    for rel in tools/audiotap/Sources/Tap.swift app/MeetingTranscriber/Sources/App.swift app/MeetingTranscriber/Tests/AppTests.swift; do
        setup
        log_without "$ROOT" "$rel" > "$T/log"
        out=$(run_check "$T/log" "$ROOT"); rc=$?
        teardown
        [ "$rc" -eq 1 ] || { echo; echo "  $rel dropped: expected exit 1, got $rc"; return 1; }
        printf '%s' "$out" | grep -qF "missing: $rel" || { echo; echo "  $rel not named: $out"; return 1; }
    done
}

test_build_with_nothing_to_do_fails() {
    setup
    printf 'Resolve Package Graph\n** TEST BUILD SUCCEEDED **\n' > "$T/log"
    out=$(run_check "$T/log" "$ROOT"); rc=$?
    teardown
    [ "$rc" -eq 1 ] || { echo; echo "  expected exit 1, got $rc: $out"; return 1; }
    printf '%s' "$out" | grep -q '3 of 3 Swift files' || { echo; echo "  count wrong: $out"; return 1; }
}

test_a_path_in_a_timing_line_is_not_coverage() {
    setup
    {
        log_without "$ROOT" "tools/audiotap/Sources/Tap.swift"
        printf '0.01ms\t%s/tools/audiotap/Sources/Tap.swift:1:1\tgetter\n' "$ROOT"
        printf '%s/tools/audiotap/Sources/Tap.swift:3:1: warning: something\n' "$ROOT"
    } > "$T/log"
    out=$(run_check "$T/log" "$ROOT"); rc=$?
    teardown
    [ "$rc" -eq 1 ] || { echo; echo "  expected exit 1, got $rc: $out"; return 1; }
}

test_special_characters_in_paths_are_matched_literally() {
    # The root has a space, a pipe, parentheses and a plus; one source file has
    # a space and one a plus. xcodebuild escapes each space as backslash-space.
    local t2 r2 esc rc out
    t2="$(mktemp -d)"
    r2="$t2/my repo|(x)+y"
    mkdir -p "$r2"
    r2="$(cd "$r2" && pwd -P)"
    make_tree "$r2"
    : > "$r2/app/MeetingTranscriber/Sources/My File.swift"
    : > "$r2/app/MeetingTranscriber/Sources/Watch+Loop.swift"
    esc="${r2// /\\ }"
    {
        full_log "$esc"
        printf 'SwiftCompile normal arm64 %s/app/MeetingTranscriber/Sources/My\\ File.swift (in target '\''MeetingTranscriber'\'' from project '\''MeetingTranscriber'\'')\n' "$esc"
        printf 'SwiftCompile normal arm64 %s/app/MeetingTranscriber/Sources/Watch+Loop.swift (in target '\''MeetingTranscriber'\'' from project '\''MeetingTranscriber'\'')\n' "$esc"
    } > "$t2/log"
    out=$(run_check "$t2/log" "$r2"); rc=$?
    [ "$rc" -eq 0 ] || { rm -rf "$t2"; echo; echo "  expected exit 0, got $rc: $out"; return 1; }
    printf '%s' "$out" | grep -q 'covers all 5 Swift files' || { rm -rf "$t2"; echo; echo "  count wrong: $out"; return 1; }
    # Dropping the escaped-space file must be reported, by its unescaped name.
    grep -vF 'My\ File.swift' "$t2/log" > "$t2/log2"
    out=$(run_check "$t2/log2" "$r2"); rc=$?
    rm -rf "$t2"
    [ "$rc" -eq 1 ] || { echo; echo "  dropped file: expected exit 1, got $rc: $out"; return 1; }
    printf '%s' "$out" | grep -qF 'missing: app/MeetingTranscriber/Sources/My File.swift' || { echo; echo "  file not named: $out"; return 1; }
}

test_analysed_count() {
    setup
    printf 'Analyzing Swift files in current working directory\nDone analyzing! Found 0 violations, 0 serious in 3 files.\n' > "$T/ok"
    printf 'Done analyzing! Found 0 violations, 0 serious in 2 files.\n' > "$T/short"
    printf 'Analyzing Swift files in current working directory\n' > "$T/nosummary"
    out_ok=$(run_check --analyzed "$T/ok" "$ROOT"); rc_ok=$?
    out_short=$(run_check --analyzed "$T/short" "$ROOT"); rc_short=$?
    out_none=$(run_check --analyzed "$T/nosummary" "$ROOT"); rc_none=$?
    teardown
    [ "$rc_ok" -eq 0 ] || { echo; echo "  matching count: expected 0, got $rc_ok: $out_ok"; return 1; }
    [ "$rc_short" -eq 1 ] || { echo; echo "  smaller count: expected 1, got $rc_short: $out_short"; return 1; }
    [ "$rc_none" -eq 1 ] || { echo; echo "  no summary: expected 1, got $rc_none: $out_none"; return 1; }
}

test_empty_inputs_are_usage_errors() {
    setup
    : > "$T/empty"
    run_check "$T/empty" "$ROOT" > /dev/null; rc_log=$?
    run_check --analyzed "$T/empty" "$ROOT" > /dev/null; rc_an=$?
    printf 'x\n' > "$T/log"
    mkdir "$T/bare"
    run_check "$T/log" "$T/bare" > /dev/null; rc_tree=$?
    run_check > /dev/null; rc_args=$?
    teardown
    [ "$rc_log" -eq 2 ] || { echo; echo "  empty log: expected 2, got $rc_log"; return 1; }
    [ "$rc_an" -eq 2 ] || { echo; echo "  empty analysis output: expected 2, got $rc_an"; return 1; }
    [ "$rc_tree" -eq 2 ] || { echo; echo "  no sources: expected 2, got $rc_tree"; return 1; }
    [ "$rc_args" -eq 2 ] || { echo; echo "  no arguments: expected 2, got $rc_args"; return 1; }
}

test_prune_removes_own_output_and_keeps_dependencies() {
    local dd
    dd="$(mktemp -d)"
    local i="$dd/Build/Intermediates.noindex" p="$dd/Build/Products/Debug"
    mkdir -p "$i/MeetingTranscriber.build/Debug" "$i/AudioTapLib.build" "$i/WhisperKit.build" \
        "$i/argmax-oss-swift.build" "$i/XCBuildData" "$p/ExecutableModules" "$p/PackageFrameworks" \
        "$dd/SourcePackages/checkouts/WhisperKit" "$dd/Logs" "$dd/Index.noindex"
    : > "$p/MeetingTranscriber"; : > "$p/MeetingTranscriber.swiftmodule"; : > "$p/MeetingTranscriberTests.xctest"
    : > "$p/AudioTapLib.o"; : > "$p/AudioTapLib.swiftmodule"; : > "$p/CExceptionCatcher.o"
    : > "$p/WhisperKit.swiftmodule"; : > "$p/ArgmaxCore.o"; : > "$p/FluidAudio_FluidAudio.bundle"
    bash "$PRUNE" "$dd"; rc=$?
    local bad=""
    [ "$rc" -eq 0 ] || bad="exit $rc"
    local gone
    for gone in "$i/MeetingTranscriber.build" "$i/AudioTapLib.build" "$p/MeetingTranscriber" \
        "$p/MeetingTranscriber.swiftmodule" "$p/MeetingTranscriberTests.xctest" "$p/AudioTapLib.o" \
        "$p/AudioTapLib.swiftmodule" "$p/CExceptionCatcher.o" "$p/ExecutableModules" "$dd/Logs" "$dd/Index.noindex"; do
        [ ! -e "$gone" ] || bad="$bad; still there: ${gone#"$dd"/}"
    done
    local kept
    for kept in "$i/WhisperKit.build" "$i/argmax-oss-swift.build" "$i/XCBuildData" "$p/WhisperKit.swiftmodule" \
        "$p/ArgmaxCore.o" "$p/FluidAudio_FluidAudio.bundle" "$p/PackageFrameworks" "$dd/SourcePackages/checkouts/WhisperKit"; do
        [ -e "$kept" ] || bad="$bad; removed: ${kept#"$dd"/}"
    done
    # A directory that does not exist is fine: the first run of a cold cache.
    bash "$PRUNE" "$dd/does-not-exist" || bad="$bad; missing dir failed"
    rm -rf "$dd"
    [ -z "$bad" ] || { echo; echo "  $bad"; return 1; }
}

run_test test_complete_log_passes
run_test test_each_module_missing_fails_and_is_named
run_test test_build_with_nothing_to_do_fails
run_test test_a_path_in_a_timing_line_is_not_coverage
run_test test_special_characters_in_paths_are_matched_literally
run_test test_analysed_count
run_test test_empty_inputs_are_usage_errors
run_test test_prune_removes_own_output_and_keeps_dependencies

exit "$FAILED"
