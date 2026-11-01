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

# Graceful AppleScript quit → SIGTERM → SIGKILL ladder. Returns 0 when the app
# is gone, 2 when it is gone but the AppleScript quit was refused for want of
# the Automation grant (see below), 1 if it survived even SIGKILL (unusual;
# means the process is wedged in a kernel call). The bundle id can be
# overridden for the rare case a forked dev variant uses a different one.
#
# The AppleScript quit is what runs the app's applicationShouldTerminate, and
# with it the quit hold that stops a recording and flushes the pipeline
# snapshots (TerminationFlush in the app: recordingBudget 5 s, then flushBudget
# 2 s, then a second flushBudget 2 s, so up to E2E_APP_QUIT_HOLD_S = 9 s; the
# app has no SIGTERM handler, so a signal skips all of it). The waits are sized
# from that hold, with margin: the Apple Event gets twice the hold to be
# answered, and the process twice the hold to be gone after it.
#
# The Apple Event needs the Automation grant for this job's process to control
# the dev app, and a pending consent prompt for it blocks rather than fails, so
# it runs under run_bounded. What the answer means:
#   - Answered: the hold runs; wait for the process.
#   - Refused (-1743): the grant is missing for certain and the hold never ran.
#     An ::error naming the grant, the signal ladder so the next lane does not
#     inherit the app, and status 2, so a lane does not carry on as if the app
#     had quit.
#   - No answer (-1712, or the bound): a pending prompt, or an app that got the
#     event and is in a modal or nested run loop, or a teardown past its hold.
#     Nothing here tells those apart, so it is no verdict on the grant: wait
#     the same as after an answer; if the app is still there, a ::warning
#     naming all of them, then the signal ladder, and the old outcome (0).
#   - Any other error (-600 not running, -128 cancelled, ...): not a grant
#     question; the short wait the ladder always had, then signals.
#
# Worst case, the unanswered path, as the reaper's grace has to cover it:
# run_bounded for 2 x hold + 5 = 23 s overshoots by at most its whole-second
# wall-clock cap, 25 s; the exit wait of 2 x hold polls whole seconds, 19 s;
# the TERM and KILL waits 4 s each: about 52 s.
: "${E2E_APP_QUIT_HOLD_S:=9}"
_app_gone() { ! pgrep -f "$1" >/dev/null; }
quit_running_app() {
    local bundle_id="${1:-$DEV_BUNDLE_ID}"
    # Default pattern matches the dev bundle. Release-bundle callers
    # (e.g. test_rpc.sh against the homebrew-cask binary) override by
    # passing a second arg.
    local pattern="${2:-MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber}"
    local hold="$E2E_APP_QUIT_HOLD_S" out status=0 verdict gone_status=0 wait_s
    _app_gone "$pattern" && return 0
    out="$(run_bounded $(( hold * 2 + 5 )) osascript \
        -e "with timeout of $(( hold * 2 )) seconds" \
        -e "tell application id \"$bundle_id\" to quit" \
        -e 'end timeout' 2>&1)" || status=$?
    verdict="$(tcc_probe_verdict "$status" "$out")"
    case "$verdict" in
        granted|blocked) wait_s=$(( hold * 2 )) ;;
        denied) wait_s=0 ;;
        *) wait_s=3 ;;
    esac
    if [ "$wait_s" -gt 0 ] && poll_until "$wait_s" 0.2 _app_gone "$pattern"; then
        return 0
    fi
    case "$verdict" in
        denied)
            gone_status=2
            echo "::error title=TCC Automation → MeetingTranscriber-Dev not usable::the AppleScript quit was refused (${out:-exit $status}), so the app's quit hold (stopping a recording, flushing the pipeline snapshots) did not run; ending it by signal instead. Fix: $(tcc_fix_hint 'Automation → MeetingTranscriber-Dev')" >&2
            ;;
        blocked)
            echo "::warning title=dev app did not quit::the AppleScript quit got no answer (${out:-exit $status}) and the app was still running $(( hold * 2 )) s later; ending it by signal, without its quit hold. Possible causes: a pending Automation → MeetingTranscriber-Dev prompt on the runner's screen ($(tcc_fix_hint 'Automation → MeetingTranscriber-Dev')), a modal or nested run loop in the app, or a teardown past its quit budget." >&2
            ;;
    esac
    pkill -f "$pattern" 2>/dev/null || true
    poll_until 3 0.2 _app_gone "$pattern" && return "$gone_status"
    pkill -KILL -f "$pattern" 2>/dev/null || true
    # Mirror the post-TERM wait for the post-KILL reap. A process
    # wedged in a kernel call can take longer than one `sleep 1` to
    # be reaped — a single check would false-negative.
    poll_until 3 0.2 _app_gone "$pattern" && return "$gone_status"
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

# host_skip <lane> <summary> — the lane could not run its assertion for a host
# condition only a person can fix; only a cause that is certainly the host's
# may come here. Returns 0 (the lane passes); in CI it also annotates, writes
# the step summary and lists the lane for fail_on_host_skips. Rationale: the
# e2e-architecture skill, runner setup step 6.
host_skip() {
    local lane="$1" summary="$2"
    echo "[$lane]: SKIP — $summary"
    [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
    echo "::warning title=$lane lane skipped::$summary"
    # A lost entry in the skip list is reported, since the gate reads nothing
    # else; a lost summary line is not.
    step_summary "$(printf '### %s lane skipped\n\n%s' "$lane" "$summary")"
    if [ -n "${RUNNER_TEMP:-}" ] && ! echo "$lane" 2>/dev/null >>"$RUNNER_TEMP/e2e-host-skips"; then
        echo "::error title=$lane skip not recorded::could not write $RUNNER_TEMP/e2e-host-skips, so the scheduled-run gate will not see this skip"
    fi
    return 0
}

# step_summary <markdown> — append a paragraph to the job's step summary.
# Guarded: GITHUB_ACTIONS alone (exported by hand, or under act) does not
# promise $GITHUB_STEP_SUMMARY, and `set -u` would turn a report into a
# failure; a write that fails must not change any outcome either.
step_summary() {
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n\n' "$1" 2>/dev/null >>"$GITHUB_STEP_SUMMARY" || true
}

# fail_on_host_skips — the body of e2e-app.yml's last step on scheduled and
# dispatched runs: exit 1, with an error per lane, when any lane of this job
# called host_skip.
fail_on_host_skips() {
    local skips="${RUNNER_TEMP:-}/e2e-host-skips" lane
    [ -s "$skips" ] || return 0
    while read -r lane; do
        echo "::error title=$lane lane skipped::a host condition kept this lane from running its assertion (see the lane's warning above and the e2e-architecture skill)"
    done <"$skips"
    return 1
}

# --- Reading /state: an answer, or no answer ---------------------------------
#
# A driver that pipes `/state` into jq cannot tell an app that answered `false`
# from one that did not answer at all: a refused connection, a timeout, an app
# blocked behind a TCC consent prompt all come out as empty input, jq turns
# that into empty or `null`, and the caller reads it as the real value. A poll
# then waits out its whole window on "not yet" and blames the feature, and a
# negative check ("the window is gone", "the prompt was cleared") passes on an
# app that said nothing. These helpers keep the two apart by status:
#
#   state_read            one read into STATE_BODY; 0 answered, 2 no answer
#   state_query <f> [a]   jq -r <f> [a] over one read; 0 + output, 2 no answer,
#                         3 the filter failed on an answer
#   poll_state [--each <cmd>] [--judge-deadline-read] <t> <i> <pred...>
#                         poll_until over fresh reads; 0 pred held, 1 timed
#                         out with the app answering, 2 app not answering,
#                         4 the --each check returned non-zero
#   state_is <f> [a]      a poll_state predicate: jq -e <f> [a] on STATE_BODY
#   state_why <rc> <msg>  the failure message for one of those statuses
#
# No answer means no usable answer: no reply within the bound, a transport
# error (an HTTP error status included: a 401 says nothing about the field
# either), or a body that is not a JSON object.

# Per-read bound, enforced by run_bounded whichever transport is used (mt-cli's
# own 5 s request timeout does not cover everything it can block on), and also
# handed to curl as --max-time.
: "${STATE_READ_BOUND_S:=15}"

# One GET /state to stdout, non-zero when the app did not answer. curl with the
# driver's RPC_TOKEN when it holds one, since its token file can sit in a lane's
# own home where mt-cli does not look; mt-cli (which exits non-zero on any
# transport failure) for the drivers that only ever talk through $MTCLI.
_state_transport() {
    if [ -n "${RPC_TOKEN:-}" ]; then
        curl --silent --show-error --fail --max-time "$STATE_READ_BOUND_S" \
            --header "Authorization: Bearer $RPC_TOKEN" \
            "${RPC_BASE:-http://127.0.0.1:9876}/state"
    elif [ -n "${MTCLI:-}" ]; then
        "$MTCLI" state
    else
        echo "neither RPC_TOKEN nor MTCLI is set, so there is no way to ask the app" >&2
        return 1
    fi
}

# state_read — one bounded read of /state. Answered: the body in STATE_BODY,
# status 0. Not answered: STATE_BODY keeps the last answer (what a timed-out
# poll wants to show), the reason goes to STATE_ERR, status 2. Runs in the
# current shell so both survive; call it bare or in a condition, not in $(...).
state_read() {
    local body err status=0
    err="$(mktemp "${TMPDIR:-/tmp}/state-read.XXXXXX")" || { STATE_ERR="mktemp failed"; return 2; }
    body="$(run_bounded "$STATE_READ_BOUND_S" _state_transport 2>"$err")" || status=$?
    if [ "$status" -eq 0 ] && [ -n "$body" ] && jq -e 'type == "object"' <<<"$body" >/dev/null 2>&1; then
        STATE_BODY="$body"
        rm -f "$err"
        return 0
    fi
    case "$status" in
        0) STATE_ERR="the reply was not a JSON object: '$(head -c 200 <<<"$body")'" ;;
        124) STATE_ERR="no reply within ${STATE_READ_BOUND_S}s" ;;
        *) STATE_ERR="the request failed (exit $status): $(tr '\n' ' ' <"$err" | head -c 300)" ;;
    esac
    rm -f "$err"
    return 2
}

# state_query <filter> [jq-args...] — one read, `jq -r <filter>` over it.
# Answered: jq's output, status 0, even when that is `false`, `null` or empty.
# No answer: the reason on stderr, status 2. A filter that fails on the answer:
# status 3. Meant for `v="$(state_query ...)" || fail "$(state_why $? ...)"`;
# `state_query .` is the whole body, for several fields from one snapshot.
state_query() {
    local filter="$1"
    shift
    state_read || { echo "state_query: no answer from the app on /state ($STATE_ERR)" >&2; return 2; }
    jq -r "$@" "$filter" <<<"$STATE_BODY" || return 3
}

# state_is <filter> [jq-args...] — true when `jq -e <filter>` holds on
# STATE_BODY. A filter that errors (a field not there yet) is false, as it
# would be in the pipe it replaces.
state_is() {
    local filter="$1"
    shift
    jq -e "$@" "$filter" <<<"$STATE_BODY" >/dev/null 2>&1
}

# poll_state [--each <cmd>] [--judge-deadline-read] <timeout_s> <interval_s>
#            <predicate> [args...]
# poll_until with a fresh state_read before every tick; the predicate runs
# only on an answer and reads STATE_BODY (state_is, or a function that also
# stashes fields or traces, in the current shell). The app going quiet and
# coming back is logged, once each way, and does not stop the poll.
#
# --each <cmd>: run <cmd> at the start of every tick, before the read and
#   whether or not the app then answers, and once more before the deadline
#   read below. It is for the liveness check (assert_app_alive), which has to
#   run on an unanswered tick above all: a crashed app answers nothing, so a
#   check inside the predicate would never run, and the poll would sit out its
#   window and report no answer instead of a dead process. <cmd> is one word
#   (wrap a check that takes arguments in a function) and is expected to end
#   the run itself on failure, as assert_app_alive does; if it returns
#   non-zero instead, the poll stops at once with status 4.
# --judge-deadline-read: run the predicate on the deadline read too (below).
#   Only for a predicate whose verdict is in the snapshot's own content, such
#   as "a job that is new and terminal": seen on that read after a gap, it
#   proves as much as it would on any answered tick, the last of which can
#   land past the deadline as well. Not for a predicate with a time bound: the
#   deadline read can return up to STATE_READ_BOUND_S after the window. It
#   passes only when the app also answered inside the window. Without it, a
#   condition first seen on the deadline read is not a pass.
#
# 0: the predicate held. 1: the window ran out with the app answering at its
# end, so the condition was false on every answer (gaps inside the window are
# logged, not held against the verdict). 2: the app was not answering: no
# answer in the whole window, or none at its end and none to one more read, so
# a single dropped read at the deadline is not taken for a dead app. 4: the
# --each command returned non-zero. 1 and 2 are what keep "never happened"
# apart from "nobody there to ask"; state_why words them.
poll_state() {
    local each="" judge_late=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --each) each="$2"; shift 2 ;;
            --judge-deadline-read) judge_late=1; shift ;;
            *) break ;;
        esac
    done
    local timeout="$1" interval="$2" answered=0 last=0 quiet_since="" each_rc=0
    shift 2
    if poll_until "$timeout" "$interval" _poll_state_tick "$@"; then
        return "$each_rc"
    fi
    if [ "$last" -eq 1 ]; then
        return 1
    fi
    # The extra read asks whether the app still answers. Without
    # --judge-deadline-read the predicate is not run on it, since a condition
    # first true after the window is not one that held inside it, and
    # STATE_BODY stays the window's last answer, for the caller's diagnostics.
    local window_body="${STATE_BODY:-}"
    if [ -n "$each" ]; then
        "$each" || return 4
    fi
    if ! state_read; then
        echo "poll_state: no answer from the app on /state at the end of the ${timeout}s window${quiet_since:+, none for the last $(( SECONDS - quiet_since ))s} ($STATE_ERR)" >&2
        return 2
    fi
    # Judged only after answers inside the window: a pass needs the window to
    # have been observed at all, or what a caller collected per tick (a value
    # seen or never seen) would stand on nothing.
    if [ "$judge_late" -eq 1 ] && [ "$answered" -eq 1 ]; then
        "$@" && return 0
    elif [ "$judge_late" -eq 0 ]; then
        STATE_BODY="$window_body"
    fi
    if [ "$answered" -eq 0 ]; then
        echo "poll_state: the app answered /state only after the ${timeout}s window, never inside it" >&2
        return 2
    fi
    return 1
}

# One poll_state tick: the --each command, a read, then the predicate if the
# app answered. It updates poll_state's answered / last / quiet_since /
# each_rc, which bash's dynamic scoping makes visible here. A failed --each
# command ends poll_until (by returning 0) with each_rc set.
_poll_state_tick() {
    if [ -n "$each" ] && ! "$each"; then
        each_rc=4
        return 0
    fi
    if ! state_read; then
        last=0
        if [ -z "$quiet_since" ]; then
            quiet_since="$SECONDS"
            echo "poll_state: no answer from the app on /state ($STATE_ERR); still polling" >&2
        fi
        return 1
    fi
    if [ -n "$quiet_since" ]; then
        echo "poll_state: the app answers /state again, after $(( SECONDS - quiet_since ))s without an answer" >&2
        quiet_since=""
    fi
    answered=1 last=1
    "$@"
}

# state_why <status> <message> — the failure message for a state_query or
# poll_state status: <message> as given when the app answered, and a statement
# that the app did not, so the check never ran, when it did not.
state_why() {
    case "$1" in
        2) echo "no answer from the app on /state (reason logged above), so this went unchecked: $2" ;;
        3) echo "the jq filter failed on the app's /state answer (jq's error is above): $2" ;;
        4) echo "the per-tick check handed to poll_state failed (its output is above), so this went unchecked: $2" ;;
        *) echo "$2" ;;
    esac
}

# watch_state — the app's watch state: the loop's state, empty when there is no
# watch loop, and `unreadable` when the app did not answer, so a dead or hung
# app never reads as "not watching".
watch_state() { state_query '.watchState // ""' 2>/dev/null || echo unreadable; }

# rpc_post_status <path> <json> [max-time] — POST a JSON body to the debug RPC
# server and print only the HTTP status, `000` when nothing answered. For the
# calls whose status code is the contract under test. Uses the calling
# driver's RPC_BASE and RPC_TOKEN.
rpc_post_status() {
    local code
    code="$(curl --silent --max-time "${3:-15}" -o /dev/null -w '%{http_code}' -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$2" "$RPC_BASE$1" 2>/dev/null)" || true
    echo "${code:-000}"
}

# rpc_post <path> <json> — POST a JSON body to the dev RPC server and print the
# response body, `{}` when nothing answered, so a caller's jq reads a missing
# answer as a missing field. Same base, token and timeout as rpc_post_status.
rpc_post() {
    curl --silent --show-error --max-time 15 -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$2" "$RPC_BASE$1" 2>/dev/null || echo '{}'
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

# --- mic-stall lane state that outlives one run -------------------------------
#
# The --mic-stall lane of e2e-app.sh switches the dev bundle's protocolProvider
# to `none` and runs the app in a throwaway home. Both have to be undone even
# when a run is killed, so what it needs to undo them is kept on disk and every
# later run of e2e-app.sh, whatever its lane, finishes the job.

# Restore protocolProvider from the record a mic-stall run wrote before it set
# `lane_value`. Nothing to do without a record. Restores only while the current
# value is still `lane_value`: anything else is a choice made since, which the
# old record must not overwrite, so the record is dropped and that is said.
# Verified by reading the value back, because the defaults helpers swallow
# every error: on a mismatch the record is kept for a later run and this
# returns 1.
mic_stall_restore_protocol() {
    local bundle="$1" container_plist="$2" record="$3" lane_value="$4"
    [ -f "$record" ] || return 0
    local before current after
    before="$(cat "$record")"
    current="$(read_dev_default_effective "$bundle" "$container_plist" protocolProvider)"
    if [ "$current" != "$lane_value" ]; then
        printf '[e2e-app] [mic-stall] protocolProvider is %s, not the %s a mic-stall run left; keeping it and dropping the record of %s\n' \
            "'${current:-<unset>}'" "'$lane_value'" "'${before:-<unset>}'"
        rm -f "$record"
        return 0
    fi
    if [ -n "$before" ]; then
        write_dev_default "$bundle" protocolProvider "$before"
    else
        delete_dev_default "$bundle" protocolProvider
    fi
    after="$(read_dev_default_effective "$bundle" "$container_plist" protocolProvider)"
    if [ "$after" != "$before" ]; then
        printf '[e2e-app] WARNING: could not restore protocolProvider to %s (it reads %s); keeping %s for the next run\n' \
            "'${before:-<unset>}'" "'${after:-<unset>}'" "$record" >&2
        return 1
    fi
    rm -f "$record"
    return 0
}

# e2e_is_lane_home <home> <stem> <parent> — whether `home` is one of a lane's
# own `mktemp` homes: directly inside `parent`, named `<stem>.` plus the letters
# and digits mktemp fills in. Anchored on purpose: a substring match would take
# `<parent>/<stem>.a/../../Documents` too, and the callers remove what this
# accepts. The lanes with an isolated home (--mic-stall, --upgrade) each pass
# their own stem, so neither can remove the other's home.
e2e_is_lane_home() {
    local home="$1" stem="$2" parent="${3%/}"
    [[ "$home" =~ ^.*/${stem}\.[A-Za-z0-9]+$ ]] || return 1
    [ "${home%/*}" = "$parent" ]
}

# Whether `home` is one of the mic-stall lane's homes, created in
# MIC_STALL_HOME_PARENT (by default $TMPDIR or /tmp, as the lane does).
mic_stall_is_lane_home() {
    e2e_is_lane_home "$1" e2e-mic-stall-home "${MIC_STALL_HOME_PARENT:-${TMPDIR:-/tmp}}"
}

# Remove a mic-stall run's throwaway home, unless the app that used it (`pid`)
# is still running: a failed run leaves its app up and writing there. A kept
# home is listed with that pid in `kept_list`, so a later run can remove it
# once that app is gone (`mic_stall_sweep_kept_homes`). Only the lane's own
# homes are ever touched (`mic_stall_is_lane_home`).
mic_stall_release_home() {
    local home="$1" pid="$2" kept_list="$3"
    mic_stall_is_lane_home "$home" || return 0
    [ -d "$home" ] || return 0
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        mkdir -p "$(dirname "$kept_list")"
        printf '%s %s\n' "$pid" "$home" >>"$kept_list"
        printf '[e2e-app] [mic-stall] app (pid %s) still running; leaving its home %s for a later run to remove\n' "$pid" "$home"
    else
        rm -rf "$home"
    fi
}

# Remove every home in `kept_list` whose app has exited; keep the entries
# whose app still runs. The list goes once it is empty.
mic_stall_sweep_kept_homes() {
    local kept_list="$1" keep="" pid home
    [ -f "$kept_list" ] || return 0
    while read -r pid home; do
        [ -n "$home" ] || continue
        mic_stall_is_lane_home "$home" || continue
        if kill -0 "$pid" 2>/dev/null; then
            keep="$keep$pid $home"$'\n'
        elif [ -d "$home" ]; then
            rm -rf "$home"
        fi
    done <"$kept_list"
    if [ -n "$keep" ]; then
        printf '%s' "$keep" >"$kept_list"
    else
        rm -f "$kept_list"
    fi
}

# The pids of every running MeetingTranscriber that is not the dev app, the
# installed one above all, space-separated. Matched on the exact process name,
# then excluded by the dev bundle in its command line.
non_dev_meetingtranscriber_pids() {
    { pgrep -x MeetingTranscriber || true; } | while read -r p; do
        ps -o command= -p "$p" 2>/dev/null | grep -q "MeetingTranscriber-Dev.app/" || printf '%s ' "$p"
    done
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

# unified_log_unusable <stream|show> [log-binary] — whether this user cannot
# use the unified log the way the --quit-flush lane needs (its header says why
# that rules out a non-admin user on macOS 26).
#   stream  a one-second `log stream` must run;
#   show    an entry written through `logger` just before must come back, so a
#           `log show` that answers but returns nothing also counts.
# Prints a one-line reason unless usable. Status 0: refused for want of
# permission (the macOS 26 non-admin case); 1: usable; 2: unknown mode; 3: any
# other failure (a failed write, an empty answer, an unrecognised error), which
# is not that host property. For tests: the binary is the second
# argument, and UNIFIED_LOG_PROBE_LOGGER and UNIFIED_LOG_PROBE_SLEEP replace the
# logger command and the wait between reads.
unified_log_unusable() {
    local mode="$1" bin="${2:-/usr/bin/log}" out="" token i
    case "$mode" in
        stream)
            out="$("$bin" stream --predicate 'process == "mt-e2e-log-probe"' --timeout 1 2>&1)" && return 1
            ;;
        show)
            token="mt-e2e-log-probe-$$-$RANDOM"
            if ! "${UNIFIED_LOG_PROBE_LOGGER:-logger}" -t mt-e2e-log-probe "$token"; then
                echo "could not write the probe entry with logger"
                return 3
            fi
            # The entry can take a moment to become visible: up to five reads.
            # The predicate names logger's process, so `log`'s own record of
            # this invocation (which carries the token) is not returned.
            for i in 1 2 3 4 5; do
                [ "$i" -eq 1 ] || sleep "${UNIFIED_LOG_PROBE_SLEEP:-1}"
                out="$("$bin" show --last 1m --style compact \
                    --predicate "process == \"logger\" AND eventMessage CONTAINS \"$token\"" 2>&1)" || break
                grep -q -- "$token" <<<"$out" && return 1
                out="log show answered but did not return an entry written a moment before"
            done
            ;;
        *) echo "unknown mode '$mode'"; return 2 ;;
    esac
    # The refusal line, not the filter banner `log` prints before it; a
    # placeholder when the banner was all there was.
    local line
    if line="$(grep -m1 -E 'Must be admin|Could not open|not permitted' <<<"$out")"; then
        echo "$line"
        return 0
    fi
    line="$(grep -v '^Filtering the log data' <<<"$out" | grep -m1 . || true)"
    echo "${line:-<no output>}"
    return 3
}

# second_quit_outcome <trace> <osascript-output> — which of the two measured
# answers a second AppleScript quit, sent while the first was held open, got.
# <trace> is AppKit's and the Apple Event log of the quit (`log show --style
# compact`, the lines the --quit-flush lane greps), <osascript-output> what the
# script that sent the second quit printed. Prints one of:
#   cancelled                    AppKit refused it itself: the script got -128
#                                and AppKit logged "Canceling termination";
#   asked-after-reply <answer>   AppKit queued it and asked the delegate only
#                                after the held quit's reply, <answer> being
#                                what the delegate returned (NSTerminateNow,
#                                NSTerminateLater, ...).
# Status 1 and nothing printed when the trace is neither: a -128 without
# AppKit's cancel, a cancel without a -128, a second ask before the reply (the
# delegate's held-open guard, never measured), or no second ask at all.
second_quit_outcome() {
    local trace="$1" osa="$2" minus128="" cancel="" after
    grep -q -- '-128' <<<"$osa" && minus128=yes
    grep -q 'Canceling termination' <<<"$trace" && cancel=yes
    if [ -n "$minus128" ] || [ -n "$cancel" ]; then
        [ -n "$minus128" ] && [ -n "$cancel" ] || return 1
        echo cancelled
        return 0
    fi
    # Asked twice, the second time after the first reply: the answer is the
    # first delegate answer logged after that reply.
    [ "$(grep -c 'Asking app delegate whether applicationShouldTerminate' <<<"$trace" || true)" -ge 2 ] || return 1
    after="$(awk '/replyToApplicationShouldTerminate/ { seen = 1; next }
        seen && /applicationShouldTerminate: NS/ { sub(/.*applicationShouldTerminate: /, ""); print $1; exit }' <<<"$trace")"
    [ -n "$after" ] || return 1
    # Both asks must not precede the reply: a second answer before it is the
    # held-open path.
    [ "$(awk '/replyToApplicationShouldTerminate/ { exit } /applicationShouldTerminate: NS/ { n++ } END { print n + 0 }' <<<"$trace")" -eq 1 ] || return 1
    echo "asked-after-reply $after"
}

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

# --- calls that a TCC consent prompt can block --------------------------------
#
# While macOS shows a consent prompt for a protected resource (Files & Folders,
# Automation, ...), the call that raised it does not fail: it BLOCKS until
# someone answers, and on the unattended runner nobody does. The grants key on
# the binary path of the job's responsible process, the runner service's node,
# and a runner update can move that node (externals/node20 -> node24), which
# drops every grant at once. Full story: the e2e-architecture skill, runner
# setup step 6.

# run_bounded <seconds> <cmd> [args...] — run a command with a hard wall-clock
# bound. Its stdout and stderr are replayed to ours once it ends. Status: the
# command's own, or 124 when it was still running at the bound; it is then
# SIGKILLed with its descendants and abandoned, never waited for. <seconds>
# may carry one decimal (0.5).
#
# Nothing simpler survives the case it exists for: macOS ships no `timeout`, a
# `perl -e alarm` wrapper leaves the caller waiting on a process the signal
# does not stop, and a `$(...)` around a background child waits for EOF on a
# pipe the abandoned child keeps open. So the command writes to files and the
# caller polls a status file its subshell writes last.
run_bounded() {
    local limit="$1" dir pid status whole frac limit_cs waited=0 step=5 started="$SECONDS"
    shift
    whole="${limit%%.*}"
    frac="${limit#"$whole"}"
    frac="${frac#.}"
    limit_cs=$(( 10#${whole:-0} * 100 + 10#${frac:0:1}0 ))
    [ "$limit_cs" -gt 0 ] || limit_cs=5
    dir="$(mktemp -d "${TMPDIR:-/tmp}/run-bounded.XXXXXX")" || return 125
    # `set +e`: the subshell inherits errexit, and a failing command must
    # still reach the line that records its status.
    ( set +e; "$@"; echo "$?" >"$dir/status" ) >"$dir/out" 2>"$dir/err" </dev/null &
    pid=$!
    # Probe before sleeping: 0.05 s steps for the first second, so a quick
    # command costs almost nothing, then 0.5 s, so a long bound is not
    # hundreds of forks. Slept time is counted, and the wall clock caps it
    # too (rounded up, plus one: SECONDS counts whole seconds and can tick
    # over at once), so a loaded host cannot stretch the bound by much.
    while [ ! -s "$dir/status" ] && [ "$waited" -lt "$limit_cs" ] \
        && [ $(( SECONDS - started )) -le $(( (limit_cs + 99) / 100 + 1 )) ]; do
        [ "$waited" -lt 100 ] || step=50
        [ "$step" -le $(( limit_cs - waited )) ] || step=$(( limit_cs - waited ))
        sleep "$(printf '%d.%02d' $(( step / 100 )) $(( step % 100 )))"
        waited=$(( waited + step ))
    done
    if [ -s "$dir/status" ]; then
        wait "$pid" 2>/dev/null || true
        status="$(cat "$dir/status")"
    else
        local -a victims=()
        _read_pids victims < <(_descendant_pids "$pid")
        kill -KILL ${victims[@]+"${victims[@]}"} "$pid" 2>/dev/null || true
        # Out of the job table, so the shell neither waits for it nor writes a
        # "Killed: 9" notice into the log when it goes.
        disown "$pid" 2>/dev/null || true
        status=124
    fi
    cat "$dir/out"
    cat "$dir/err" >&2
    rm -rf "$dir"
    return "$status"
}

# _read_pids <array-name> — append the pids on stdin, one per line, to the
# named array. An array rather than a space-joined string, so no caller's IFS
# can turn the kill into a no-op (see _no_pid_alive).
_read_pids() {
    local _pid
    while IFS= read -r _pid; do
        [ -n "$_pid" ] && eval "$1+=(\"\$_pid\")"
    done
    return 0
}

# _descendant_pids <pid> — every descendant of pid, one per line, deepest
# first, found by parent pid only. Nothing here is matched by name.
_descendant_pids() {
    local child children
    children="$(pgrep -P "$1" 2>/dev/null || true)"
    # Read line by line rather than split, so a caller's IFS cannot matter.
    while IFS= read -r child; do
        [ -n "$child" ] || continue
        _descendant_pids "$child"
        echo "$child"
    done <<<"$children"
}

# e2e_tcc_prompt_timeout — E2E_TCC_PROMPT_TIMEOUT (default 10) as a positive
# whole number of seconds, base 10 so a leading zero is not octal. Status 1,
# with the reason on stderr, for anything else. The bound for every TCC probe:
# short in CI so a missing grant is reported in seconds, long (300) for a
# one-time grant session at the runner's screen.
e2e_tcc_prompt_timeout() {
    local raw="${E2E_TCC_PROMPT_TIMEOUT:-10}"
    case "$raw" in
        ''|*[!0-9]*) ;;
        *) if [ $(( 10#$raw )) -gt 0 ]; then echo $(( 10#$raw )); return 0; fi ;;
    esac
    echo "E2E_TCC_PROMPT_TIMEOUT must be a positive whole number of seconds, got '$raw'" >&2
    return 1
}

# tcc_probe_verdict <status> <output> — what a probe of a TCC-guarded resource
# answered: `granted` (status 0); `blocked` (status 124 from run_bounded, or
# AppleScript's own timeout -1712: no answer, which on the runner means a
# consent prompt is waiting on the screen); `denied` (the system's refusal:
# Files & Folders' "Operation not permitted", Automation's -1743,
# Accessibility's -1719 / "assistive access"); or `error` for anything else,
# which is not a grant answer and must not be read as one.
tcc_probe_verdict() {
    local status="$1" output="$2"
    case "$status" in
        0) echo granted; return 0 ;;
        124) echo blocked; return 0 ;;
    esac
    case "$output" in
        *"-1712"*|*"timed out"*) echo blocked ;;
        *"Operation not permitted"*|*"-1743"*|*"not authori"*|*"-1719"*|*"assistive access"*|*"not allowed"*)
            echo denied ;;
        *) echo error ;;
    esac
}

# _tcc_grantee_from_ps <pid> — read a `ps -axo pid=,ppid=,comm=` table on stdin
# and print "<pid> <comm>" of the process TCC most likely attributes <pid>'s
# accesses to: the topmost GitHub runner node (`.../externals/node*/bin/node`)
# among its ancestors, else the topmost ancestor below launchd (Terminal, sshd,
# ...). `comm` may be relative (runsvc.sh starts node as ./externals/...), so
# the caller resolves the path. Status 1 when <pid> is not in the table.
_tcc_grantee_from_ps() {
    awk -v start="$1" '
        { pid = $1; ppid = $2; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, ""); parent[pid] = ppid; comm[pid] = $0 }
        END {
            if (!(start in parent)) exit 1
            p = start; top = ""; node = ""
            for (n = 0; (p in parent) && p > 1 && n < 200; n++) {
                top = p
                if (comm[p] ~ /(^|\/)externals\/node[^\/]*\/bin\/node$/) node = p
                p = parent[p]
            }
            pick = (node != "" ? node : top)
            print pick, comm[pick]
        }'
}

# tcc_grantee [pid] — the absolute path of the binary to allow in System
# Settings for this job (see _tcc_grantee_from_ps), resolved from the running
# process, never assumed: a runner update moves it. Falls back to a
# description when nothing can be resolved.
tcc_grantee() {
    local line pid comm path
    if line="$(ps -axo pid=,ppid=,comm= | _tcc_grantee_from_ps "${1:-$$}")" && [ -n "$line" ]; then
        pid="${line%% *}"
        comm="${line#* }"
        # lsof's first `txt` entry is the executable itself, absolute even when
        # the process was started through a relative path.
        path="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
        echo "${path:-$comm}"
        return 0
    fi
    echo "the binary that started this job (for the CI runner: <runner dir>/externals/node<N>/bin/node, whichever node runsvc.sh starts)"
}

# tcc_fix_hint <pane> [grantee] — the one-sentence fix every TCC message ends
# with: where to allow which binary, and where the background is.
tcc_fix_hint() {
    printf 'System Settings → Privacy & Security → %s: allow %s (answer the prompt on the runner'"'"'s screen if one is open), then re-run; see the e2e-architecture skill, runner setup step 6.' \
        "$1" "${2:-$(tcc_grantee)}"
}

# --- drivers a step timeout left behind ---------------------------------------
#
# A step that times out does not reliably take its driver down: one blocked in
# a TCC-guarded read outlived its step, and the rerun's e2e-app.sh refused to
# start next to it. So every e2e driver records itself in CI, by pid AND start
# time, and the next driver of the job and the workflow's `if: always()` step
# end exactly those: a pid alone may have been reused, and a pattern would
# match whatever else names the script.

# _ancestor_pids [pid] — pid (default: this shell) and each ancestor up to,
# not including, launchd, space-delimited with a leading and trailing space so
# a caller can test membership with `case " $list " in *" $p "*`.
_ancestor_pids() {
    local p="${1:-$$}" out=" "
    while [ -n "$p" ] && [ "$p" -gt 1 ]; do
        out="$out$p "
        p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    done
    echo "$out"
}

# e2e_register_driver — record this script's pid in the job's driver list,
# after ending what an earlier step left in it (a step that runs after a
# timeout, `if: always()` or `!cancelled()` or after a continue-on-error lane,
# would otherwise start next to the leftover driver). Every e2e-*.sh driver
# that sources this file calls it right after; it is explicit rather than a
# side effect of `source`, since it can signal processes and wait. CI only
# ($RUNNER_TEMP is per job); a no-op elsewhere.
e2e_register_driver() {
    [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${RUNNER_TEMP:-}" ] || return 0
    e2e_reap_registered_drivers || true
    local started
    started="$(ps -o lstart= -p $$ 2>/dev/null)" || return 0
    printf '%s\t%s\t%s\n' "$$" "$started" "$(basename "$0")" 2>/dev/null >>"$RUNNER_TEMP/e2e-driver-pids" || true
}

# e2e_reap_registered_drivers [list] — end every driver in the list that is
# still running as the process recorded (same pid, same start time).
#
# Every driver gets SIGTERM at the same moment, together rather than one by
# one: a nested driver that exits early would otherwise start its parent's
# cleanup, and a TERM sent to the parent a moment later would cut it off. A
# driver whose trap can run then runs it with its children still there (the
# drivers that trap only EXIT clean up at once, and some of them quit or sweep
# an app that is their own child). After E2E_REAP_UNBLOCK_S (10) seconds, the
# drivers still running have the non-driver descendants they had before the
# TERM SIGKILLed: bash holds a TERM trap until its foreground child returns,
# and that child is the call blocked behind the prompt. What a trap started
# after the TERM is left alone. A descendant that is itself a registered
# driver (an e2e-app.sh --redeploy-only under e2e-browser.sh, e2e-soak.sh or
# e2e-channel-fault.sh) is spared, and gets its own TERM. The drivers share
# E2E_REAP_GRACE_S (90) seconds in all for their traps. The arithmetic: a
# trap held until the unblock starts by about 11 s (10 s plus the poll's
# whole-second overshoot); quit_running_app's worst case is about 52 s (see
# there); restoring routing, settings and shared state, and sweeping
# recordings, is allowed 10 s; that is 73 s, and 90 leaves 17 s of margin.
# Then SIGKILL for what is left, with whatever the traps started, which with
# its 3 s wait keeps the whole reap under 100 s; the workflows' reaper steps
# allow 3 minutes. This shell and its ancestors are never touched. Entries that are
# gone are dropped; a driver that survives SIGKILL stays listed, so the job's
# last step still sees it, and makes the status 1.
e2e_reap_registered_drivers() {
    local list="${1:-${RUNNER_TEMP:-}/e2e-driver-pids}" pid started name p ancestors
    local keep="" survivors="" entries="" members=" "
    local -a drivers=() children=() all=()
    [ -s "$list" ] || return 0
    ancestors="$(_ancestor_pids)"
    while IFS=$'\t' read -r pid started name; do
        [ -n "$pid" ] || continue
        case "$ancestors" in
            *" $pid "*) keep="$keep$pid"$'\t'"$started"$'\t'"$name"$'\n'; continue ;;
        esac
        [ "$(ps -o lstart= -p "$pid" 2>/dev/null)" = "$started" ] || continue
        echo "::warning title=leftover e2e driver::$name (pid $pid) was still running from an earlier step; ending it and its children. A step timeout leaves one behind; look in that step's log for a call blocked behind a TCC prompt."
        drivers+=("$pid")
        members="$members$pid "
        entries="$entries$pid"$'\t'"$started"$'\t'"$name"$'\n'
    done <"$list"
    if [ "${#drivers[@]}" -gt 0 ]; then
        local unblock="${E2E_REAP_UNBLOCK_S:-10}" grace="${E2E_REAP_GRACE_S:-90}" before="" owner
        # The descendants as they are before the TERM, with start times and
        # the driver they hang under. Only these are ever SIGKILLed below, and
        # only while their start time still matches, so neither what a trap
        # starts after the TERM nor a pid reused meanwhile is touched.
        for pid in "${drivers[@]}"; do
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                case "$members" in *" $p "*) continue ;; esac
                before="$before$p"$'\t'"$(ps -o lstart= -p "$p" 2>/dev/null)"$'\t'"$pid"$'\n'
            done < <(_descendant_pids "$pid")
        done
        kill -TERM "${drivers[@]}" 2>/dev/null || true
        # Phase 1: a driver whose trap can run does so now, with its children
        # (the app it started, its simulator) still there for the cleanup to
        # quit or sweep after.
        poll_until "$unblock" 0.2 _no_pid_alive "${drivers[@]}" || true
        # Phase 2: a driver still here is most likely held by a foreground
        # child blocked behind a prompt, which keeps bash from running its
        # pending TERM trap. SIGKILL the descendants it had before the TERM,
        # so the trap runs, and give it the rest of the grace.
        while IFS=$'\t' read -r p started owner; do
            [ -n "$p" ] && [ -n "$started" ] || continue
            _pid_is_alive "$owner" || continue
            if [ "$(ps -o lstart= -p "$p" 2>/dev/null)" = "$started" ]; then children+=("$p"); fi
        done <<<"$before"
        [ "${#children[@]}" -eq 0 ] || kill -KILL "${children[@]}" 2>/dev/null || true
        poll_until $(( grace > unblock ? grace - unblock : 1 )) 0.2 _no_pid_alive "${drivers[@]}" || true
        # Then SIGKILL what is left: the drivers, what their traps started,
        # and what they had before (orphaned if their driver died on TERM).
        all=("${drivers[@]}")
        for pid in "${drivers[@]}"; do
            if _pid_is_alive "$pid"; then _read_pids all < <(_descendant_pids "$pid"); fi
        done
        while IFS=$'\t' read -r p started owner; do
            [ -n "$p" ] && [ -n "$started" ] || continue
            if [ "$(ps -o lstart= -p "$p" 2>/dev/null)" = "$started" ]; then all+=("$p"); fi
        done <<<"$before"
        kill -KILL "${all[@]}" 2>/dev/null || true
        poll_until 3 0.2 _no_pid_alive "${all[@]}" || true
        for p in "${all[@]}"; do
            if _pid_is_alive "$p"; then survivors="$survivors $p"; fi
        done
        while IFS=$'\t' read -r pid started name; do
            [ -n "$pid" ] || continue
            case " $survivors " in *" $pid "*) keep="$keep$pid"$'\t'"$started"$'\t'"$name"$'\n' ;; esac
        done <<<"$entries"
    fi
    printf '%s' "$keep" >"$list"
    [ -s "$list" ] || rm -f "$list"
    if [ -n "$survivors" ]; then
        echo "::error title=e2e driver could not be ended::pid(s)${survivors} survived SIGKILL, most likely stuck in a call a TCC prompt holds; answer the prompt on the runner's screen (see the e2e-architecture skill, runner setup step 6)"
        return 1
    fi
    return 0
}

# --- preference overrides a lane must undo, even after a killed run ----------
#
# A lane that changes a host's own settings (not a test toggle but a user's
# choice, such as the protocol provider) has to put them back on every exit, and
# a run killed before its trap fires must not leave them changed for good. So
# the old values go to a record file on disk BEFORE the first write, and every
# later run of the driver restores a record it finds before changing anything.
#
# Values are kept as their property-list XML (`<real>0.7</real>`, `<true/>`,
# `<string>…</string>`), read through `defaults export` and written back with
# `defaults write <plist> <key> '<fragment>'`, both through cfprefsd. Not
# `defaults read` and `-float`: `-float` stores a 32-bit float (0.7 comes back
# as 0.69999998807907104), and `defaults read` prints both as "0.7", so a
# read-back would hide the loss. Measured on macOS 26.
#
# Record lines are plist, key, value fragment (or `absent`) and, once marked,
# the lane's own value, separated by the ASCII unit separator (0x1f), not a tab:
# a tab is IFS whitespace, so `read` would collapse an empty field.

# _defaults_export <plist> — the whole plist as XML, through cfprefsd. Returns
# 1 when nothing readable came back, which callers must not mistake for "every
# key absent". A plist that does not exist exports as an empty dictionary.
_defaults_export() {
    local xml
    xml="$(/usr/bin/defaults export "$1" - 2>/dev/null)" || return 1
    case "$xml" in *"<plist"*) printf '%s' "$xml" ;; *) return 1 ;; esac
}

# _defaults_fragment <export-xml> <key> — the key's value in what
# `_defaults_export` printed, as one line of plist XML; `absent` when the key is
# not there. Returns 1 for empty input, for a value that spans lines (a string
# with a newline, a dictionary or an array), which a record line cannot carry,
# and when plutil fails for any other reason than a missing key.
_defaults_fragment() {
    local out
    [ -n "$1" ] || return 1
    if ! out="$(plutil -extract "$2" xml1 -o - - <<<"$1" 2>&1)"; then
        case "$out" in
            *"No value at that key path"*) printf 'absent'; return 0 ;;
            *) return 1 ;;
        esac
    fi
    out="$(sed -n '/^<plist/,/^<\/plist>/p' <<<"$out" | sed '1d;$d')"
    case "$out" in
        ''|*$'\n'*|*$'\x1f'*) return 1 ;;
    esac
    printf '%s' "$out"
}

# defaults_record_keys <record> <plist> <key>... — append one line per key to
# `record`: plist, key, the value's plist XML (or `absent`). `plist` is an
# absolute path, as write_dev_default writes. Returns 1, recording nothing for
# this plist, when the plist cannot be read or a key holds something a line
# cannot carry: the caller must not change a value it could not put back.
defaults_record_keys() {
    local record="$1" plist="$2" key xml fragment lines=""
    shift 2
    xml="$(_defaults_export "$plist")" || {
        echo "defaults_record_keys: could not read $plist" >&2; return 1; }
    for key in "$@"; do
        fragment="$(_defaults_fragment "$xml" "$key")" || {
            echo "defaults_record_keys: $key in $plist is not a single-line value; not recordable" >&2; return 1; }
        lines="$lines$plist"$'\x1f'"$key"$'\x1f'"$fragment"$'\n'
    done
    printf '%s' "$lines" >>"$record"
}

# defaults_mark_lane_values <record> — append to each line the value its key
# holds now, once the lane has written its own. The restore then puts back only
# keys that still hold the lane's value: anything else is a choice made since (a
# killed run, then a person changing the setting before the next run repairs
# it), which an old record must not overwrite. A record never marked (a run
# killed between the record and its writes) restores every key. Marking again
# replaces the old marks. Returns 1, leaving the record unmarked, when a plist
# cannot be read: a mark taken from a failed read would later make every key
# look changed and nothing would be restored.
defaults_mark_lane_values() {
    local record="$1" plist key value _old xml="" xml_of="" now out=""
    [ -f "$record" ] || return 0
    # shellcheck disable=SC2034  # an old mark is read only to be dropped
    while IFS=$'\x1f' read -r plist key value _old; do
        [ -n "$key" ] || continue
        if [ "$plist" != "$xml_of" ]; then
            xml="$(_defaults_export "$plist")" || return 1
            xml_of="$plist"
        fi
        now="$(_defaults_fragment "$xml" "$key")" || return 1
        out="$out$plist"$'\x1f'"$key"$'\x1f'"$value"$'\x1f'"$now"$'\n'
    done <"$record"
    printf '%s' "$out" >"$record.tmp" && mv "$record.tmp" "$record"
}

# defaults_restore_record <record> — put back every value `record` holds, then
# read each one back. A key no longer holding the lane's marked value is left
# as it is, and said; so is one whose current value a line could not carry,
# which the lane never writes. A line not in this format is dropped, and said.
# Lines that are settled are dropped; a line whose value did not come back, or
# whose plist could not be read at all, stays in the record, and then this
# returns 1, so a later run retries exactly those and never re-applies a settled
# one over a choice made in between. The defaults writes swallow their own
# errors, so the read-back is the only evidence a restore landed. Each plist is
# exported once before the writes and once after them.
defaults_restore_record() {
    local record="$1" plist key value lane line xml="" xml_of="" now keep="" written=""
    [ -f "$record" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS=$'\x1f' read -r plist key value lane <<<"$line"
        case "$value" in
            absent|"<"*) ;;
            *) echo "defaults_restore_record: dropping a line it cannot read: $key in $plist" >&2; continue ;;
        esac
        case "$lane" in
            *$'\x1f'*) echo "defaults_restore_record: dropping a line it cannot read: $key in $plist" >&2; continue ;;
        esac
        if [ "$plist" != "$xml_of" ]; then
            xml="$(_defaults_export "$plist")" || xml=""
            xml_of="$plist"
        fi
        [ -n "$xml" ] || { keep="$keep$line"$'\n'; continue; }
        now="$(_defaults_fragment "$xml" "$key")" || now="<not representable>"
        if [ -n "$lane" ] && [ "$now" != "$lane" ]; then
            echo "defaults_restore_record: $key in $plist changed since the lane set it; keeping it" >&2
            continue
        fi
        if [ "$value" = absent ]; then
            /usr/bin/defaults delete "$plist" "$key" >/dev/null 2>&1 || true
        else
            /usr/bin/defaults write "$plist" "$key" "$value" 2>/dev/null || true
        fi
        written="$written$line"$'\n'
    done <"$record"
    xml_of=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS=$'\x1f' read -r plist key value lane <<<"$line"
        if [ "$plist" != "$xml_of" ]; then
            xml="$(_defaults_export "$plist")" || xml=""
            xml_of="$plist"
        fi
        now="$(_defaults_fragment "$xml" "$key")" || now=""
        [ "$now" = "$value" ] || keep="$keep$line"$'\n'
    done <<<"$written"
    if [ -n "$keep" ]; then
        printf '%s' "$keep" >"$record.tmp" && mv "$record.tmp" "$record"
        echo "defaults_restore_record: did not restore: $(cut -d $'\x1f' -f2 "$record" | tr '\n' ' '); keeping them in $record for the next run" >&2
        return 1
    fi
    rm -f "$record"
}

# openai_stub_request_violations <request> <expect> — what is wrong with one
# request the --protocol lane's stub logged (scripts/fixtures/openai-chat-stub.py),
# one line per problem, nothing when it is the request the lane expects. Both
# arguments are JSON. `expect` carries: path, model, language, transcript,
# temperature and topP (null: the key must be absent from the body), and
# languageInPrompt (false when a custom prompt is installed, which need not name
# the language at all). The API key is not checked here: the lane runs with
# whatever key the host has, and where it goes is covered by
# OpenAIProtocolGeneratorTests.
openai_stub_request_violations() {
    jq -nr --argjson r "$1" --argjson e "$2" '
        def sampling($name; $want):
            if $want == null then
                (if ($r.body | has($name)) then "\($name) was sent (\($r.body[$name])) but no override is set" else empty end)
            elif $r.body[$name] != $want then "\($name) is \($r.body[$name] // "absent"), expected \($want)"
            else empty end;
        if ($r.body | type) != "object" then "the body is not a JSON object (\($r.bodyBytes) bytes)"
        else
            (if $r.method != "POST" then "method is \($r.method), expected POST" else empty end),
            (if $r.path != $e.path then "path is \($r.path), expected \($e.path)" else empty end),
            (if ($r.contentType | startswith("application/json") | not) then "Content-Type is \($r.contentType | tojson), expected application/json" else empty end),
            (if $r.body.model != $e.model then "model is \($r.body.model | tojson), expected \($e.model | tojson)" else empty end),
            (if $r.body.stream != true then "stream is \($r.body.stream | tojson), expected true" else empty end),
            (if ($r.body.max_tokens | type) != "number" then "max_tokens is \($r.body.max_tokens | tojson), expected a number on the first attempt" else empty end),
            sampling("temperature"; $e.temperature),
            sampling("top_p"; $e.topP),
            (if ($r.body.messages | type) != "array" or ($r.body.messages | length) != 2 then "messages is not a [system, user] pair"
             else
                $r.body.messages[0] as $sys | $r.body.messages[1] as $user |
                (if $sys.role != "system" then "messages[0].role is \($sys.role | tojson), expected system" else empty end),
                (if $user.role != "user" then "messages[1].role is \($user.role | tojson), expected user" else empty end),
                (if ($sys.content | tostring | contains("{LANGUAGE}")) then "the system prompt still holds the {LANGUAGE} placeholder" else empty end),
                (if $e.languageInPrompt and ($sys.content | tostring | contains($e.language) | not) then "the system prompt does not name the protocol language \($e.language | tojson)" else empty end),
                (if $user.content != $e.transcript then "the user message is not the transcript (\($user.content | tostring | length) chars sent, \($e.transcript | length) in the transcript file)" else empty end)
             end)
        end'
}
