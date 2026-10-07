# Shared helpers for the dev-app e2e scripts. Source this file from a
# bash script that has already set `set -euo pipefail`.
#
#   source "$ROOT/scripts/lib/e2e-helpers.sh"
#   quit_running_app
#   bootout_stale_launchctl
#   wait_for_rpc "$MTCLI"
#   restore_bool_default "$DEV_BUNDLE_ID" autoWatch "$SAVED"
#
# This file has no shebang and no `set -e` — it inherits the caller's.
# Sourcing it also gives the caller $RELEASE_BUNDLE_ID / $DEV_BUNDLE_ID, so no
# driver has to restate an identifier that only Info.plist should own, plus
# resign_deployed_bundle, which every driver that deploys a bundle needs.

# shellcheck source=bundle-ids.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bundle-ids.sh"
# shellcheck source=signing.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/signing.sh"

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
    local bundle_id="${1:-$DEV_BUNDLE_ID}"
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

# Boot out stale launchctl entries for `$DEV_BUNDLE_ID.*`.
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
        | awk -v id="$DEV_BUNDLE_ID" 'index($3, id) == 1 {print $3}' \
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

# Write a dev-bundle default so the RUNNING APP actually sees it.
#
# Say once per run that this host redirects `defaults <bundle-id>` into a
# container, so the next time one appears it carries a timestamp in a log
# instead of surfacing days later as a lane that configures nothing.
_CONTAINER_WARNED=""
_warn_once_about_container() {
    local bundle="$1"
    [ -n "$_CONTAINER_WARNED" ] && return 0
    if [ -d "$HOME/Library/Containers/$bundle" ]; then
        _CONTAINER_WARNED=1
        echo "note: $HOME/Library/Containers/$bundle exists, so \`defaults <bundle-id>\` is redirected there." >&2
        echo "note: lane settings are written to $(dev_standard_plist "$bundle") instead. Remove the container to clear the redirect." >&2
    fi
    return 0
}

# The write that matters is the FIRST one: the standard-domain plist, because a
# non-sandboxed app resolves its UserDefaults there and the dev .app is not
# sandboxed. Writing it by absolute path was measured coherent with cfprefsd on
# macOS 26.6.2 in every configuration tried: cold and warm daemon cache, file
# absent or present, container present or absent, and a live client that does
# its own set plus synchronize after an external write. No failure window, so
# this is not a race the lanes keep winning by luck.
#
# `defaults write <bundle-id>` is deliberately NOT used. cfprefsd redirects it
# into the app's container, and the trigger is a container that
# containermanagerd has REGISTERED for the identifier, not the directory merely
# existing: creating the path by hand does not redirect, and `rm -rf` of a
# registered container stops the redirect without the directory coming back.
# That removal is the operational cure on a host that has one. What created the
# container on the runner is NOT established, and it was not this repo:
# build_release.sh signs even the App Store variant with the release
# identifier, and that workflow runs on a GitHub-hosted image.
#
# The container plist is written only when it already exists, so a lane never
# creates one. Feeding a domain nothing reads would leave a future sandboxed
# build under this identifier starting up with a test lane's settings.
#
# Measured on the self-hosted runner: with only the redirected write, every
# setting a lane wrote was invisible to the app, which is how e2e-app and
# e2e-browser came to fail with no record-only sidecar and no error anywhere.
#
# `type` is one of bool / int / float / string (default string).
write_dev_default() {
    local bundle="$1" key="$2" value="$3" type="${4:-string}"
    local -a args
    case "$type" in
        bool) args=(-bool "$value") ;;
        int) args=(-int "$value") ;;
        float) args=(-float "$value") ;;
        *) args=("$value") ;;
    esac
    /usr/bin/defaults write "$(dev_standard_plist "$bundle")" "$key" "${args[@]}" 2>/dev/null || true
    _warn_once_about_container "$bundle"
    local container
    container="$(dev_container_plist "$bundle")"
    if [ -f "$container" ]; then
        /usr/bin/defaults write "$container" "$key" "${args[@]}" 2>/dev/null || true
    fi
    return 0
}

# Delete a dev-bundle default from every domain `write_dev_default` writes.
# Deleting only some of them leaves the app reading a stale value from the one
# that was missed, which looks exactly like the delete having had no effect.
delete_dev_default() {
    local bundle="$1" key="$2"
    /usr/bin/defaults delete "$(dev_standard_plist "$bundle")" "$key" 2>/dev/null || true
    local container
    container="$(dev_container_plist "$bundle")"
    if [ -f "$container" ]; then
        /usr/bin/defaults delete "$container" "$key" 2>/dev/null || true
    fi
    return 0
}

# Read the EFFECTIVE value of a dev-bundle default the way the app resolves it.
# The dev .app is NOT sandboxed, so it resolves its UserDefaults from the
# standard domain, and that is what this returns when the file exists. The
# container copy is only a fallback for a host where the standard plist has not
# been created yet; a plain `defaults read <bundle> <key>` cannot stand in for
# either, because cfprefsd redirects it into the container whenever one exists.
# Empty when unset. Only e2e-app.sh calls this, for a diagnostic log line rather
# than an assertion; it exists so a reader does not re-derive the container
# redirect by hand. Mutating a dev default needs `write_dev_default`; this is
# for verification and readback only.
read_dev_default_effective() {
    local bundle="$1"
    local container_plist="$2"
    local key="$3"
    local standard_plist
    standard_plist="$(dev_standard_plist "$bundle")"
    if [ -f "$standard_plist" ]; then
        /usr/bin/defaults read "$standard_plist" "$key" 2>/dev/null || true
    elif [ -f "$container_plist" ]; then
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

# Common German words, matched whole. Function words rather than words from the
# fixture's script, because the live lane cannot choose which part of the
# meeting it records: the app starts recording only once it has DETECTED the
# meeting, so the opening seconds are never captured and the remaining slice
# shifts run to run. Measured over 13 runs, a content-word list drawn from the
# script matched exactly [Status Entwicklung] twelve times and [Entwicklung]
# once — a ceiling of 2 against a floor of 2, so the gate was one dropped word
# from red while nothing was wrong with the recording.
#
# What the gate is actually for is unchanged: catching an English hallucination
# or garbage that got past the size check. Any German speech carries several of
# these; English carries none.
# Kept broad on purpose: the margin comes from the list being long enough that
# any few German sentences hit several, not from a low threshold.
GERMAN_MARKER_WORDS=(
    und die der den das ein ist sind nicht noch mit für haben wir ich
)
GERMAN_MARKER_WORDS_MIN=3

# True when the transcript reads as German. Word-boundary matching (`-w`) is
# load-bearing: with substring matching, English "submit"/"listed"/"sound"
# contain mit/ist/und and fluent English would pass the very check meant to
# reject it.
transcript_is_german() {
    local transcript_path="$1"
    local matched=0 hit="" word
    for word in "${GERMAN_MARKER_WORDS[@]}"; do
        if grep -qiw -- "$word" "$transcript_path" 2>/dev/null; then
            matched=$(( matched + 1 )); hit="$hit $word"
        fi
    done
    GERMAN_MARKER_HITS="${hit# }"
    GERMAN_MARKER_MATCHED="$matched"
    [ "$matched" -ge "$GERMAN_MARKER_WORDS_MIN" ]
}

# _pid_is_alive <pid> — does this process exist, whether or not we may signal it.
#
# `kill -0` answers a different question: "may I signal it". It fails the same
# way for a dead pid and for a live one owned by somebody else, so a guard whose
# whole purpose is not to fail open cannot rest on it alone. Measured: `kill -0 1`
# reports "Operation not permitted" and exits 1 while launchd is plainly
# running. `ps -p` answers existence regardless of ownership.
_pid_is_alive() {
    kill -0 "$1" 2>/dev/null && return 0
    ps -p "$1" >/dev/null 2>&1
}

# _no_pid_alive <pid>... — the pids arrive as separate arguments rather than as
# one string on purpose. Splitting a string depends on the CALLER's IFS, and a
# caller with IFS unset of its space turns both the kill and the check into
# no-ops whose failures cancel into a false success. Measured on two live
# processes with IFS set to newline: reported gone, both still running.
_no_pid_alive() {
    local pid
    for pid in "$@"; do
        _pid_is_alive "$pid" && return 1
    done
    return 0
}

# kill_and_verify_gone <pattern> [timeout_s] — SIGKILL every process matching
# `pattern` and prove those processes are gone. Returns 1 when the pattern
# matched nothing, when pgrep could not answer, and when a victim is still
# alive after `timeout_s`.
#
# `pkill` reports "matched nothing" and "killed it" identically to a caller that
# discards the status, and a lane that kills and then asserts on files cannot
# tell the two apart: a live process leaves the files in exactly the state the
# assertions expect.
#
# THE WHOLE SEQUENCE LIVES HERE, and that is the point. An earlier draft of this
# same change only waited for the pattern to stop matching, which reads "gone" on
# the first tick when the pattern matches nothing — the likeliest failure of all,
# since a pattern is a path fragment and paths get renamed. A caller cannot fix
# that by checking first either, because the process can exit on its own between
# its check and its kill. So the victims are captured once, before the signal,
# and it is THOSE PROCESS IDS that have to disappear.
#
# Watching ids rather than the pattern also matters on a shared host: the pattern
# names a deploy path that every lane and the console user share, so another
# process matching it can appear while this one waits. An empty victim list is a
# refusal rather than an early success, because having nothing to wait for and
# having killed something are opposite facts.
kill_and_verify_gone() {
    local pattern="$1" timeout_s="${2:-10}" raw status=0 pid
    local -a victims=()

    # `--` because a pattern may begin with a dash, which pgrep would otherwise
    # read as an option; measured, it exits 2 for a usage error. And the status
    # is examined rather than discarded: 1 means no match, anything above it
    # means pgrep could not answer, and reporting that as "matched no process"
    # would be a confident wrong diagnosis.
    raw="$(pgrep -f -- "$pattern")" || status=$?
    if [ "$status" -gt 1 ]; then
        echo "kill_and_verify_gone: pgrep failed with status $status for '$pattern'," >&2
        echo "  so whether anything matched is unknown. Refusing rather than guessing." >&2
        return 1
    fi

    while IFS= read -r pid; do
        if [ -n "$pid" ]; then
            victims+=("$pid")
        fi
    done <<< "$raw"

    if [ "${#victims[@]}" -eq 0 ]; then
        echo "kill_and_verify_gone: '$pattern' matched no process, so the kill would" >&2
        echo "  be a no-op. Refusing rather than reporting a kill that never happened:" >&2
        echo "  everything a caller does after this point is equally true of a process" >&2
        echo "  that is still running." >&2
        return 1
    fi

    kill -KILL "${victims[@]}" 2>/dev/null || true

    if poll_until "$timeout_s" 0.2 _no_pid_alive "${victims[@]}"; then
        return 0
    fi
    echo "kill_and_verify_gone: still alive after ${timeout_s}s despite SIGKILL:" >&2
    for pid in "${victims[@]}"; do
        _pid_is_alive "$pid" && echo "    pid $pid" >&2
    done
    return 1
}

# Files a completed pipeline would have written under the output folder, newer
# than `marker`. The record-only lanes use this as a negative assertion:
# record-only short-circuits before transcription and protocol generation, so a
# `.txt` or `.md` belonging to this meeting means the pipeline ran when it must
# not have.
#
# Searches the output ROOT rather than one subdirectory, deliberately. The
# transcript and the protocol land in `<output>/protocols` while the audio and
# its sidecar land in `<output>/recordings`, and pinning the search to the
# recordings directory is how this assertion came to be satisfied
# unconditionally: no `.txt` or `.md` can appear there in either the working or
# the broken world. Searching from the root cannot be outlived by a change to
# which subdirectory the app writes into.
#
# record_only_violation <state-json> <expected-last-job-id> — why the pipeline
# is not idle, or nothing at all when it is.
#
# Two observations, and the second is the one a record-only lane was missing.
# `lastJob` is the last FINISHED job, so a job that is still waiting or
# transcribing is invisible to it, and the transcript that would betray the same
# job is written near the END of the pipeline. A lane checking both a few
# seconds after the recording stops would therefore pass while a regression was
# busy transcribing, which is precisely what record-only forbids.
#
# The queue counters see exactly the states `lastJob` hides. Together the two
# turn "nothing finished" into "nothing ran", which is the actual promise.
#
# Pure on purpose: it takes the snapshot rather than fetching it, so the
# decision can be exercised against crafted state without an app.
record_only_violation() {
    local snapshot="$1" expected_id="$2" lj_id in_flight
    lj_id="$(jq -r '.lastJob.jobID // empty' <<<"$snapshot")"
    if [ "$lj_id" != "$expected_id" ]; then
        printf 'lastJob.jobID changed to %s (was %s)' "${lj_id:-<none>}" "${expected_id:-<none>}"
        return 0
    fi
    # No `// 0` default. An absent counter and a counter reading zero are
    # opposite facts: the first means the snapshot cannot answer the question,
    # which a renamed field or an older app would produce, and defaulting it to
    # zero would make this assertion quietly stop looking while still reporting
    # success. That is the failure this whole check exists to remove.
    in_flight="$(jq -r 'if (.pipeline.activeJobCount == null) or (.pipeline.waitingJobCount == null)
                        then "unknown"
                        else (.pipeline.activeJobCount + .pipeline.waitingJobCount) end' <<<"$snapshot")"
    if [ "$in_flight" = unknown ]; then
        printf 'the pipeline job counters are missing from /state, so whether a job is in flight cannot be told'
        return 0
    fi
    if [ "${in_flight:-0}" != 0 ]; then
        printf '%s pipeline job(s) waiting or running' "$in_flight"
        return 0
    fi
}

# NOT LOOKING IS NOT THE SAME AS FINDING NOTHING, and both callers read this
# function's OUTPUT, so the distinction has to live in its status. Two ways to
# come back empty without having looked, both measured:
#
#   - `find` exits 1 when a subtree cannot be read, having printed its complaint
#     to stderr and nothing to stdout. Leaving stderr visible makes that legible
#     in a log and changes nothing for the caller, which sees an empty string
#     and calls it clean.
#   - a directory that is not there yields nothing at all.
#
# The second is worth refusing rather than tolerating precisely because this
# lane now asserts the app resolved this exact path: if it then does not exist,
# something is wrong somewhere else, and answering "no artifacts" would report
# that as a pass.
#
# So: 0 and output means artifacts were found, 0 and no output means the tree was
# read and is clean, and 2 means the question could not be answered. Callers must
# separate the last one, or the fail-open comes straight back.
pipeline_output_artifacts() {
    local output_dir="$1" marker="$2" found status=0

    # Belt and braces, and deliberately so: `find` fails on a missing directory
    # by itself and would reach the same refusal below. This branch exists to
    # say WHY in the one case that has a likely cause, so removing it costs a
    # diagnosis rather than the verdict.
    if [ ! -d "$output_dir" ]; then
        echo "pipeline_output_artifacts: $output_dir does not exist, so nothing could be" >&2
        echo "  looked at. Refusing rather than reporting an empty tree as a clean one." >&2
        return 2
    fi

    # `-L` because BSD find defaults to -P and will not descend a symlink, while
    # `test -d` above follows one. Measured: with the output folder itself, or
    # just `protocols/` inside it, symlinked elsewhere, the search returned
    # nothing and status 0 while a transcript sat plainly behind the link. For a
    # NEGATIVE assertion, following links is also the safe direction: seeing more
    # can only make this fail, never pass.
    found="$(find -L "$output_dir" -type f -newer "$marker" \
        \( -name '*.txt' -o -name '*.md' \))" || status=$?
    if [ "$status" -ne 0 ]; then
        echo "pipeline_output_artifacts: find exited $status under $output_dir, so whether" >&2
        echo "  the pipeline wrote anything is unknown. Reporting that as clean is the" >&2
        echo "  defect this function exists to remove." >&2
        return 2
    fi
    printf '%s' "$found"
}

# snapshot_new_job_ids <snapshot.json> <title> [known-id...] — the ids of the
# jobs in a pipeline snapshot file titled exactly <title> and not among the
# known ids, one per line. Used by the --quit-flush lane to read what a quit
# left on disk, after the process is gone and before anything relaunches.
#
# Status 2 when the file is missing or does not parse: that is not the same
# as "the job is absent", and the lane reports the two differently. Empty
# output with status 0 means the file was read and holds no such job.
snapshot_new_job_ids() {
    local snapshot="$1" title="$2"
    shift 2
    if [ ! -f "$snapshot" ]; then
        echo "snapshot_new_job_ids: no snapshot at $snapshot" >&2
        return 2
    fi
    # Validate before extracting. `jq -e` cannot carry both answers: measured
    # with jq 1.7, a torn file exits 4, the same status as "no output", so a
    # half-written snapshot would read as one that lacks the job.
    if ! jq -e 'type == "array"' "$snapshot" >/dev/null 2>&1; then
        echo "snapshot_new_job_ids: $snapshot does not parse as a job array" >&2
        return 2
    fi
    local known
    known="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
    jq -r --arg title "$title" --argjson known "$known" \
        '.[] | select(.meetingTitle == $title) | .id | select(. as $id | $known | index($id) | not)' \
        "$snapshot"
}

# Must equal `PersistentDiagnosticLog.streamPredicate`. A drift cannot pass
# silently: the --quit-flush lane asserts at launch that the app has exactly
# one child matching it, so a changed predicate fails there, before the
# orphan check that relies on it could report a false "none left".
MT_LOG_STREAM_PREDICATE="subsystem CONTAINS 'com.meetingtranscriber'"

# streamer_pids <parent-pid> — read a `ps -axo pid=,ppid=,command=` table on
# stdin and print the pids of the app's persistent-log `log stream` processes
# whose parent is <parent-pid>, one per line. Parent 1 asks for orphans: a
# streamer that outlived its app is re-parented to launchd. The predicate
# match keeps a user's own `log stream` out of it.
streamer_pids() {
    local parent="$1"
    awk -v parent="$parent" -v pred="$MT_LOG_STREAM_PREDICATE" '
        $2 == parent && $3 == "/usr/bin/log" && $4 == "stream" && index($0, pred) { print $1 }
    '
}

# queue_snapshot_is_empty <pipeline_queue.json> — 0 when the snapshot holds no
# job (exactly an empty array, or no file at all: nothing was ever queued),
# 1 when it holds any job, 2 when it does not parse. A lane that adds jobs to
# the shared queue and restores it afterwards may only start from empty.
queue_snapshot_is_empty() {
    local snapshot="$1"
    [ -f "$snapshot" ] || return 0
    jq -e 'type == "array"' "$snapshot" >/dev/null 2>&1 || return 2
    jq -e 'length == 0' "$snapshot" >/dev/null 2>&1
}

# backup_state_files <src-dir> <backup-dir> <name>... — copy each named file
# with its metadata. Names that do not exist are listed in <backup-dir>/.absent
# so a restore can tell "absent before" from "lost from the backup".
backup_state_files() {
    local src="$1" dst="$2" name
    shift 2
    mkdir -p "$dst"
    : >"$dst/.absent"
    for name in "$@"; do
        if [ -f "$src/$name" ]; then
            cp -p "$src/$name" "$dst/$name" || return 1
        else
            printf '%s\n' "$name" >>"$dst/.absent"
        fi
    done
}

# compare_state_files <backup-dir> <dir> <name>... — read-only SHA-256 compare,
# one line per name: "<name>: match", "<name>: MISMATCH (...)", "<name>:
# absent before, still absent", or "<name>: absent before, now present". Status
# 1 when any backed-up file differs or a file absent before is present now: the
# shared state did not end as it began.
compare_state_files() {
    local backup="$1" dir="$2" name status=0 want got
    shift 2
    for name in "$@"; do
        if grep -qx "$name" "$backup/.absent" 2>/dev/null; then
            if [ -f "$dir/$name" ]; then
                echo "$name: absent before, now present"
                status=1
            else
                echo "$name: absent before, still absent"
            fi
            continue
        fi
        want="$(shasum -a 256 "$backup/$name" 2>/dev/null | cut -d' ' -f1)"
        got="$(shasum -a 256 "$dir/$name" 2>/dev/null | cut -d' ' -f1)"
        if [ -n "$want" ] && [ "$want" = "$got" ]; then
            echo "$name: match ($want)"
        else
            echo "$name: MISMATCH (backup ${want:-missing}, now ${got:-missing})"
            status=1
        fi
    done
    return "$status"
}

# state_file_records <file> <name> — the records of a shared state file, one per
# line: job ids (lowercased) for the queue, the terminal-job store and the
# pipeline log, paths for the processed-recordings ledger. Status 2 when the
# file does not parse or <name> is not a file this helper knows.
state_file_records() {
    local file="$1" name="$2" filter slurp=()
    case "$name" in
        pipeline_queue.json) filter='.[] | .id | ascii_downcase' ;;
        terminal_jobs.json) filter='.[] | .jobID | ascii_downcase' ;;
        pipeline_log.jsonl) filter='.[] | .job_id | ascii_downcase'; slurp=(-s) ;;
        processed_recordings.json) filter='.[]' ;;
        *) return 2 ;;
    esac
    jq -e ${slurp[@]+"${slurp[@]}"} 'type == "array" and all(.[]; . != null)' "$file" >/dev/null 2>&1 || return 2
    jq -r ${slurp[@]+"${slurp[@]}"} "$filter" "$file" 2>/dev/null || return 2
}

# state_file_foreign_records <file> <name> <ids-file> <paths-file> [<backup>] —
# print each record of <file> that is neither this run's (a job id in
# <ids-file>, or for the ledger a path in <paths-file>) nor already in the
# backed-up copy <backup>. Nothing printed means everything in it is the run's
# or was there before. Status 2 when either file does not parse.
state_file_foreign_records() {
    local file="$1" name="$2" ids="$3" paths="$4" backup="${5:-}" records known
    records="$(state_file_records "$file" "$name")" || return 2
    if [ "$name" = processed_recordings.json ]; then
        known="$(cat "$paths" 2>/dev/null)"
    else
        known="$(tr '[:upper:]' '[:lower:]' <"$ids" 2>/dev/null)"
    fi
    if [ -n "$backup" ]; then
        known="$known
$(state_file_records "$backup" "$name")" || return 2
    fi
    [ -n "$records" ] || return 0
    grep -Fxv -f <(printf '%s\n' "$known" | grep -v '^$' || true) <<<"$records" || true
}

# restore_state_files <backup-dir> <dir> <ids-file> <paths-file> <name>... —
# put the shared state back as the backup found it, then report the compare.
# Only this run's records may have changed in the meantime, so each file is
# checked first (state_file_foreign_records):
#   existed before: copied back byte for byte when everything added since the
#     backup is the run's;
#   absent before: removed when everything in it is the run's, so the run
#     created it.
# The pipeline log is append-only and its history holds torn fragments that do
# not parse, so for it the check is on what the run appended: the backup must
# be a byte prefix of the file, and every appended line the run's.
# A file holding anyone else's record, or one that does not parse, is left as
# it is, said so, and the compare fails: a blind copy would erase what another
# writer added after the backup, and keeping it quietly would leave the run's
# records in the app's data.
restore_state_files() {
    local backup="$1" dir="$2" ids="$3" paths="$4" name status foreign
    shift 4
    for name in "$@"; do
        local before=""
        grep -qx "$name" "$backup/.absent" 2>/dev/null || before="$backup/$name"
        if [ -z "$before" ] && [ ! -f "$dir/$name" ]; then continue; fi
        if [ -n "$before" ] && [ "$name" = pipeline_log.jsonl ] && [ -f "$dir/$name" ]; then
            # Append-only, and its history is not all JSON (torn fragments of
            # earlier interleaved appends): check only what the run appended.
            local size appended
            size="$(stat -f%z "$before")"
            if ! head -c "$size" "$dir/$name" | cmp -s - "$before"; then
                echo "$name: NOT RESTORED, no longer an append of the backup"
                continue
            fi
            appended="$(mktemp)"
            tail -c +"$((size + 1))" "$dir/$name" >"$appended"
            status=0
            foreign="$(state_file_foreign_records "$appended" "$name" "$ids" "$paths")" || status=$?
            rm -f "$appended"
            if [ "$status" -ne 0 ]; then
                echo "$name: NOT RESTORED, what was appended since the backup does not parse"
                continue
            fi
            if [ -n "$foreign" ]; then
                echo "$name: NOT RESTORED, appended records that are not this run's: $(tr '\n' ' ' <<<"$foreign")"
                continue
            fi
            cp -p "$before" "$dir/$name" || echo "$name: restore copy FAILED"
            continue
        fi
        if [ -f "$dir/$name" ]; then
            status=0
            foreign="$(state_file_foreign_records "$dir/$name" "$name" "$ids" "$paths" "$before")" || status=$?
            if [ "$status" -ne 0 ]; then
                echo "$name: NOT RESTORED, does not parse, so what changed in it since the backup cannot be told apart"
                continue
            fi
            if [ -n "$foreign" ]; then
                echo "$name: NOT RESTORED, holds records neither in the backup nor this run's: $(tr '\n' ' ' <<<"$foreign")"
                continue
            fi
        fi
        if [ -z "$before" ]; then
            rm -f "$dir/$name" && echo "$name: created by this run (only its records), removed"
        else
            cp -p "$before" "$dir/$name" || echo "$name: restore copy FAILED"
        fi
    done
    compare_state_files "$backup" "$dir" "$@"
}

# remove_state_backup <backup-dir> <name>... — remove a backup taken by
# backup_state_files for these names, once the state matched it: only the
# files it wrote (each name, and .absent), then the directory if that leaves
# it empty. Status 1, and the directory left, when anything else is in it.
remove_state_backup() {
    local backup="$1" name
    shift
    for name in "$@" .absent; do
        rm -f "$backup/$name"
    done
    rmdir "$backup" 2>/dev/null || { echo "backup $backup holds files it did not write; left in place"; return 1; }
}
