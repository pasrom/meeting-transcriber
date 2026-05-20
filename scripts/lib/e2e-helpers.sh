# Shared helpers for the dev-app e2e scripts. Source this file from a
# bash script that has already set `set -euo pipefail`.
#
#   source "$ROOT/scripts/lib/e2e-helpers.sh"
#   quit_running_app
#   bootout_stale_launchctl
#   wait_for_rpc "$MTCLI"
#   restore_bool_default com.meetingtranscriber.dev autoWatch "$SAVED"
#
# This file has no shebang and no `set -e` — it inherits the caller's.

# Graceful AppleScript quit → SIGTERM → SIGKILL ladder. Returns 0 when
# the process is gone, 1 if it survived even SIGKILL (unusual; means
# the process is wedged in a kernel call). The bundle id can be
# overridden for the rare case a forked dev variant uses a different one.
#
# Timing budget: up to ~3 s for graceful AppleScript quit, then ~3 s
# for SIGTERM grace, then SIGKILL with a 1 s reap window. Total worst
# case ~7 s. The pre-extraction inline ladders ran with shorter
# windows (3 s or 5 s total); the merged version is strictly more
# graceful and never sends SIGTERM/SIGKILL when the process has
# already exited.
quit_running_app() {
    local bundle_id="${1:-com.meetingtranscriber.dev}"
    # Default pattern matches the dev bundle. Release-bundle callers
    # (e.g. test_rpc.sh against the homebrew-cask binary) override by
    # passing a second arg.
    local pattern="${2:-MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber}"
    if ! pgrep -f "$pattern" >/dev/null; then
        return 0
    fi
    osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
    for _ in 1 2 3; do
        pgrep -f "$pattern" >/dev/null || return 0
        sleep 1
    done
    pkill -f "$pattern" 2>/dev/null || true
    for _ in 1 2 3; do
        pgrep -f "$pattern" >/dev/null || return 0
        sleep 1
    done
    pkill -KILL -f "$pattern" 2>/dev/null || true
    # Mirror the post-TERM ladder for the post-KILL reap. A process
    # wedged in a kernel call can take longer than one `sleep 1` to
    # be reaped — a single check would false-negative.
    for _ in 1 2 3; do
        pgrep -f "$pattern" >/dev/null || return 0
        sleep 1
    done
    echo "ERROR: could not stop running MeetingTranscriber — kill it manually and retry" >&2
    return 1
}

# Boot out stale launchctl entries for `com.meetingtranscriber.dev.*`.
# A previous run that exited ungracefully can leave per-PID service
# registrations in `gui/<uid>` even after the process is dead, which
# in turn can hold per-bundle TCC state or block re-launches. Safe to
# call repeatedly; the awk filter scopes the cleanup to our bundle so
# it never touches unrelated services.
bootout_stale_launchctl() {
    # `|| true` swallows pipefail when `launchctl list` exits non-zero
    # (e.g. an SSH session without a `gui/<uid>` domain) so callers
    # outside an EXIT trap aren't taken down by a best-effort cleanup.
    { launchctl list 2>/dev/null \
        | awk '$3 ~ /com\.meetingtranscriber\.dev/ {print $3}' \
        | while read -r srv; do
            launchctl bootout "gui/$(id -u)/$srv" 2>/dev/null || true
        done
    } || true
}

# Poll mt-cli healthz until the dev RPC server responds or `timeout`
# seconds elapse. Returns 0 on success, 1 on timeout, 2 on
# misconfiguration (mtcli path not executable — fail fast rather than
# burn the full timeout silently). Default timeout 30 s matches the
# dev-app cold-start budget on a Mac mini.
wait_for_rpc() {
    local mtcli="${1:?mt-cli binary path required}"
    local timeout="${2:-30}"
    if [ ! -x "$mtcli" ]; then
        echo "wait_for_rpc: $mtcli is not executable" >&2
        return 2
    fi
    # Probe-then-sleep so a warm restart (RPC already up) returns
    # immediately and an app that becomes ready right at `timeout`
    # still gets one last probe before we give up.
    local _
    for _ in $(seq 1 "$timeout"); do
        if "$mtcli" healthz >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    "$mtcli" healthz >/dev/null 2>&1
}

# Restore a defaults boolean from a snapshotted value as returned by
# `defaults read`. That command returns "0"/"1" but `-bool` only
# accepts the literal tokens `true`/`false`/`yes`/`no`; without this
# translation the cleanup path bails out on the first restore call
# and prints the defaults usage screen. Empty `saved` (key wasn't set
# before the test) deletes the key.
restore_bool_default() {
    local bundle="$1"
    local key="$2"
    local saved="$3"
    case "$saved" in
        1) /usr/bin/defaults write "$bundle" "$key" -bool true ;;
        0) /usr/bin/defaults write "$bundle" "$key" -bool false ;;
        *) /usr/bin/defaults delete "$bundle" "$key" 2>/dev/null || true ;;
    esac
}
