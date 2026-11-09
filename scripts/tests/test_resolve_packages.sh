#!/usr/bin/env bash
# Regression test for scripts/ci/resolve-packages.sh.
#
# What this pins is that the retry neither hides a persistent failure nor
# retries a success: a first-try success resolves once, a transient failure
# passes on a later attempt with a visible warning, a persistent failure fails
# after five attempts, and the waits are 15, 30, 60 and 120 s. `xcodebuild`
# is a fake on PATH that fails a scripted number of times, and `sleep` a fake
# that only records its argument, so no case waits for real.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/resolve-packages.sh"

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

# The fake `xcodebuild`: records its arguments and fails until call
# number $SUCCEED_ON.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/xcodebuild" <<'EOF'
#!/bin/sh
n=$(cat "$COUNTER" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$COUNTER"
echo "$*" >> "$CALLS"
[ "$n" -ge "$SUCCEED_ON" ]
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/bin/sh
echo "$1" >> "$SLEEPS"
EOF
chmod +x "$TMP/bin/xcodebuild" "$TMP/bin/sleep"

# Runs the script with the fakes; sets RC, OUT, CALL_COUNT, SLEPT.
resolve() {
    local succeed_on="$1"
    rm -f "$TMP/counter" "$TMP/calls" "$TMP/sleeps"
    touch "$TMP/sleeps"
    OUT=$(COUNTER="$TMP/counter" CALLS="$TMP/calls" SLEEPS="$TMP/sleeps" SUCCEED_ON="$succeed_on" \
        PATH="$TMP/bin:$PATH" bash "$SCRIPT" -scheme MeetingTranscriber 2>&1)
    RC=$?
    CALL_COUNT=$(wc -l < "$TMP/calls" | tr -d ' ')
    SLEPT=$(tr '\n' ' ' < "$TMP/sleeps")
}

test_first_try_success_resolves_once() {
    resolve 1
    [ "$RC" -eq 0 ] && [ "$CALL_COUNT" -eq 1 ] && [ -z "$SLEPT" ] && ! grep -q '::warning::' <<< "$OUT"
}

test_passes_arguments_to_resolve() {
    resolve 1
    [ "$(cat "$TMP/calls")" = "-resolvePackageDependencies -scheme MeetingTranscriber" ]
}

test_transient_failure_passes_with_a_warning() {
    resolve 3
    [ "$RC" -eq 0 ] && [ "$CALL_COUNT" -eq 3 ] \
        && [ "$(grep -c '::warning::' <<< "$OUT")" -eq 2 ]
}

test_persistent_failure_fails_after_five_attempts() {
    resolve 99
    [ "$RC" -eq 1 ] && [ "$CALL_COUNT" -eq 5 ] && grep -q '::error::' <<< "$OUT"
}

test_persistent_failure_waits_15_30_60_120() {
    resolve 99
    [ "$SLEPT" = "15 30 60 120 " ]
}

run_test test_first_try_success_resolves_once
run_test test_passes_arguments_to_resolve
run_test test_transient_failure_passes_with_a_warning
run_test test_persistent_failure_fails_after_five_attempts
run_test test_persistent_failure_waits_15_30_60_120

COMPLETED=1
exit "$FAILED"
