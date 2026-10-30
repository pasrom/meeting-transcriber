#!/usr/bin/env bash
# Regression test for scripts/ci/prepare-runner-home.sh.
#
# Why this exists: the script creates a per-runner test home and links the
# account's ffmpeg into it. If the test home, its Library (where the tests put
# Application Support and Caches), or a folder on the way to that link, were a
# link into the account's home, the tests or the setup would write into the
# account's own folders, the ones every job on the Mini shares. The guards
# that refuse those layouts are what this pins. Each case builds a fake
# account home in a temp dir and asserts the account side is untouched.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/prepare-runner-home.sh"

FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$name"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Counts the account's entries, so account_intact can tell nothing was added.
snapshot() { ACCOUNT_ENTRIES=$(find "$ACCOUNT" | wc -l | tr -d ' '); }

# A fresh fake account with a keychain file and an ffmpeg, plus a tool cache.
setup() {
    rm -rf "$TMP/case"
    ACCOUNT="$TMP/case/account"
    TOOLS="$TMP/case/tools"
    mkdir -p "$ACCOUNT/Library/Keychains" "$ACCOUNT/.local/bin" "$TOOLS"
    echo secret > "$ACCOUNT/Library/Keychains/login.keychain-db"
    printf '#!/bin/sh\n' > "$ACCOUNT/.local/bin/ffmpeg"
    chmod +x "$ACCOUNT/.local/bin/ffmpeg"
    HOME_DIR="$TOOLS/meetingtranscriber-home/mini-1"
    snapshot
}

prepare() {
    HOME="$ACCOUNT" bash "$SCRIPT" "$TOOLS" mini-1 2>/dev/null
}

account_intact() {
    [ "$(cat "$ACCOUNT/Library/Keychains/login.keychain-db")" = secret ] &&
        [ -x "$ACCOUNT/.local/bin/ffmpeg" ] && [ ! -L "$ACCOUNT/.local/bin/ffmpeg" ] &&
        [ "$(find "$ACCOUNT" | wc -l | tr -d ' ')" = "$ACCOUNT_ENTRIES" ]
}

test_fresh_home_gets_the_ffmpeg_link() {
    setup
    local out
    out=$(prepare) || return 1
    [ "$out" = "$(cd "$HOME_DIR" && pwd -P)" ] &&
        [ "$(readlink "$HOME_DIR/.local/bin/ffmpeg")" = "$(cd "$ACCOUNT" && pwd -P)/.local/bin/ffmpeg" ] &&
        account_intact
}

test_rerun_is_idempotent() {
    setup
    prepare >/dev/null && prepare >/dev/null && account_intact && [ -L "$HOME_DIR/.local/bin/ffmpeg" ]
}

test_home_linked_to_the_account_is_refused() {
    setup
    mkdir -p "$TOOLS/meetingtranscriber-home"
    ln -s "$ACCOUNT" "$HOME_DIR"
    ! prepare >/dev/null && account_intact
}

test_home_linked_elsewhere_in_the_account_creates_nothing_there() {
    setup
    mkdir -p "$TOOLS/meetingtranscriber-home" "$ACCOUNT/Documents/scratch"
    snapshot   # the scratch folder is part of the account now
    ln -s "$ACCOUNT/Documents/scratch" "$HOME_DIR"
    ! prepare >/dev/null && account_intact
}

test_base_linked_into_the_account_is_refused() {
    setup
    ln -s "$ACCOUNT" "$TOOLS/meetingtranscriber-home"
    ! prepare >/dev/null && account_intact
}

# The tests run with CFFIXED_USER_HOME on this home, so a Library linked into
# the account's would put the models into the account's Application Support.
test_library_linked_into_the_account_is_refused() {
    setup
    mkdir -p "$HOME_DIR"
    ln -s "$ACCOUNT/Library" "$HOME_DIR/Library"
    # Refused by the Library guard itself, not by something earlier.
    local err
    err=$(HOME="$ACCOUNT" bash "$SCRIPT" "$TOOLS" mini-1 2>&1 >/dev/null) && return 1
    grep -q "Library is a symlink" <<<"$err" && account_intact
}

test_local_linked_into_the_account_is_refused() {
    setup
    mkdir -p "$HOME_DIR"
    ln -s "$ACCOUNT/.local" "$HOME_DIR/.local"
    ! prepare >/dev/null && account_intact
}

test_local_bin_linked_into_the_account_is_refused() {
    setup
    mkdir -p "$HOME_DIR/.local"
    ln -s "$ACCOUNT/.local/bin" "$HOME_DIR/.local/bin"
    ! prepare >/dev/null && account_intact
}

# An earlier version linked the account's Keychains folder into the home.
test_stale_keychains_link_is_unlinked_not_followed() {
    setup
    mkdir -p "$HOME_DIR/Library"
    ln -s "$ACCOUNT/Library/Keychains" "$HOME_DIR/Library/Keychains"
    prepare >/dev/null && [ ! -e "$HOME_DIR/Library/Keychains" ] && [ ! -L "$HOME_DIR/Library/Keychains" ] &&
        account_intact
}

test_runner_name_with_a_slash_is_refused() {
    setup
    ! HOME="$ACCOUNT" bash "$SCRIPT" "$TOOLS" ../.. >/dev/null 2>&1 && account_intact
}

run_test test_fresh_home_gets_the_ffmpeg_link
run_test test_rerun_is_idempotent
run_test test_home_linked_to_the_account_is_refused
run_test test_home_linked_elsewhere_in_the_account_creates_nothing_there
run_test test_base_linked_into_the_account_is_refused
run_test test_library_linked_into_the_account_is_refused
run_test test_local_linked_into_the_account_is_refused
run_test test_local_bin_linked_into_the_account_is_refused
run_test test_stale_keychains_link_is_unlinked_not_followed
run_test test_runner_name_with_a_slash_is_refused

exit "$FAILED"
