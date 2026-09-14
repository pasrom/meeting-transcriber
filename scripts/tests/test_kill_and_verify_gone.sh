#!/bin/bash
# Regression test for `kill_and_verify_gone`, the verdict the crash-recovery
# lane's kill was missing.
#
# The lane SIGKILLs the app mid-recording and then asserts on files. It threw
# the kill's status away, and everything below that line is equally true of an
# app that is still running, so the lane could pass while testing an ordinary
# recording.
#
# An earlier draft of this same change watched the kill's PATTERN instead of its
# target: `! pgrep -f "$pattern"`, which answers "gone" on the first tick when
# the pattern matches nothing. That is the likeliest failure of all, a pattern
# being a path fragment and paths getting renamed. So the helper captures the
# victims first, refuses when there are none, kills those, and waits for THOSE
# PROCESS IDS.
#
# Three reviews on different models found four ways the first version of that
# helper still reported success while verifying nothing. Each has a case here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

PASSED=0
TMPD="$(mktemp -d)"
PIDS=""
# Set at the very end. MEASURED on bash 3.2, which is the system bash here: a
# `set -u` abort in a script that has an EXIT trap reports `$? = 0` inside the
# trap AND exits 0, so the abort is indistinguishable from success to anything
# reading the exit status, which is exactly how ci.yml runs this file. (An
# errexit abort behaves correctly, 1 both places; only `set -u` is affected.)
# Without this sentinel the whole file could silently pass while running none of
# its cases, which is the failure it exists to prevent, one level up.
COMPLETED=0

# Every probe ever started, so a failing case cannot leave a `sleep 300` behind.
# That matters more than tidiness: the probes are orphans sharing this shell's
# stdout, so a leaked one holds the log pipe open and a one-line FAIL turns into
# a step that hangs until the job timeout, losing the diagnosis exactly when it
# is wanted. Their output is discarded for the same reason.
reap_all() {
    local rc=$? pid
    for pid in $PIDS; do kill -KILL "$pid" 2>/dev/null || true; done
    rm -rf "$TMPD"
    if [ "$COMPLETED" -ne 1 ]; then
        echo "FAIL: the test aborted before reaching its end" >&2
        exit 1
    fi
    exit "$rc"
}
trap reap_all EXIT

# A process whose argv carries a unique marker, so `pgrep -f` cannot match this
# test's own shell or anything else on a shared runner. `exec -a` renames the
# sleep in place, so nothing is written to disk and the probe costs no CPU.
#
# Started through an intermediate subshell that exits at once, so the probe is
# an orphan rather than a job of THIS shell: a job earns a "Killed: 9" notice
# written into the log by this shell when it is reaped, and that notice cannot
# be redirected from the job or from the wait, only away from the shell. The pid
# travels through a file because `$!` of the outer subshell is the wrong one.
start_probe() {
    local marker="$1" pidfile="$TMPD/pid.$RANDOM"
    ( ( exec -a "$marker" sleep 300 >/dev/null 2>&1 ) & echo "$!" > "$pidfile" )
    PROBE_PID="$(cat "$pidfile")"
    PIDS="$PIDS $PROBE_PID"
    local tries=0
    until pgrep -f -- "$marker" >/dev/null 2>&1; do
        tries=$(( tries + 1 ))
        [ "$tries" -lt 100 ] || { echo "probe $marker never became visible" >&2; exit 1; }
        sleep 0.05
    done
}

ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }

# --- the case the pattern watcher got backwards -----------------------------

ERR="$TMPD/err"
if kill_and_verify_gone "e2e-probe-never-started-$$" 1 2>"$ERR"; then
    bad nothing_matched_is_refused "a pattern matching nothing was reported as a successful kill"
fi
case "$(cat "$ERR")" in
    *"matched no process"*) ok nothing_matched_is_refused ;;
    *) bad nothing_matched_is_refused "refused, but not for the stated reason: $(cat "$ERR")" ;;
esac

# --- the ordinary path ------------------------------------------------------

start_probe "e2e-probe-killed-$$"
VICTIM="$PROBE_PID"
if kill_and_verify_gone "e2e-probe-killed-$$" 5; then
    kill -0 "$VICTIM" 2>/dev/null \
        && bad live_process_is_killed "reported gone while the process is still alive"
    ok live_process_is_killed
else
    bad live_process_is_killed "a live, matchable process was not killed or not verified"
fi

# --- two victims at once ----------------------------------------------------

# The lane's pattern is a path shared by every lane on this host, so more than
# one match is the normal case, not an exotic one. It is also where the quoting
# has to hold: the pids are carried as separate arguments precisely so a caller
# with an unusual IFS cannot collapse them into one.
MARKER_TWO="e2e-probe-pair-$$"
start_probe "$MARKER_TWO"; FIRST="$PROBE_PID"
start_probe "$MARKER_TWO"; SECOND="$PROBE_PID"
if kill_and_verify_gone "$MARKER_TWO" 5; then
    for p in "$FIRST" "$SECOND"; do
        kill -0 "$p" 2>/dev/null && bad two_victims_are_both_killed "pid $p survived"
    done
    ok two_victims_are_both_killed
else
    bad two_victims_are_both_killed "two matching processes were not both killed or not verified"
fi

# --- a caller whose IFS does not contain a space ----------------------------

# Measured on the first version of this helper: with IFS set to newline it
# reported gone while two probes were still running. The kill got one bogus
# argument and the check made the same mistake, and the two errors cancelled
# into a false success. A library function may not depend on its caller's IFS.
MARKER_IFS="e2e-probe-ifs-$$"
start_probe "$MARKER_IFS"; IFS_FIRST="$PROBE_PID"
start_probe "$MARKER_IFS"; IFS_SECOND="$PROBE_PID"
(
    IFS=$'\n'
    kill_and_verify_gone "$MARKER_IFS" 5
) || bad unusual_ifs_still_works "reported failure under IFS=newline"
for p in "$IFS_FIRST" "$IFS_SECOND"; do
    kill -0 "$p" 2>/dev/null && bad unusual_ifs_still_works "pid $p survived under IFS=newline"
done
ok unusual_ifs_still_works

# --- a victim that survives the kill ----------------------------------------

# SIGKILL cannot be caught, so a real victim cannot be made to survive. What can
# be reproduced is the case that matters, a kill that does not take effect. The
# killing is swallowed and the liveness probe left alone, so the helper runs its
# real logic against a victim that genuinely stays alive.
#
# A first version of this case pointed the helper at a root-owned process. It
# passed, and for the wrong reason: the pattern matched nothing, so it took the
# "matched no process" branch, and both failures return 1. Widening the pattern
# until it matched would have killed this machine's own processes. Hence the
# override, and hence the message assertion.
MARKER_SURVIVE="e2e-probe-survivor-$$"
start_probe "$MARKER_SURVIVE"
SURVIVOR="$PROBE_PID"

kill() {
    case "${1:-}" in
        -KILL) return 0 ;;   # swallowed: the victim is meant to survive
    esac
    builtin kill "$@"        # -0 liveness probes go through untouched
}
ERR2="$TMPD/err2"
if kill_and_verify_gone "$MARKER_SURVIVE" 1 2>"$ERR2"; then
    unset -f kill
    bad surviving_victim_is_not_gone "a victim that is still alive was reported gone"
fi
unset -f kill
kill -0 "$SURVIVOR" 2>/dev/null \
    || bad surviving_victim_is_not_gone "the victim died anyway, so this case proved nothing"
case "$(cat "$ERR2")" in
    *"still alive after"*) ok surviving_victim_is_not_gone ;;
    *) bad surviving_victim_is_not_gone "refused, but as the wrong failure: $(cat "$ERR2")" ;;
esac

# --- a victim we are not allowed to signal ----------------------------------

# `kill -0` answers "may I signal it", not "does it exist", and fails the same
# way for a dead pid and for a live one owned by somebody else. Reported by two
# independent reviews and reproduced against root's daemons: the helper said
# gone while the process was plainly running. `ps -p` is the fallback.
#
# Simulated rather than run against a real root process, because a pattern broad
# enough to match one also matches this machine's own.
MARKER_EPERM="e2e-probe-eperm-$$"
start_probe "$MARKER_EPERM"
EPERM_PID="$PROBE_PID"

kill() {
    case "${1:-}" in
        -0|-KILL) return 1 ;;   # every signal denied, as EPERM would
    esac
    builtin kill "$@"
}
ERR3="$TMPD/err3"
if kill_and_verify_gone "$MARKER_EPERM" 1 2>"$ERR3"; then
    unset -f kill
    bad unsignalable_victim_is_not_gone "a live process we may not signal was reported gone"
fi
unset -f kill
kill -0 "$EPERM_PID" 2>/dev/null \
    || bad unsignalable_victim_is_not_gone "the victim died anyway, so this case proved nothing"
case "$(cat "$ERR3")" in
    *"still alive after"*) ok unsignalable_victim_is_not_gone ;;
    *) bad unsignalable_victim_is_not_gone "refused, but as the wrong failure: $(cat "$ERR3")" ;;
esac

# --- it watches its TARGET, not its pattern ---------------------------------

# Everything above is satisfied by a helper that merely waits for the pattern to
# stop matching, because the empty-victim refusal already covers the hollow
# case. What separates the two is a replacement: the victim dies, and something
# else matching the same pattern is running by the time the wait looks. On this
# host that is not hypothetical, the pattern being a deploy path every lane and
# the console user share.
MARKER_REPL="e2e-probe-replaced-$$"
start_probe "$MARKER_REPL"
ORIGINAL="$PROBE_PID"
REPLACEMENT=""

kill() {
    case "${1:-}" in
        -KILL)
            shift
            builtin kill -KILL "$@" 2>/dev/null || true
            ( ( exec -a "$MARKER_REPL" sleep 300 >/dev/null 2>&1 ) & echo "$!" > "$TMPD/repl" )
            REPLACEMENT="$(cat "$TMPD/repl")"
            PIDS="$PIDS $REPLACEMENT"
            return 0 ;;
    esac
    builtin kill "$@"
}
ERR4="$TMPD/err4"
if kill_and_verify_gone "$MARKER_REPL" 3 2>"$ERR4"; then
    unset -f kill
    kill -0 "$ORIGINAL" 2>/dev/null \
        && bad watches_its_target_not_its_pattern "reported gone while the victim lives"
    # Without this the case is green against a helper that never ran the
    # override at all, for instance one rewritten to use `pkill -f`: the victim
    # dies, nothing stands in, and "gone" is right for the wrong reason.
    [ -n "$REPLACEMENT" ] \
        || bad watches_its_target_not_its_pattern "the stand-in was never started, so the pattern was never kept alive"
    kill -0 "$REPLACEMENT" 2>/dev/null \
        || bad watches_its_target_not_its_pattern "the stand-in died, so the pattern was not kept alive"
    ok watches_its_target_not_its_pattern
else
    unset -f kill
    bad watches_its_target_not_its_pattern \
        "the victim is gone, but another process matching the pattern made it report failure: $(cat "$ERR4")"
fi

# --- pgrep is asked properly, and its refusals are told apart ---------------

# A pattern may begin with a dash. Without `--` pgrep reads it as an option and
# exits 2 for a usage error, which the helper would otherwise report as "matched
# no process": a confident wrong diagnosis about the one thing it is for.
ERR5="$TMPD/err5"
if kill_and_verify_gone "-zzz-no-such-pattern-$$" 1 2>"$ERR5"; then
    bad option_like_pattern_is_passed_through "an option-like pattern was reported as a successful kill"
fi
case "$(cat "$ERR5")" in
    *"matched no process"*) ok option_like_pattern_is_passed_through ;;
    *) bad option_like_pattern_is_passed_through "pgrep never saw the pattern as a pattern: $(cat "$ERR5")" ;;
esac

# And when pgrep cannot answer at all, "nothing matched" is a guess, not a
# finding. The two have opposite remedies, so they must not share a message.
STUB="$TMPD/stub"
mkdir -p "$STUB"
printf '#!/usr/bin/env bash
exit 3
' > "$STUB/pgrep"
chmod +x "$STUB/pgrep"
ERR6="$TMPD/err6"
if PATH="$STUB:$PATH" kill_and_verify_gone "anything-$$" 1 2>"$ERR6"; then
    bad pgrep_failure_is_not_no_match "a broken pgrep was reported as a successful kill"
fi
case "$(cat "$ERR6")" in
    *"pgrep failed with status 3"*) ok pgrep_failure_is_not_no_match ;;
    *) bad pgrep_failure_is_not_no_match "a pgrep that could not answer was reported as a finding: $(cat "$ERR6")" ;;
esac

# --- the lane consumes the verdict ------------------------------------------

# Structural, and said so: driving e2e-app.sh's crash-recovery path needs a
# running app. What it pins is the one thing that makes the helper worth having,
# that its answer is acted on.
#
# Anchored on the call rather than filtered afterwards. A first version filtered
# comments with `grep -n … | grep -v '^\s*#'`, which never matches: after `-n`
# every line starts with its number. A comment naming the helper then satisfied
# the check while the real call had been weakened to `|| true`, measured.
LANE="$ROOT/scripts/e2e-app.sh"
CALL="$(grep -nE '^[[:space:]]*kill_and_verify_gone[[:space:]]' "$LANE" || true)"
if [ -z "$CALL" ]; then
    bad lane_consumes_the_verdict "e2e-app.sh has no call to the helper"
fi
CALL_LINE="${CALL%%:*}"
FOLLOWING="$(sed -n "${CALL_LINE},$(( CALL_LINE + 2 ))p" "$LANE")"
case "$FOLLOWING" in
    *"|| fail"*) ok lane_consumes_the_verdict ;;
    *) bad lane_consumes_the_verdict "the lane does not stop on the verdict:
$FOLLOWING" ;;
esac

COMPLETED=1
echo "$PASSED checks passed"
