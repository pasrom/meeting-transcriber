#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions are invoked indirectly via run_test
# Regression test for scripts/appstore-bundle-check.sh: the two judgements the
# App Store smoke workflow relies on, exercised on plist files and temp folders
# so they run without building, signing or launching anything.
#
# Each case is a way an App Store build can be broken while still launching:
# entitlements dropped, swapped for the Homebrew set, or quietly changed; the
# app writing its data outside its container. The workflow only proves the
# checks pass on a good build; these prove they would fail on a bad one.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/appstore-bundle-check.sh
source "$REPO_ROOT/scripts/appstore-bundle-check.sh"
set +e   # the sourced script sets -e; the harness must not stop on a failure

ENTITLEMENTS_DIR="$REPO_ROOT/app/MeetingTranscriber/Entitlements"
APPSTORE="$ENTITLEMENTS_DIR/AppStore.entitlements"
HOMEBREW="$ENTITLEMENTS_DIR/Homebrew.entitlements"

WORK="$(mktemp -d)"
# Set at the very end: on the system bash 3.2 a `set -u` abort under an EXIT
# trap exits 0, so without this a half-run file would read as a pass.
COMPLETED=0
finish() {
    local rc=$?
    rm -rf "$WORK"
    if [ "$COMPLETED" -ne 1 ]; then
        echo "FAIL: the test aborted before reaching its end" >&2
        exit 1
    fi
    exit "$rc"
}
trap finish EXIT

FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$2" >"$WORK/out" 2>&1; then
        printf 'PASS\n'
    else
        printf 'FAIL\n'
        sed 's/^/    /' "$WORK/out"
        FAILED=1
    fi
}

# expect_fail <reason> <cmd...>: the check must reject, and say <reason>
# (a fixed string). Exiting non-zero alone is not enough: a crash in the
# checker exits non-zero too and must not count as a rejection.
expect_fail() {
    local reason="$1" out; shift
    if out="$("$@" 2>&1)"; then
        echo "  expected a rejection, got success:"; echo "$out"
        return 1
    fi
    if ! grep -qF -- "$reason" <<<"$out"; then
        echo "  rejected, but not with '$reason':"; echo "$out"
        return 1
    fi
}

# edited <name> <key> <json-value>: a copy of the committed App Store file with
# <key> set to <json-value> (`null` removes it), so each case tracks the real
# file instead of restating its keys. Prints the copy's path. Callers assign
# it with `|| return 1`: a failed edit must fail the case, not let an
# expect_fail pass on a missing file.
# Not plutil: its key paths split on the dots every entitlement name has.
edited() {
    python3 -I - "$APPSTORE" "$WORK/$1" "$2" "$3" <<'PY'
import json, plistlib, sys
src, dst, key, value = sys.argv[1:5]
with open(src, "rb") as f:
    d = plistlib.load(f)
value = json.loads(value)
if value is None:
    del d[key]
else:
    d[key] = value
with open(dst, "wb") as f:
    plistlib.dump(d, f)
print(dst, end="")
PY
}

test_identical_passes() { compare_entitlements "$APPSTORE" "$APPSTORE"; }

test_homebrew_set_fails() { expect_fail "missing from signed bundle: com.apple.security.app-sandbox" \
        compare_entitlements "$APPSTORE" "$HOMEBREW"; }

test_no_entitlements_fails() {
    : >"$WORK/empty"
    expect_fail "missing from signed bundle: com.apple.security.device.audio-input" \
        compare_entitlements "$APPSTORE" "$WORK/empty"
}

test_extra_key_fails() {
    local f; f="$(edited extra com.apple.security.cs.disable-library-validation true)" || return 1
    expect_fail "not in committed file: com.apple.security.cs.disable-library-validation" \
        compare_entitlements "$APPSTORE" "$f"
}

test_missing_key_fails() {
    local f; f="$(edited drop com.apple.security.device.audio-input null)" || return 1
    expect_fail "missing from signed bundle: com.apple.security.device.audio-input" \
        compare_entitlements "$APPSTORE" "$f"
}

test_type_change_fails() {
    local f; f="$(edited int com.apple.security.device.audio-input 1)" || return 1
    expect_fail "value differs: com.apple.security.device.audio-input" \
        compare_entitlements "$APPSTORE" "$f"
}

# The committed file is the reference, so a sandbox switched off there must
# not pass just because the signed bundle agrees with it.
test_unsandboxed_reference_fails() {
    local off; off="$(edited nosandbox com.apple.security.app-sandbox false)" || return 1
    expect_fail "committed file does not set com.apple.security.app-sandbox" \
        compare_entitlements "$off" "$off"
}

# --- data location -----------------------------------------------------------

ID="com.example.app"

# A fresh container folder and no host folder for each case; `marker` and
# `host_marker` write a liveness marker naming the given PID.
layout() {
    rm -rf "$WORK/container" "$WORK/host"
    mkdir -p "$WORK/container"
}
marker() { printf '%s' "$1" >"$WORK/container/$ID.running"; }
host_marker() { mkdir -p "$WORK/host"; printf '%s' "$1" >"$WORK/host/$ID.running"; }
check() { check_data_location "$WORK/container" "$WORK/host" "$ID" 4242; }

test_marker_in_container_passes() { layout; marker 4242; check; }

test_missing_marker_fails() { layout; expect_fail "no liveness marker" check; }

test_marker_of_other_process_fails() {
    layout; marker 1111
    expect_fail "names PID 1111" check
}

test_marker_outside_container_fails() {
    layout; marker 4242; host_marker 4242
    expect_fail "outside the container:" check
}

# A dev or Homebrew build on the same machine owns that folder, and its own
# marker (another PID) is not this run's doing.
test_other_builds_host_data_passes() {
    layout; marker 4242; host_marker 1111
    mkdir -p "$WORK/host/recordings"
    check
}

# Unanchored grep -E, as pgrep -f applies it to a whole command line.
test_command_regex_matches_only_the_app() {
    local path='/tmp/a (copy)+[x]/M.app/Contents/MacOS/M' re
    re="$(command_regex "$path")"
    printf '%s\n' "$path" | grep -Eq -- "$re" &&
        printf '%s\n' "$path -psn_0_1" | grep -Eq -- "$re" &&
        ! printf '%s\n' '/tmp/a (copy)+[x]/MXapp/Contents/MacOS/M' | grep -Eq -- "$re" &&
        ! printf '%s\n' "$path"Helper | grep -Eq -- "$re" &&
        ! printf '%s\n' "lldb $path" | grep -Eq -- "$re"
}

echo "Testing scripts/appstore-bundle-check.sh"
echo
run_test "identical entitlements pass" test_identical_passes
run_test "Homebrew entitlements in an App Store bundle fail" test_homebrew_set_fails
run_test "a bundle without entitlements fails" test_no_entitlements_fails
run_test "an entitlement not in the committed file fails" test_extra_key_fails
run_test "an entitlement missing from the bundle fails" test_missing_key_fails
run_test "a value of another plist type fails" test_type_change_fails
run_test "an unsandboxed committed file fails" test_unsandboxed_reference_fails
run_test "marker in the container passes" test_marker_in_container_passes
run_test "no marker in the container fails" test_missing_marker_fails
run_test "marker naming another PID fails" test_marker_of_other_process_fails
run_test "a marker of the launched PID outside the container fails" test_marker_outside_container_fails
run_test "another build's data outside the container passes" test_other_builds_host_data_passes
run_test "the process pattern matches only the app binary itself" test_command_regex_matches_only_the_app
echo

COMPLETED=1
if [ "$FAILED" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests FAILED."
fi
exit "$FAILED"
