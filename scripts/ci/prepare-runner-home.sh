#!/usr/bin/env bash
# Prepares a self-hosted runner's own test home and prints its physical path.
# Used by .github/actions/runner-home; tested by
# scripts/tests/test_prepare_runner_home.sh.
#
# Usage: prepare-runner-home.sh <tool-cache-dir> <runner-name>
#   $HOME must be the account's real home (the step's own environment).
#
# The home is <tool-cache>/meetingtranscriber-home/<runner-name>. The tests run
# with CFFIXED_USER_HOME pointed there, which moves NSHomeDirectory(), so an
# ffmpeg in the account's ~/.local/bin, one of the places FFmpegHelper looks,
# is linked in; without it the ffmpeg tests would start skipping.
#
# Each folder the script creates or writes in (the base, the home, its
# Library, and the .local/bin chain to the ffmpeg link) is checked before
# anything is created in it: none may be a symlink, and each must resolve
# physically to exactly where it should. The test home must never turn out to
# be the account's own home, or a folder inside it that other jobs use. Library
# matters beyond this script: the tests resolve Application Support and Caches
# inside it.

set -euo pipefail

tool_cache=${1:?tool cache dir required}
runner_name=${2:?runner name required}

fail() {
    echo "::error::prepare-runner-home: $*" >&2
    exit 1
}

case "$runner_name" in
    "" | . | .. | */* | .*) fail "unusable runner name '$runner_name'" ;;
esac

account=$(cd "$HOME" && pwd -P) || fail "cannot resolve HOME"
tool_cache_p=$(cd "$tool_cache" && pwd -P) || fail "cannot resolve tool cache $tool_cache"

# own_dir <parent-physical-path> <name>: creates <parent>/<name> unless it is a
# symlink, then checks it resolves to exactly that path; prints the path.
own_dir() {
    local dir="$1/$2"
    [ ! -L "$dir" ] || fail "$dir is a symlink"
    mkdir -p "$dir" || fail "cannot create $dir"
    local resolved
    resolved=$(cd "$dir" && pwd -P) || fail "cannot resolve $dir"
    [ "$resolved" = "$dir" ] || fail "$dir resolves to $resolved"
    echo "$dir"
}

base=$(own_dir "$tool_cache_p" meetingtranscriber-home)
home=$(own_dir "$base" "$runner_name")
[ "$home" != "$account" ] || fail "test home $home is the account's home"
case "$home/" in
    "$account/Library/"* | "$account/Documents/"*)
        fail "test home $home is inside the account's Library or Documents ($account)" ;;
esac

# Before anything is written inside the home: the tests resolve Application
# Support and Caches inside its Library, so a Library linked into the
# account's would put the models straight back into the account's folders.
library=$(own_dir "$home" Library)

# An earlier version linked the account's Keychains folder in here. Removed
# (the link only, never what it points at), so nothing under the test home
# leads back into the account's keychains.
if [ -L "$library/Keychains" ]; then
    rm "$library/Keychains"
fi

if [ -x "$account/.local/bin/ffmpeg" ]; then
    # Two steps: a failure inside a nested substitution would not stop this.
    local_dir=$(own_dir "$home" .local)
    bin=$(own_dir "$local_dir" bin)
    ln -sfn "$account/.local/bin/ffmpeg" "$bin/ffmpeg"
fi

echo "$home"
