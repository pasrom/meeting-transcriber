#!/usr/bin/env bash
# Regression test for scripts/lib/signing.sh on the path where no provisioning
# profile exists — which is every machine except the one that holds the
# account's profiles: the CI Mac mini, and every contributor.
#
# Bug history:
#   `profile_for` ended in `[ -f "$candidate" ] && printf ...`, so with no
#   profile the function's exit status was the failed test, i.e. 1. Under
#   `set -e` the caller's `profile="$(profile_for "$id")"` assignment then
#   aborted the whole script with no output at all — `run_app.sh` died straight
#   after "Build complete!" and the bundle was never assembled or signed.
#
# The library's own header promises the no-profile path is byte-identical to the
# previous behaviour, so this pins exactly that: prepare_signing succeeds, hands
# back the base entitlements unchanged, and leaves the fallback identity alone.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$2"; then
        printf 'PASS\n'
    else
        printf 'FAIL\n'
        FAILED=1
    fi
}

# Runs prepare_signing in a subshell with `set -e` (as its callers do) against a
# PROFILE_DIR that is empty, and echoes the two globals it is contracted to set.
_prepare_without_profile() {
    local workdir="$1"
    (
        set -euo pipefail
        PROFILE_DIR="$workdir/profiles"
        # shellcheck source=../lib/signing.sh
        source "$REPO_ROOT/scripts/lib/signing.sh"
        prepare_signing "$workdir/Some.app" "$workdir/base.entitlements" \
            "com.example.absent" "FALLBACKHASH" >/dev/null
        printf '%s\n%s\n' "$SIGNING_ENTITLEMENTS" "$SIGNING_IDENTITY"
    )
}

test_survives_missing_profile() {
    local workdir out status
    workdir="$(mktemp -d)"
    mkdir -p "$workdir/Some.app/Contents" "$workdir/profiles"
    printf '<plist/>' > "$workdir/base.entitlements"

    local expected_entitlements="$workdir/base.entitlements"
    out="$(_prepare_without_profile "$workdir")"
    status=$?
    rm -rf "$workdir"
    if [ "$status" -ne 0 ]; then
        echo "  prepare_signing aborted (exit $status) with no profile present" >&2
        return 1
    fi
    local entitlements identity
    entitlements="$(printf '%s' "$out" | sed -n 1p)"
    identity="$(printf '%s' "$out" | sed -n 2p)"

    if [ "$entitlements" != "$expected_entitlements" ]; then
        echo "  expected the base entitlements unchanged, got: $entitlements" >&2
        return 1
    fi
    if [ "$identity" != "FALLBACKHASH" ]; then
        echo "  expected the caller's fallback identity, got: $identity" >&2
        return 1
    fi
}

echo "Testing scripts/lib/signing.sh (no provisioning profile)"
echo
run_test "prepare_signing succeeds and passes the base entitlements through" \
    test_survives_missing_profile
echo

if [ "$FAILED" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests FAILED."
fi
exit "$FAILED"
