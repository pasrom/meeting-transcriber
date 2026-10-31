#!/usr/bin/env bash
# Regression test for scripts/ci/prewarm-models.sh.
#
# What this pins is that the pre-warm's retry neither hides a real failure nor
# records an incomplete cache as warm: a first-try success runs once, a
# transient failure passes on the retry with a visible warning, a persistent
# failure fails after the bound without a marker, and a moved or renamed
# suite, a build error or a signal fails without a retry. `swift` is a fake on PATH that
# plays a scripted sequence of outcomes.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/prewarm-models.sh"

FAILED=0
TMP=$(mktemp -d)
# Set at the very end. On bash 3.2 a `set -u` abort in a script with an EXIT
# trap exits 0, so without this the file could pass while running none of its
# cases (see test_kill_and_verify_gone.sh, where this was measured).
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

# The fake `swift`: each call records its arguments, consumes the next line of
# $PLAN and prints what `swift test` would for that outcome.
#   pass     suite ran and passed, exit 0
#   fail     suite started, a download failed, exit 1
#   none     filter matched nothing, exit 0 (suite renamed or removed)
#   fetch    package fetch failed before the build, exit 1
#   compile  compile error, exit 1
mkdir -p "$TMP/bin"
cat > "$TMP/bin/swift" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$CALLS") + 1 )); echo "$n" > "$CALLS"
echo "$*" > "$ARGS"
case "$(sed -n "${n}p" "$PLAN")" in
    pass)    echo "Test Suite 'ModelPreloadTests' started"
             echo "Test Suite 'ModelPreloadTests' passed"; exit 0 ;;
    fail)    echo "Test Suite 'ModelPreloadTests' started"
             echo "error: The Internet connection appears to be offline."
             echo "Test Suite 'ModelPreloadTests' failed"; exit 1 ;;
    none)    echo "warning: No matching test cases were run"; exit 0 ;;
    fetch)   echo "error: Failed to clone repository"; exit 1 ;;
    compile) echo "/w/Sources/A.swift:12:5: error: cannot find 'x' in scope"; exit 1 ;;
    link)    echo "error: link command failed with exit code 1 (use -v to see invocation)"; exit 1 ;;
    assert)  echo "Test Suite 'ModelPreloadTests' started"
             echo "/w/Tests/ModelPreloadTests.swift:17: error: -[T testPreloadParakeet] : XCTAssertEqual failed"
             echo "Test Suite 'ModelPreloadTests' failed"; exit 1 ;;
    oom)     echo "error: compile command failed due to signal 9 (use -v to see invocation)"; exit 1 ;;
    signal)  echo "Test Suite 'ModelPreloadTests' started"; exit 130 ;;
    *)       echo "fake: no outcome planned for call $n"; exit 99 ;;
esac
EOF
chmod +x "$TMP/bin/swift"

# A fresh package folder with the preload file, no marker, no calls yet.
setup() {
    rm -rf "$TMP/case"
    mkdir -p "$TMP/case/pkg/Tests"
    touch "$TMP/case/pkg/Tests/ModelPreloadTests.swift" "$TMP/case/summary.md"
    MARKER="$TMP/case/.prewarmed"
    SUMMARY="$TMP/case/summary.md"
    export PLAN="$TMP/case/plan" CALLS="$TMP/case/calls" ARGS="$TMP/case/args"
    echo 0 > "$CALLS"
    printf '%s\n' "$@" > "$PLAN"
}

# Runs the script with the marker set unless NO_MARKER is; output in out.
prewarm() {
    (cd "$TMP/case/pkg" &&
        PATH="$TMP/bin:$PATH" GITHUB_STEP_SUMMARY="$SUMMARY" PREWARM_BACKOFF_SECONDS=0 \
        PREWARM_LOG="$TMP/case/log" PREWARM_MARKER="${NO_MARKER-$MARKER}" \
        bash "$SCRIPT" "$@") > "$TMP/case/out" 2>&1
}

calls() { cat "$CALLS"; }
warnings() { grep -c '^::warning::' "$TMP/case/out"; }
said() { grep -q "$1" "$TMP/case/out"; }

test_first_try_success_runs_once_and_writes_the_marker() {
    setup pass
    prewarm --skip X && [ "$(calls)" = 1 ] && [ -f "$MARKER" ] && [ "$(warnings)" = 0 ] &&
        [ ! -s "$SUMMARY" ] && [ "$(cat "$ARGS")" = "test --filter ModelPreloadTests --skip X" ]
}

test_transient_failure_passes_on_retry_with_a_warning() {
    setup fail pass
    prewarm && [ "$(calls)" = 2 ] && [ -f "$MARKER" ] && [ "$(warnings)" = 1 ] &&
        grep -q 'attempt 1 of 2 failed' "$SUMMARY" && grep -q 'passed on attempt 2 of 2' "$SUMMARY"
}

test_failed_package_fetch_is_retried() {
    setup fetch pass
    prewarm && [ "$(calls)" = 2 ] && [ -f "$MARKER" ] && [ "$(warnings)" = 1 ]
}

test_persistent_failure_fails_after_the_bound_without_a_marker() {
    setup fail fail pass
    ! prewarm && [ "$(calls)" = 2 ] && [ ! -f "$MARKER" ] && said '^::error::Pre-warm did not pass'
}

test_missing_preload_file_fails_without_running() {
    setup pass
    rm "$TMP/case/pkg/Tests/ModelPreloadTests.swift"
    ! prewarm && [ "$(calls)" = 0 ] && [ ! -f "$MARKER" ] && said 'moved or renamed'
}

test_renamed_suite_fails_without_retry() {
    setup none pass
    ! prewarm && [ "$(calls)" = 1 ] && [ ! -f "$MARKER" ] && said 'renamed or removed' && [ "$(warnings)" = 0 ]
}

test_compile_error_fails_without_retry() {
    setup compile pass
    ! prewarm && [ "$(calls)" = 1 ] && [ ! -f "$MARKER" ] && said 'failed to build' && [ "$(warnings)" = 0 ]
}

test_link_error_fails_without_retry() {
    setup link pass
    ! prewarm && [ "$(calls)" = 1 ] && [ ! -f "$MARKER" ] && said 'failed to build' && [ "$(warnings)" = 0 ]
}

# A cancelled run or a step timeout must not start a second attempt.
test_signal_exit_fails_without_retry() {
    setup signal pass
    prewarm
    [ $? = 130 ] && [ "$(calls)" = 1 ] && [ ! -f "$MARKER" ] && [ "$(warnings)" = 0 ] &&
        said 'ended by signal 2'
}

# A compiler killed under memory pressure is not a build error in the code.
test_compiler_killed_by_a_signal_is_retried() {
    setup oom pass
    prewarm && [ "$(calls)" = 2 ] && [ -f "$MARKER" ] && [ "$(warnings)" = 1 ]
}

# Indistinguishable from a model that failed to download, so it is retried,
# and the final error points away from the network.
test_failing_assertion_is_retried_then_blamed_on_the_code() {
    setup assert assert
    ! prewarm && [ "$(calls)" = 2 ] && [ ! -f "$MARKER" ] && [ "$(warnings)" = 1 ] &&
        said 'rather than the network'
}

test_unwritable_log_fails_instead_of_misjudging_the_run() {
    setup pass
    mkdir "$TMP/case/log"   # tee cannot write to a directory
    ! prewarm && [ "$(calls)" = 1 ] && [ ! -f "$MARKER" ] && said 'could not write its log'
}

test_warm_marker_skips_the_run() {
    setup fail
    touch "$MARKER"
    prewarm && [ "$(calls)" = 0 ]
}

# setup-swift-test caches the models itself and sets no marker.
test_without_a_marker_nothing_is_written() {
    setup pass
    NO_MARKER="" prewarm && [ "$(calls)" = 1 ] && [ ! -e "$MARKER" ]
}

run_test test_first_try_success_runs_once_and_writes_the_marker
run_test test_transient_failure_passes_on_retry_with_a_warning
run_test test_failed_package_fetch_is_retried
run_test test_persistent_failure_fails_after_the_bound_without_a_marker
run_test test_missing_preload_file_fails_without_running
run_test test_renamed_suite_fails_without_retry
run_test test_compile_error_fails_without_retry
run_test test_link_error_fails_without_retry
run_test test_signal_exit_fails_without_retry
run_test test_compiler_killed_by_a_signal_is_retried
run_test test_failing_assertion_is_retried_then_blamed_on_the_code
run_test test_unwritable_log_fails_instead_of_misjudging_the_run
run_test test_warm_marker_skips_the_run
run_test test_without_a_marker_nothing_is_written

COMPLETED=1
exit "$FAILED"
