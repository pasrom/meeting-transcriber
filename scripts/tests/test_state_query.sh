#!/bin/bash
# Regression test for the RPC readers in e2e-helpers.sh: state_read,
# state_query, state_is, poll_state and state_why for /state, and rpc_read,
# rpc_is, poll_rpc and rpc_why for any other path (/v1/..., /metrics).
#
# What they exist for is one distinction, so every case pins one side of it:
# an app that answered `false` (or `null`, or nothing for the field) against an
# app that did not answer at all. Before them the drivers piped /state into jq,
# and an app that printed nothing read as the real value: a silent-recording
# poll waited out its window on "not silent yet" while the app was not
# answering, and a negative check ("the naming window is gone") would pass on
# an app that said nothing.
#
# The app is a fake mt-cli on $MTCLI that plays a script of replies, one line
# per call (the last line repeats): `answer <json>`, `empty` (exit 0, prints
# nothing), `fail` (exit 1, as mt-cli does on a refused connection), `garbage`
# (exit 0, not JSON) or `hang`. The cases from "the curl path" on drive a
# fake curl that plays the same script, with HTTP status codes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

TMP="$(mktemp -d)"
# Set at the very end: on the system bash 3.2 a `set -u` abort under an EXIT
# trap exits 0, so without this a half-run file would read as a pass.
COMPLETED=0
finish() {
    local rc=$?
    rm -rf "$TMP"
    if [ "$COMPLETED" -ne 1 ]; then
        echo "FAIL: the test aborted before reaching its end" >&2
        exit 1
    fi
    exit "$rc"
}
trap finish EXIT
PASSED=0
ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }

MTCLI="$TMP/mt-cli"
cat >"$MTCLI" <<'EOF'
#!/bin/bash
# Fake mt-cli: `state` replays $FAKE_DIR/script, one line per call.
[ "${1:-}" = state ] || exit 64
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FAKE_DIR/calls"
line="$(sed -n "${n}p" "$FAKE_DIR/script")"
[ -n "$line" ] || line="$(tail -n 1 "$FAKE_DIR/script")"
case "$line" in
    answer\ *) echo "${line#answer }" ;;
    empty) ;;
    fail) echo "Error: Meeting Transcriber app is not running on http://127.0.0.1:9876" >&2; exit 1 ;;
    garbage) echo "<html>proxy error</html>" ;;
    hang) sleep 30 ;;
esac
EOF
chmod +x "$MTCLI"
export FAKE_DIR="$TMP"
RPC_TOKEN=""

# script <line>... — what the fake app replies, call by call.
script() { printf '%s\n' "$@" >"$TMP/script"; rm -f "$TMP/calls"; }
calls() { cat "$TMP/calls" 2>/dev/null || echo 0; }

# --- state_query ------------------------------------------------------------

script 'answer {"channelHealth":{"recordingSilent":false}}'
status=0; out="$(state_query '.channelHealth.recordingSilent' 2>/dev/null)" || status=$?
[ "$status" -eq 0 ] && [ "$out" = false ] \
    && ok query_answered_false_is_an_answer || bad query_answered_false_is_an_answer "status $status, '$out'"

script 'answer {"lastJob":null}'
status=0; out="$(state_query '.lastJob.jobID // empty' 2>/dev/null)" || status=$?
[ "$status" -eq 0 ] && [ -z "$out" ] \
    && ok query_answered_absent_is_an_answer || bad query_answered_absent_is_an_answer "status $status, '$out'"

script 'answer {"pendingNamingJobs":[{"jobID":"a"},{"jobID":"b"}]}'
status=0; out="$(state_query '[.pendingNamingJobs[] | select(.jobID == $id)] | length' --arg id b 2>/dev/null)" || status=$?
[ "$status" -eq 0 ] && [ "$out" = 1 ] \
    && ok query_passes_jq_args || bad query_passes_jq_args "status $status, '$out'"

for reply in empty fail garbage; do
    script "$reply"
    status=0; out="$(state_query '.channelHealth.recordingSilent' 2>"$TMP/err")" || status=$?
    [ "$status" -eq 2 ] && [ -z "$out" ] && grep -q '^state_query: no answer from the app on /state' "$TMP/err" \
        && ok "query_${reply}_is_no_answer" || bad "query_${reply}_is_no_answer" "status $status, '$out', stderr '$(cat "$TMP/err")'"
done

# The refusal mt-cli printed is what a CI log needs to tell a dead app from a
# blocked one, so it has to come through.
script fail
state_query . 2>"$TMP/err" >/dev/null || true
grep -q 'not running on http://127.0.0.1:9876' "$TMP/err" \
    && ok query_reports_the_transport_error || bad query_reports_the_transport_error "$(cat "$TMP/err")"

script 'answer {"windows":null}'
status=0; state_query '.windows[]' >/dev/null 2>&1 || status=$?
[ "$status" -eq 3 ] && ok query_filter_error_is_its_own_status || bad query_filter_error_is_its_own_status "status $status"

# A wedged app must not hang the step: the read is bounded. The fake hangs for
# 30 s, so the wall clock is only a ceiling telling "bounded" from "waited it
# out": run_bounded's whole-second cap lets a 0.1 s bound run close to 3 s, and
# a loaded runner more, so the old 5 s judged the host rather than the bound.
script hang
start=$SECONDS status=0
STATE_READ_BOUND_S=0.1 state_query . >/dev/null 2>"$TMP/err" || status=$?
[ "$status" -eq 2 ] && [ $(( SECONDS - start )) -lt 20 ] && grep -q 'no reply within 0.1s' "$TMP/err" \
    && ok query_hang_is_bounded_no_answer || bad query_hang_is_bounded_no_answer "status $status after $(( SECONDS - start ))s: $(cat "$TMP/err")"

# --- state_read -------------------------------------------------------------

# A failed read keeps the last answer, which is what a timed-out poll shows.
script 'answer {"watchState":"recording"}' fail
state_read && [ "$(jq -r .watchState <<<"$STATE_BODY")" = recording ] || bad read_keeps_last_answer "first read"
status=0; state_read || status=$?
[ "$status" -eq 2 ] && [ "$(jq -r .watchState <<<"$STATE_BODY")" = recording ] && [ -n "$STATE_ERR" ] \
    && ok read_keeps_last_answer || bad read_keeps_last_answer "status $status, body '$STATE_BODY'"

# --- poll_state -------------------------------------------------------------

# The windows of the polls meant to hold are ceilings: they end at the read
# the condition holds on. The interval keeps a never-true condition from
# forking the fake back to back for the whole window.
script 'answer {"watchState":"watching"}' 'answer {"watchState":"recording"}'
status=0; poll_state 20 0.05 state_is '.watchState == "recording"' 2>/dev/null || status=$?
[ "$status" -eq 0 ] && ok poll_holds || bad poll_holds "status $status"

# The real false: the app answers throughout and the condition never holds.
script 'answer {"channelHealth":{"recordingSilent":false}}'
status=0; poll_state 0 0 state_is '.channelHealth.recordingSilent == true' 2>/dev/null || status=$?
[ "$status" -eq 1 ] && ok poll_answered_false_times_out || bad poll_answered_false_times_out "status $status"

# The CI case: the app never answers. Before, this was the same timeout as the
# case above; now it is a status of its own, and says why.
script fail
status=0; poll_state 0 0 state_is '.channelHealth.recordingSilent == true' 2>"$TMP/err" || status=$?
[ "$status" -eq 2 ] && grep -q 'no answer from the app on /state at the end' "$TMP/err" \
    && ok poll_no_answer_is_its_own_status || bad poll_no_answer_is_its_own_status "status $status: $(cat "$TMP/err")"

# A negative predicate is where no answer used to pass outright.
script empty
status=0; poll_state 0 0 state_is '[.windows[]? | select(.id == "speaker-naming") | .isVisible] | any | not' 2>/dev/null || status=$?
[ "$status" -eq 2 ] && ok poll_negative_check_does_not_pass_on_silence || bad poll_negative_check_does_not_pass_on_silence "status $status"

# The app goes quiet mid-poll and comes back: polling goes on, the gap is
# logged once each way, and the condition is still found.
script 'answer {"x":0}' fail fail fail 'answer {"x":1}'
status=0; poll_state 20 0.05 state_is '.x == 1' 2>"$TMP/err" || status=$?
[ "$status" -eq 0 ] && [ "$(grep -c 'still polling' "$TMP/err")" = 1 ] && grep -q 'answers /state again' "$TMP/err" \
    && ok poll_survives_a_gap || bad poll_survives_a_gap "status $status: $(cat "$TMP/err")"

# The deadline cases below run on a fake clock that advances one second per
# read, so "the window holds exactly N reads" does not hang on where in a
# wall-clock second the poll happened to start. poll_until reads the clock as
# `date +%s` (also inside $(...), where this function is visible too).
fake_clock_on()  { date() { if [ "${1:-}" = +%s ]; then echo $(( 1000 + $(calls) )); else command date "$@"; fi; }; }
fake_clock_off() { unset -f date; }

# Answered in the window, quiet at its end, answering again one read later: a
# single dropped read at the deadline is not a dead app, so the verdict is the
# condition's. A 2 s window on the fake clock is two reads (the second the
# dropped one), then the deadline read: three in all.
fake_clock_on
script 'answer {"x":0}' fail 'answer {"x":0}'
status=0; poll_state 2 0 state_is '.x == 1' 2>/dev/null || status=$?
[ "$status" -eq 1 ] && [ "$(calls)" = 3 ] \
    && ok poll_dropped_read_at_deadline || bad poll_dropped_read_at_deadline "status $status after $(calls) reads"

# The extra read only asks whether the app answers: a condition that first
# holds on it held after the window, not inside it, so the verdict stays the
# window's, and STATE_BODY stays its last answer.
script 'answer {"x":0}' fail 'answer {"x":1}'
status=0; poll_state 2 0 state_is '.x == 1' 2>/dev/null || status=$?
[ "$status" -eq 1 ] && [ "$(calls)" = 3 ] && [ "$(jq -r .x <<<"$STATE_BODY")" = 0 ] \
    && ok poll_late_truth_is_not_a_pass || bad poll_late_truth_is_not_a_pass "status $status after $(calls) reads, body '$STATE_BODY'"

# --judge-deadline-read is for a predicate judged by the snapshot's content (a
# new job that is terminal): there the same late answer is a pass, and
# STATE_BODY is the snapshot it held on.
script 'answer {"x":0}' fail 'answer {"x":1}'
status=0; poll_state --judge-deadline-read 2 0 state_is '.x == 1' 2>/dev/null || status=$?
[ "$status" -eq 0 ] && [ "$(calls)" = 3 ] && [ "$(jq -r .x <<<"$STATE_BODY")" = 1 ] \
    && ok poll_judged_deadline_read_can_pass || bad poll_judged_deadline_read_can_pass "status $status after $(calls) reads, body '$STATE_BODY'"

# ... and a deadline read it does not hold on is still the timeout, with the
# body that read brought.
script 'answer {"x":0}' fail 'answer {"x":2}'
status=0; poll_state --judge-deadline-read 2 0 state_is '.x == 1' 2>/dev/null || status=$?
[ "$status" -eq 1 ] && [ "$(calls)" = 3 ] \
    && ok poll_judged_deadline_read_false_times_out || bad poll_judged_deadline_read_false_times_out "status $status after $(calls) reads"

# ... nor does it pass a window the app never answered inside: what a caller
# gathers per tick would stand on nothing, so that is still no answer.
script fail fail 'answer {"x":1}'
status=0; poll_state --judge-deadline-read 2 0 state_is '.x == 1' 2>/dev/null || status=$?
[ "$status" -eq 2 ] && [ "$(calls)" = 3 ] \
    && ok poll_judged_deadline_read_needs_a_window_answer || bad poll_judged_deadline_read_needs_a_window_answer "status $status after $(calls) reads"

# --each runs at the start of every tick, before the read, answered or not, and
# once more before the deadline read. The hook logs the read count it saw.
EACH_SEEN=""
_each_log() { EACH_SEEN="$EACH_SEEN $(calls)"; }
script 'answer {"x":0}' fail fail
status=0; poll_state --each _each_log 3 0 state_is '.x == 1' 2>/dev/null || status=$?
[ "$status" -eq 2 ] && [ "$EACH_SEEN" = " 0 1 2 3" ] \
    && ok poll_each_runs_on_every_tick || bad poll_each_runs_on_every_tick "status $status, hook saw reads:$EACH_SEEN"

# The regression it exists for: the app is dead and refuses every read. The
# liveness check must still run and end the run at once, not after the window
# has been sat out as "no answer". The hook dies as assert_app_alive does,
# on its second tick, so exactly one read was made.
_dies_on_second() {
    DIE_TICKS=$(( ${DIE_TICKS:-0} + 1 ))
    [ "$DIE_TICKS" -lt 2 ] || { echo "app process is not running" >&2; exit 1; }
}
script fail
status=0; ( DIE_TICKS=0; poll_state --each _dies_on_second 100 0 state_is '.x == 1' ) 2>"$TMP/err" || status=$?
[ "$status" -eq 1 ] && [ "$(calls)" = 1 ] && grep -q 'app process is not running' "$TMP/err" \
    && ok poll_each_liveness_fails_while_reads_refused || bad poll_each_liveness_fails_while_reads_refused "status $status after $(calls) reads: $(cat "$TMP/err")"

# A hook that returns non-zero instead of exiting stops the poll with status 4,
# without another read.
_returns_false() { return 1; }
script fail
status=0; poll_state --each _returns_false 100 0 state_is '.x == 1' 2>/dev/null || status=$?
[ "$status" -eq 4 ] && [ "$(calls)" = 0 ] \
    && ok poll_each_nonzero_is_status_4 || bad poll_each_nonzero_is_status_4 "status $status after $(calls) reads"

# Not on the window's ticks but on the deadline read: still status 4, and no
# deadline read.
_false_on_third() { HOOK_TICKS=$(( HOOK_TICKS + 1 )); [ "$HOOK_TICKS" -lt 3 ]; }
HOOK_TICKS=0
script fail
status=0; poll_state --each _false_on_third 2 0 state_is '.x == 1' 2>/dev/null || status=$?
[ "$status" -eq 4 ] && [ "$(calls)" = 2 ] \
    && ok poll_each_checked_before_deadline_read || bad poll_each_checked_before_deadline_read "status $status after $(calls) reads"
fake_clock_off

# Never answered inside the window, answering only to the extra read: the
# condition had no window to happen in, so that is still no answer. A zero
# window is one read, then the extra one.
script fail 'answer {"x":0}'
status=0; poll_state 0 0 state_is '.x == 1' 2>"$TMP/err" || status=$?
[ "$status" -eq 2 ] && [ "$(calls)" = 2 ] && grep -q 'only after the 0s window' "$TMP/err" \
    && ok poll_answer_only_after_window_is_no_answer || bad poll_answer_only_after_window_is_no_answer "status $status after $(calls) reads: $(cat "$TMP/err")"

# A predicate function reads STATE_BODY and its assignments stay in this shell.
_stash() { SEEN="$(jq -r .x <<<"$STATE_BODY")"; [ "$SEEN" = 2 ]; }
SEEN=""
script 'answer {"x":1}' 'answer {"x":2}'
poll_state 5 0 _stash 2>/dev/null && [ "$SEEN" = 2 ] \
    && ok poll_predicate_runs_in_this_shell || bad poll_predicate_runs_in_this_shell "SEEN='$SEEN'"

# --- state_why --------------------------------------------------------------

[ "$(state_why 1 "never went true")" = "never went true" ] \
    && [ "$(state_why 2 "never went true")" = "no answer from the app on /state (reason logged above), so this went unchecked: never went true" ] \
    && state_why 3 x | grep -q 'jq filter failed' \
    && state_why 4 x | grep -q 'per-tick check handed to poll_state failed' \
    && ok why_words_each_status || bad why_words_each_status "$(state_why 2 x)"

# --- watch_state ------------------------------------------------------------

# The string form of the same distinction: no watch loop is empty, no answer
# is `unreadable`, never the same thing.
script 'answer {"watchState":"recording"}' 'answer {}' fail
[ "$(watch_state)" = recording ] && [ -z "$(watch_state)" ] && [ "$(watch_state)" = unreadable ] \
    && ok watch_state_tells_no_loop_from_no_answer || bad watch_state_tells_no_loop_from_no_answer "after $(calls) reads"

# --- the curl path ----------------------------------------------------------
#
# A driver holding RPC_TOKEN reads through curl. The fake curl plays the same
# script as the fake mt-cli, one line per call, with two more kinds of line:
# `http <code> [body]` (an answer with that status) and `timeout` (curl's
# own --max-time, exit 28); `fail` is curl's exit 7 for a refused
# connection, `answer <json>` is a 200, and `empty` exits 0 without even a
# status line. It writes the body to --output and the
# code for --write-out, as the real one does, and keeps its last arguments.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_DIR/curl-args"
out=/dev/stdout
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FAKE_DIR/calls"
line="$(sed -n "${n}p" "$FAKE_DIR/script")"
[ -n "$line" ] || line="$(tail -n 1 "$FAKE_DIR/script")"
case "$line" in
    answer\ *) printf '%s\n' "${line#answer }" >"$out"; printf 200 ;;
    http\ *)
        rest="${line#http }"
        code="${rest%% *}"
        body="${rest#"$code"}"
        printf '%s' "${body# }" >"$out"
        printf '%s' "$code" ;;
    empty) ;;
    fail) echo "curl: (7) Failed to connect to 127.0.0.1 port 9876: Connection refused" >&2; printf 000; exit 7 ;;
    hang) sleep 30 ;;
    timeout) echo "curl: (28) Operation timed out after 15001 milliseconds with 0 bytes received" >&2; printf 000; exit 28 ;;
esac
EOF
chmod +x "$TMP/bin/curl"
PATH="$TMP/bin:$PATH"
# shellcheck disable=SC2034 # read by the helpers
RPC_BASE=http://127.0.0.1:1
RPC_TOKEN=tok

script 'answer {"watchState":"recording"}'
out="$(state_query .watchState 2>/dev/null)" || true
[ "$out" = recording ] && grep -qx 'Authorization: Bearer tok' "$TMP/curl-args" \
    && grep -qx 'http://127.0.0.1:1/state' "$TMP/curl-args" \
    && ok curl_path_answers || bad curl_path_answers "'$out', args: $(tr '\n' ' ' <"$TMP/curl-args")"

# /state means one thing, so an HTTP error status is no answer about it, and
# its body is not handed to jq.
script 'http 500 {"error":"boom"}'
status=0; state_query .watchState >/dev/null 2>"$TMP/err" || status=$?
[ "$status" -eq 2 ] && grep -q 'answered HTTP 500' "$TMP/err" \
    && ok curl_http_error_is_no_answer || bad curl_http_error_is_no_answer "status $status: $(cat "$TMP/err")"

# A refused token is no usable answer on every reader, said as a refusal, and a
# poll stops on it at once: waiting does not mend a token.
script 'http 401 {"error":"unauthorized"}'
status=0; poll_state 100 0 state_is '.x == 1' 2>"$TMP/err" || status=$?
[ "$status" -eq 2 ] && [ "$(calls)" = 1 ] && [ "$RPC_REFUSED" = 1 ] && grep -q 'refused the request with HTTP 401' "$TMP/err" \
    && state_why 2 x | grep -q "refused the driver's token on /state" \
    && ok state_refusal_stops_the_poll || bad state_refusal_stops_the_poll "status $status after $(calls) reads: $(cat "$TMP/err")"

script fail
status=0; state_query .watchState >/dev/null 2>"$TMP/err" || status=$?
[ "$status" -eq 2 ] && grep -q 'exit 7' "$TMP/err" \
    && ok curl_refused_is_no_answer || bad curl_refused_is_no_answer "status $status: $(cat "$TMP/err")"

# --- rpc_read ---------------------------------------------------------------

script 'answer {"state":"done"}'
status=0; rpc_read /v1/jobs/j 2>/dev/null || status=$?
[ "$status" -eq 0 ] && [ "$RPC_STATUS" = 200 ] && [ "$(jq -r .state <<<"$RPC_BODY")" = "done" ] \
    && grep -qx 'http://127.0.0.1:1/v1/jobs/j' "$TMP/curl-args" && rpc_is '.state == "done"' \
    && ok rpc_answered_200 || bad rpc_answered_200 "status $status, $RPC_STATUS '$RPC_BODY'"

# The /v1 routes answer 404 and 409 on purpose: that is an answer, with its
# code. rpc_is wants a 200, so not even a negative filter holds on it.
script 'http 404 {"error":"unknown job"}'
status=0; rpc_read /v1/jobs/j 2>/dev/null || status=$?
[ "$status" -eq 0 ] && [ "$RPC_STATUS" = 404 ] && [ "$(jq -r .error <<<"$RPC_BODY")" = "unknown job" ] \
    && ! rpc_is '.state != "done"' \
    && ok rpc_answered_4xx_is_an_answer || bad rpc_answered_4xx_is_an_answer "status $status, $RPC_STATUS '$RPC_BODY'"

# A 200 with nothing in it is an answer too, and holds no filter, negative or
# not (jq 1.6 passes -e on empty input).
script 'http 200'
status=0; rpc_read /metrics 2>/dev/null || status=$?
[ "$status" -eq 0 ] && [ "$RPC_STATUS" = 200 ] && [ -z "$RPC_BODY" ] && ! rpc_is '.x | not' \
    && ok rpc_answered_empty_body || bad rpc_answered_empty_body "status $status, $RPC_STATUS '$RPC_BODY'"

# No status line at all is no answer. A failed read keeps the last answer and
# says why, on stderr as well, since a one-shot caller has no poll to log it.
script 'http 409 {"error":"busy"}' empty fail
rpc_read /v1/jobs/j 2>/dev/null || bad rpc_no_status_is_no_answer "first read"
status=0; rpc_read /v1/jobs/j 2>"$TMP/err" || status=$?
[ "$status" -eq 2 ] && [ "$RPC_STATUS" = 409 ] && grep -q 'no usable answer from the app on /v1/jobs/j (no HTTP status' "$TMP/err" \
    && ok rpc_no_status_is_no_answer || bad rpc_no_status_is_no_answer "status $status, $RPC_STATUS: $(cat "$TMP/err")"
status=0; rpc_read /v1/jobs/j 2>/dev/null || status=$?
[ "$status" -eq 2 ] && [ "$RPC_STATUS" = 409 ] && [ "$(jq -r .error <<<"$RPC_BODY")" = busy ] && [[ "$RPC_ERR" == *"exit 7"*"Connection refused"* ]] \
    && ok rpc_transport_failure_is_no_answer || bad rpc_transport_failure_is_no_answer "status $status, $RPC_STATUS '$RPC_BODY', err '$RPC_ERR'"

script hang
start=$SECONDS status=0
RPC_READ_BOUND_S=0.1 rpc_read /v1/jobs/j 2>/dev/null || status=$?
[ "$status" -eq 2 ] && [ $(( SECONDS - start )) -lt 20 ] && [ "$RPC_ERR" = "no reply within 0.1s" ] \
    && ok rpc_hang_is_bounded_no_answer || bad rpc_hang_is_bounded_no_answer "status $status after $(( SECONDS - start ))s: $RPC_ERR"

# curl's own --max-time usually fires just before run_bounded: the same no reply.
script timeout
status=0; rpc_read /v1/jobs/j 2>/dev/null || status=$?
[ "$status" -eq 2 ] && [ "$RPC_ERR" = "no reply within 15s" ] \
    && ok rpc_curl_timeout_is_no_reply || bad rpc_curl_timeout_is_no_reply "status $status: $RPC_ERR"

script 'http 403 {"error":"origin"}'
status=0; rpc_read /v1/jobs/j 2>/dev/null || status=$?
[ "$status" -eq 2 ] && [ "$RPC_REFUSED" = 1 ] && [[ "$(rpc_why 2 /v1/jobs/j x)" == "the app refused the driver's token on /v1/jobs/j"* ]] \
    && ok rpc_refusal_is_no_usable_answer || bad rpc_refusal_is_no_usable_answer "status $status, refused '$RPC_REFUSED'"

status=0; ( RPC_TOKEN=""; rpc_read /metrics ) 2>"$TMP/err" || status=$?
[ "$status" -eq 2 ] && grep -q 'RPC_TOKEN is not set' "$TMP/err" \
    && ok rpc_no_token_is_reported || bad rpc_no_token_is_reported "status $status: $(cat "$TMP/err")"

# A /state read between a caller's rpc_read and its use of RPC_BODY does not
# overwrite it.
script 'http 404 {"error":"unknown job"}' 'answer {"watchState":"idle"}'
rpc_read /v1/jobs/j 2>/dev/null && state_read && [ "$RPC_STATUS" = 404 ] && [ "$(jq -r .error <<<"$RPC_BODY")" = "unknown job" ] \
    && ok rpc_body_survives_a_state_read || bad rpc_body_survives_a_state_read "$RPC_STATUS '$RPC_BODY'"

# --- poll_rpc ---------------------------------------------------------------

# A job not there yet (404, allowed with --not-yet), then running, then done.
script 'http 404 {"error":"unknown job"}' 'answer {"state":"transcribing"}' 'answer {"state":"done"}'
status=0; poll_rpc /v1/jobs/j --not-yet 404 20 0.05 rpc_is '.state == "done"' 2>/dev/null || status=$?
[ "$status" -eq 0 ] && [ "$(calls)" = 3 ] && ok rpc_poll_holds || bad rpc_poll_holds "status $status after $(calls) reads"

# Without --not-yet a 404 cannot turn into a 200: status 5 at once, worded so.
# A 5xx is the same; a 409 is a "not yet".
script 'answer {"state":"transcribing"}' 'http 404 {"error":"unknown job"}'
status=0; poll_rpc /v1/jobs/j 100 0 rpc_is '.state == "done"' 2>"$TMP/err" || status=$?
[ "$status" -eq 5 ] && [ "$(calls)" = 2 ] && grep -q 'HTTP 404, which waiting cannot turn into a 200' "$TMP/err" \
    && [[ "$(rpc_why 5 /v1/jobs/j "never done")" == *"cannot get past"*"never done (last answer: HTTP 404"* ]] \
    && ok rpc_poll_unsettled_code_stops || bad rpc_poll_unsettled_code_stops "status $status after $(calls) reads: $(rpc_why 5 /v1/jobs/j "never done")"
script 'http 503 {}'
status=0; poll_rpc /v1/jobs/j 100 0 rpc_is '.state == "done"' 2>/dev/null || status=$?
[ "$status" -eq 5 ] && [ "$(calls)" = 1 ] || bad rpc_poll_5xx_and_409 "503: status $status after $(calls) reads"
script 'http 409 {}' 'answer {"state":"done"}'
status=0; poll_rpc /v1/jobs/j 20 0.05 rpc_is '.state == "done"' 2>/dev/null || status=$?
[ "$status" -eq 0 ] && ok rpc_poll_5xx_and_409 || bad rpc_poll_5xx_and_409 "409: status $status"

# A refusal stops the poll at once as no usable answer.
script 'http 401 {}'
status=0; poll_rpc /v1/jobs/j 100 0 rpc_is '.state == "done"' 2>/dev/null || status=$?
[ "$status" -eq 2 ] && [ "$(calls)" = 1 ] && ok rpc_poll_refusal_stops || bad rpc_poll_refusal_stops "status $status after $(calls) reads"

# The real false, and rpc_why names the answer the poll ended on.
script 'answer {"state":"transcribing"}'
status=0; poll_rpc /v1/jobs/j 0 0 rpc_is '.state == "done"' 2>/dev/null || status=$?
[ "$status" -eq 1 ] && [ "$(rpc_why 1 /v1/jobs/j "never done")" = 'never done (last answer: HTTP 200 {"state":"transcribing"})' ] \
    && [ "$(rpc_why 1 /other "no snapshot")" = "no snapshot" ] \
    && ok rpc_poll_answered_false_times_out || bad rpc_poll_answered_false_times_out "status $status: $(rpc_why 1 /v1/jobs/j "never done")"

# rpc_field reads a field only out of a 200.
script 'answer {"state":"done"}' 'http 404 {"state":"stale"}'
rpc_read /v1/jobs/j 2>/dev/null; a="$(rpc_field .state)"
rpc_read /v1/jobs/j 2>/dev/null; status=0; b="$(rpc_field .state)" || status=$?
[ "$a" = "done" ] && [ -z "$b" ] && [ "$status" -ne 0 ] \
    && ok rpc_field_only_from_a_200 || bad rpc_field_only_from_a_200 "'$a' '$b' status $status"

# metrics_snapshot: a snapshot, an answer that is none (1, worded with that
# answer), no answer (2), a refusal (2, worded as one).
script 'answer {"monotonicTimeSeconds":5}' 'http 200 {}' fail 'http 401 {}'
metrics_snapshot 2>/dev/null && [ "$(jq -r .monotonicTimeSeconds <<<"$RPC_BODY")" = 5 ] \
    || bad metrics_snapshot_statuses "first read: '$RPC_BODY'"
status=0; metrics_snapshot 2>/dev/null || status=$?
[ "$status" -eq 1 ] && [ "$(rpc_why 1 /metrics "no snapshot")" = "no snapshot (last answer: HTTP 200 {})" ] \
    || bad metrics_snapshot_statuses "second read: status $status, $(rpc_why "$status" /metrics "no snapshot")"
status=0; metrics_snapshot 2>/dev/null || status=$?
[ "$status" -eq 2 ] || bad metrics_snapshot_statuses "third read: status $status"
status=0; metrics_snapshot 2>/dev/null || status=$?
[ "$status" -eq 2 ] && [[ "$(rpc_why 2 /metrics x)" == "the app refused the driver's token on /metrics"* ]] \
    && ok metrics_snapshot_statuses || bad metrics_snapshot_statuses "fourth read: status $status, $(rpc_why 2 /metrics x)"

script fail
status=0; poll_rpc /v1/jobs/j 0 0 rpc_is '.state == "done"' 2>"$TMP/err" || status=$?
[ "$status" -eq 2 ] && grep -q 'poll_rpc: no answer from the app on /v1/jobs/j at the end of the 0s window' "$TMP/err" \
    && [ "$(rpc_why 2 /v1/jobs/j "job never finished")" = "no answer from the app on /v1/jobs/j (reason logged above), so this went unchecked: job never finished" ] \
    && ok rpc_poll_no_answer_is_its_own_status || bad rpc_poll_no_answer_is_its_own_status "status $status: $(cat "$TMP/err")"

script 'answer {"state":"waiting"}' fail fail 'answer {"state":"done"}'
status=0; poll_rpc /v1/jobs/j 20 0.05 rpc_is '.state == "done"' 2>"$TMP/err" || status=$?
[ "$status" -eq 0 ] && [ "$(grep -c 'still polling' "$TMP/err")" = 1 ] && grep -q 'answers /v1/jobs/j again' "$TMP/err" \
    && ok rpc_poll_survives_a_gap || bad rpc_poll_survives_a_gap "status $status: $(cat "$TMP/err")"

# The deadline rule is poll_state's: a late truth is not a pass, and the answer
# variables, the status with the body, are put back to the window's last.
fake_clock_on
script 'http 404 {"error":"unknown job"}' fail 'answer {"state":"done"}'
status=0; poll_rpc /v1/jobs/j --not-yet 404 2 0 rpc_is '.state == "done"' 2>/dev/null || status=$?
[ "$status" -eq 1 ] && [ "$(calls)" = 3 ] && [ "$RPC_STATUS" = 404 ] && [ "$(jq -r .error <<<"$RPC_BODY")" = "unknown job" ] \
    && ok rpc_poll_late_truth_restores_status_and_body || bad rpc_poll_late_truth_restores_status_and_body "status $status after $(calls) reads, $RPC_STATUS '$RPC_BODY'"

script 'http 404 {"error":"unknown job"}' fail 'answer {"state":"done"}'
status=0; poll_rpc /v1/jobs/j --judge-deadline-read --not-yet 404 2 0 rpc_is '.state == "done"' 2>/dev/null || status=$?
[ "$status" -eq 0 ] && [ "$RPC_STATUS" = 200 ] \
    && ok rpc_poll_judged_deadline_read_can_pass || bad rpc_poll_judged_deadline_read_can_pass "status $status, $RPC_STATUS"

# --each, on an unanswered tick as on an answered one.
EACH_SEEN=""
script 'answer {"state":"waiting"}' fail fail
status=0; poll_rpc /v1/jobs/j --each _each_log 3 0 rpc_is '.state == "done"' 2>/dev/null || status=$?
[ "$status" -eq 2 ] && [ "$EACH_SEEN" = " 0 1 2 3" ] \
    && ok rpc_poll_each_runs_on_every_tick || bad rpc_poll_each_runs_on_every_tick "status $status, hook saw reads:$EACH_SEEN"
fake_clock_off

# Neither transport configured: no answer with a reason, not a crash.
status=0; ( MTCLI="" RPC_TOKEN=""; state_query . ) >/dev/null 2>"$TMP/err" || status=$?
[ "$status" -eq 2 ] && grep -q 'neither RPC_TOKEN nor MTCLI' "$TMP/err" \
    && ok no_transport_is_reported || bad no_transport_is_reported "status $status: $(cat "$TMP/err")"

COMPLETED=1
echo "$PASSED passed"
