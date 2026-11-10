#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions are invoked indirectly via run_test
# Regression test for scripts/lib/bundle-licenses.sh: what lands in an app
# bundle's Resources, exercised on a temp folder so it runs without building.
#
# The app's own MIT licence has to ship with the binary as well as the
# third-party texts. MIT asks for its copyright and permission notice in all
# copies, a distributed .app is a copy, and anyone building from a fork with
# these scripts would otherwise ship this project's code without the notice.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/bundle-licenses.sh
source "$REPO_ROOT/scripts/lib/bundle-licenses.sh"

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

test_app_license_is_bundled_verbatim() {
    local res="$WORK/app-license/Resources"
    mkdir -p "$res"
    install_bundled_licenses "$res" || return 1
    if ! cmp -s "$REPO_ROOT/LICENSE" "$res/LICENSE"; then
        echo "  Resources/LICENSE missing or differs from the repo LICENSE"
        return 1
    fi
}

test_third_party_licenses_are_bundled() {
    local res="$WORK/third-party/Resources" src
    mkdir -p "$res"
    install_bundled_licenses "$res" || return 1
    for src in "$REPO_ROOT"/licenses/*.txt; do
        if ! cmp -s "$src" "$res/licenses/$(basename "$src")"; then
            echo "  not bundled: licenses/$(basename "$src")"
            return 1
        fi
    done
}

run_test "app LICENSE lands verbatim in Resources" test_app_license_is_bundled_verbatim
run_test "every licenses/*.txt lands in Resources/licenses" test_third_party_licenses_are_bundled

COMPLETED=1
exit "$FAILED"
