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

# Print "FAIL: <msg>" to stderr and exit 1. The e2e drivers fail-fast
# on the first error, so a one-liner is more readable than the
# `{ echo "FAIL: …" >&2; exit 1; }` block that gets repeated across
# `||` chains and bare guards.
#
# Callers that need a script-specific prefix (e.g. e2e-app.sh's
# `[e2e-app] FAIL:`) keep their own local `fail()` — `die()` is for
# scripts that don't have one yet.
die() {
    echo "FAIL: $*" >&2
    exit 1
}

# Assert that a process matching `$pattern` is running. Exits 1 with a
# clear error if not. Intended for polling loops that would otherwise
# burn their full timeout if the app crashed mid-poll — the loop just
# sees `{}` (or no /state response) and surfaces a misleading
# "expected X never happened" error.
#
# Pattern-based (via `pgrep -f`) rather than PID-based so it works for
# both `&`-launched scripts (e2e-silent-recording.sh) and
# `open`-launched scripts (e2e-app.sh) without two APIs. The default
# matches the deployed dev .app — same string as `quit_running_app`.
assert_app_alive() {
    local pattern="${1:-MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber}"
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
        die "app process matching '$pattern' is not running"
    fi
}

# Poll a predicate until it succeeds or a timeout elapses. The loop
# mechanics (deadline tracking, probe-then-sleep, timeout result) live
# here so the e2e drivers stop re-deriving them inline.
#
# Usage: poll_until <timeout_s> <interval_s> <predicate> [args...]
#
# <predicate> is a command — typically a shell function — re-run each
# tick in the CURRENT shell, so it can both read and assign caller-scope
# variables (e.g. stash a parsed /state field for post-loop asserts).
# Running in an `if` condition also suspends `set -e` for the predicate
# body, so intermediate `jq`/`curl` hiccups don't abort the script.
# Probe-then-sleep: an already-true condition returns on the first tick,
# and one final probe runs right before the deadline check.
#
# Returns 0 on success, 1 on timeout. The caller decides how to report a
# timeout (its own prefixed `fail()`, `die`, or a custom diagnostic
# dump) — this stays agnostic to per-script conventions.
poll_until() {
    local timeout="$1" interval="$2"
    shift 2
    local deadline=$(( $(date +%s) + timeout ))
    while true; do
        if "$@"; then
            return 0
        fi
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep "$interval"
    done
}

# Snapshot a defaults value for later restoration, or empty when the
# key isn't set. The caller's `$()` command substitution strips the
# trailing newline that `defaults read` emits, so internal whitespace
# in string values (e.g. "hello world") is preserved — important once
# this gets used for keys beyond the current numeric/bool callsites.
# Trailing `|| true` keeps a missing key from tripping `set -e`.
snapshot_default() {
    local bundle="$1"
    local key="$2"
    /usr/bin/defaults read "$bundle" "$key" 2>/dev/null || true
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

# Float companion to `restore_bool_default`. Empty `saved` (key wasn't
# set before the test) deletes the key; anything else is written back
# as `-float`. `defaults read` returns floats as plain numeric strings
# (e.g. "30" or "30.5"), and `-float "30"` is happily accepted by
# `defaults write` even without a decimal point.
restore_float_default() {
    local bundle="$1"
    local key="$2"
    local saved="$3"
    if [ -n "$saved" ]; then
        /usr/bin/defaults write "$bundle" "$key" -float "$saved"
    else
        /usr/bin/defaults delete "$bundle" "$key" 2>/dev/null || true
    fi
}

# Integer companion to restore_bool_default / restore_float_default. Empty
# `saved` deletes the key; anything else is written as `-int`. Keys like
# `numSpeakers` are read by the app as `defaults.object(forKey:) as? Int`, so
# they must round-trip through `-int` (a `-float` or bare-string write would
# fail the cast and silently fall back to the default sentinel).
restore_int_default() {
    local bundle="$1"
    local key="$2"
    local saved="$3"
    if [ -n "$saved" ]; then
        /usr/bin/defaults write "$bundle" "$key" -int "$saved"
    else
        /usr/bin/defaults delete "$bundle" "$key" 2>/dev/null || true
    fi
}

# Read the EFFECTIVE value of a dev-bundle default the way the app resolves it.
# The dev `.app` has a pre-existing container at
# `~/Library/Containers/<bundle>/…`, and macOS routes the app's UserDefaults
# reads there regardless of whether the current binary is sandboxed, so a plain
# `defaults read <bundle> <key>` (standard domain) can disagree with what the
# app actually sees. When the container plist exists it wins; else fall back to
# the standard domain. Empty when unset. Shared so e2e-app.sh / e2e-live-captions.sh
# / e2e-cpu-load.sh read their blind `defaults write`s back consistently instead
# of each re-deriving the container redirect. NOTE: mutating a dev default still
# needs BOTH domains written (see the per-domain snapshot/restore in e2e-app.sh);
# this reader is for verification/readback only.
read_dev_default_effective() {
    local bundle="$1"
    local container_plist="$2"
    local key="$3"
    if [ -f "$container_plist" ]; then
        /usr/bin/defaults read "$container_plist" "$key" 2>/dev/null || true
    else
        /usr/bin/defaults read "$bundle" "$key" 2>/dev/null || true
    fi
}

# Delete the recording artifacts THIS run created — every file under `rec_dir`
# newer than `marker` (create the marker before the run starts recording).
# Killing the app mid-recording orphans a raw temp; the next run's app
# crash-recovers it into a garbage job that, once errored, never enters
# processed_recordings.json and so re-enqueues on every launch.
#
# GUARDED to CI via $GITHUB_ACTIONS (never set in a developer's shell): dev and
# prod share the recordings dir on a developer machine, so a local sweep could
# delete a real recording made during the run. Locally the orphans are harmless
# — the next app launch recovers them. `-newer` leaves pre-existing files alone.
sweep_run_artifacts() {
    local rec_dir="$1"
    local marker="$2"
    if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "$marker" ] && [ -d "$rec_dir" ]; then
        find "$rec_dir" -type f -newer "$marker" -delete 2>/dev/null || true
    fi
}
