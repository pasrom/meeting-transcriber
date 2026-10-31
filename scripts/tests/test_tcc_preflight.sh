#!/bin/bash
# Regression test for the helpers that keep a pending TCC consent prompt from
# hanging an e2e lane, and for scripts/ci/tcc-preflight.sh built on them.
#
# A real prompt cannot be raised here, so the blocked call is a fake that
# sleeps forever: it has to come back as `blocked` within the bound and be
# gone afterwards. A fake that refuses at once has to read as `denied`, and a
# real read as `granted`. Plus the grantee resolution over crafted process
# tables, and the reaper that ends a driver a step timeout left behind, by
# recorded pid and start time only.
# shellcheck disable=SC2015  # `check && ok || bad`: `ok` only prints and counts
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

TMP="$(mktemp -d)"
PASSED=0
# Set at the very end: on bash 3.2 a `set -u` abort under an EXIT trap exits 0,
# so without it this file could pass having run none of its cases.
COMPLETED=0
PIDS=""
finish() {
    local rc=$? pid
    for pid in $PIDS; do kill -KILL "$pid" 2>/dev/null || true; done
    rm -rf "$TMP"
    if [ "$COMPLETED" -ne 1 ]; then
        echo "FAIL: the test aborted before reaching its end" >&2
        exit 1
    fi
    exit "$rc"
}
trap finish EXIT
ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

# --- run_bounded ---------------------------------------------------------------

status=0
out="$(run_bounded 5 sh -c 'echo hello; echo oops >&2; exit 3' 2>"$TMP/err")" || status=$?
[ "$status" -eq 3 ] && [ "$out" = hello ] && [ "$(cat "$TMP/err")" = oops ] \
    && ok bounded_passes_status_stdout_and_stderr || bad bounded_passes_status_stdout_and_stderr "status $status out '$out'"

# The fake records its own pid, so the test can prove the kill reached the
# process doing the blocking and not only the subshell around it.
cat >"$TMP/forever" <<EOF
#!/bin/sh
echo \$\$ >"$TMP/forever.pid"
echo started
exec sleep 300
EOF
chmod +x "$TMP/forever"
# A full second: the fake has to start, write its pid and print, which a cold,
# loaded host (a fresh checkout on CI) does not reliably do within 0.2 s.
status=0
t0="$(now_ms)"
out="$(run_bounded 1 "$TMP/forever")" || status=$?
elapsed=$(( $(now_ms) - t0 ))
blocked_pid="$(cat "$TMP/forever.pid" 2>/dev/null || true)"
PIDS="$PIDS $blocked_pid"
[ "$status" -eq 124 ] && [ "$elapsed" -lt 2500 ] && [ "$out" = started ] \
    && ok bounded_reports_a_hang_within_the_bound || bad bounded_reports_a_hang_within_the_bound "status $status after ${elapsed}ms, out '$out'"
[ -n "$blocked_pid" ] && poll_until 2 0.1 _no_pid_alive "$blocked_pid" \
    && ok bounded_kills_the_blocked_process || bad bounded_kills_the_blocked_process "pid '$blocked_pid' still alive"

# Under errexit, a failing command must still report its status.
status=0
( set -e; run_bounded 5 false ) || status=$?
[ "$status" -eq 1 ] && ok bounded_reports_failure_under_errexit || bad bounded_reports_failure_under_errexit "status $status"

# --- tcc_probe_verdict -----------------------------------------------------------

expect_verdict() {
    local name="$1" status="$2" output="$3" want="$4" got
    got="$(tcc_probe_verdict "$status" "$output")"
    [ "$got" = "$want" ] && ok "$name" || bad "$name" "got '$got', want '$want'"
}
expect_verdict verdict_success_is_granted 0 "" granted
expect_verdict verdict_bound_is_blocked 124 "" blocked
expect_verdict verdict_applescript_timeout_is_blocked 1 "execution error: System Events got an error: AppleEvent timed out. (-1712)" blocked
expect_verdict verdict_files_refusal_is_denied 1 "ls: /Users/x/Downloads: Operation not permitted" denied
expect_verdict verdict_automation_refusal_is_denied 1 "execution error: Not authorized to send Apple events to System Events. (-1743)" denied
expect_verdict verdict_other_failure_is_error 1 "ls: /nope: No such file or directory" error

# --- grantee resolution --------------------------------------------------------

# The runner chain as launchd starts it: runsvc.sh (bash) -> node (started by
# a relative path) -> listener -> worker -> step shell. A second node further
# down (a JavaScript action) must not win over the service's.
runner_table='    1     0 /sbin/launchd
  100     1 /bin/bash
  101   100 ./externals/node24/bin/node
  102   101 /Users/r/runners/a/bin/Runner.Listener
  103   102 /Users/r/runners/a/bin/Runner.Worker
  104   103 /Users/r/runners/a/externals/node24/bin/node
  105   104 /bin/bash'
got="$(_tcc_grantee_from_ps 105 <<<"$runner_table")"
[ "$got" = "101 ./externals/node24/bin/node" ] && ok grantee_is_the_service_node || bad grantee_is_the_service_node "'$got'"

terminal_table='    1     0 /sbin/launchd
  200     1 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
  201   200 /usr/bin/login
  202   201 /bin/zsh
  203   202 /bin/bash'
got="$(_tcc_grantee_from_ps 203 <<<"$terminal_table")"
[ "$got" = "200 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal" ] \
    && ok grantee_falls_back_to_the_topmost_ancestor || bad grantee_falls_back_to_the_topmost_ancestor "'$got'"

_tcc_grantee_from_ps 999 <<<"$terminal_table" >/dev/null \
    && bad grantee_unknown_pid_fails "status 0" || ok grantee_unknown_pid_fails

[ -n "$(tcc_grantee)" ] && ok grantee_resolves_for_this_process || bad grantee_resolves_for_this_process "empty"

# --- quit_running_app: an AppleScript quit the grant blocks is not a quit ------

# A stand-in "app" whose command line carries a unique marker, and a fake
# osascript first on PATH (its mode in $TMP/osa-mode). Only a refusal (-1743)
# is the missing Automation grant: an error naming it, status 2, and the
# stand-in is still ended. No answer (-1712) while the app stays is no verdict
# on the grant (a pending prompt, a modal run loop, a long teardown): a warning
# naming the causes, the app ended by signal, status 0, so a lane that calls
# this bare under `set -e` is not turned red. No answer but the app quits in
# the wait after it: its own quit, status 0, nothing reported. Another error
# (-600) is not a grant question either: the short wait, nothing reported
# (here the app goes within it). Answered:
# status 0, nothing reported. The app's hold is cut to 1 s for the test.
mkdir -p "$TMP/bin"
marker="e2e-quit-probe-$$"
cat >"$TMP/bin/osascript" <<EOF
#!/bin/sh
case "\$(cat "$TMP/osa-mode")" in
    refuse) echo "execution error: Not authorized to send Apple events to MeetingTranscriber-Dev. (-1743)" >&2; exit 1 ;;
    timeout) echo "execution error: MeetingTranscriber-Dev got an error: AppleEvent timed out. (-1712)" >&2; exit 1 ;;
    other) ( sleep 0.5; kill \$(cat "$TMP/quit-app.pid") ) >/dev/null 2>&1 &
           echo "execution error: MeetingTranscriber-Dev got an error: Application isn't running. (-600)" >&2; exit 1 ;;
    late) ( sleep 0.5; kill \$(cat "$TMP/quit-app.pid") ) >/dev/null 2>&1 &
          echo "execution error: MeetingTranscriber-Dev got an error: AppleEvent timed out. (-1712)" >&2; exit 1 ;;
    *) kill \$(cat "$TMP/quit-app.pid") 2>/dev/null ;;
esac
EOF
chmod +x "$TMP/bin/osascript"
start_quit_app() {
    ( exec -a "$marker" sleep 300 ) &
    echo $! >"$TMP/quit-app.pid"
    disown "$(cat "$TMP/quit-app.pid")"
    PIDS="$PIDS $(cat "$TMP/quit-app.pid")"
}

expect_quit() {
    local name="$1" mode="$2" want="$3" annotation="$4" status=0 out
    echo "$mode" >"$TMP/osa-mode"
    start_quit_app
    out="$(PATH="$TMP/bin:$PATH" E2E_APP_QUIT_HOLD_S=1 quit_running_app some.bundle "$marker" 2>&1)" || status=$?
    if [ "$status" -eq "$want" ] && _no_pid_alive "$(cat "$TMP/quit-app.pid")" \
        && case "$annotation" in
               error) grep -q '^::error title=TCC Automation → MeetingTranscriber-Dev not usable::' <<<"$out" ;;
               warning) grep -q '^::warning title=dev app did not quit::.*Possible causes: a pending Automation → MeetingTranscriber-Dev prompt' <<<"$out" \
                   && ! grep -q '^::error' <<<"$out" ;;
               *) [ -z "$out" ] ;;
           esac; then
        ok "$name"
    else
        bad "$name" "status $status: $out"
    fi
}
expect_quit quit_reports_a_refused_apple_event_as_the_grant refuse 2 error
expect_quit quit_warns_on_an_unanswered_quit_that_never_lands timeout 0 warning
expect_quit quit_accepts_an_unanswered_quit_that_lands_late late 0 none
expect_quit quit_treats_another_error_as_no_grant_question other 0 none
expect_quit quit_answered_is_a_clean_quit answer 0 none

# --- e2e_tcc_prompt_timeout ---------------------------------------------------------

[ "$(E2E_TCC_PROMPT_TIMEOUT=010 e2e_tcc_prompt_timeout)" = 10 ] && [ "$(E2E_TCC_PROMPT_TIMEOUT='' e2e_tcc_prompt_timeout)" = 10 ] \
    && ok prompt_timeout_reads_base_ten_with_a_default || bad prompt_timeout_reads_base_ten_with_a_default "wrong value"
E2E_TCC_PROMPT_TIMEOUT=0 e2e_tcc_prompt_timeout 2>/dev/null && bad prompt_timeout_rejects_zero "accepted" || ok prompt_timeout_rejects_zero
E2E_TCC_PROMPT_TIMEOUT=1.5 e2e_tcc_prompt_timeout 2>/dev/null && bad prompt_timeout_rejects_a_fraction "accepted" || ok prompt_timeout_rejects_a_fraction

# --- tcc-preflight.sh -------------------------------------------------------------

mkdir -p "$TMP/home/Downloads"
preflight() {
    E2E_TCC_PROMPT_TIMEOUT=1 TCC_PREFLIGHT_HOME="$TMP/home" TCC_PREFLIGHT_GRANTEE=/runner/externals/node99/bin/node \
        GITHUB_STEP_SUMMARY="$TMP/summary" "$@" bash "$ROOT/scripts/ci/tcc-preflight.sh" "${PREFLIGHT_ARGS[@]}"
}
PREFLIGHT_ARGS=(--downloads)

status=0
out="$(preflight env 2>&1)" || status=$?
[ "$status" -eq 0 ] && grep -q 'Downloads: granted' <<<"$out" \
    && ok preflight_real_read_is_granted || bad preflight_real_read_is_granted "status $status: $out"

cat >"$TMP/ls-forever" <<EOF
#!/bin/sh
exec sleep 300
EOF
cat >"$TMP/ls-denied" <<'EOF'
#!/bin/sh
echo "ls: $2: Operation not permitted" >&2
exit 1
EOF
chmod +x "$TMP/ls-forever" "$TMP/ls-denied"

status=0
: >"$TMP/summary"
t0="$(now_ms)"
out="$(preflight env TCC_PREFLIGHT_BOUND=0.3 TCC_PREFLIGHT_LS="$TMP/ls-forever" 2>&1)" || status=$?
elapsed=$(( $(now_ms) - t0 ))
[ "$status" -eq 1 ] && [ "$elapsed" -lt 3000 ] \
    && grep -q '^::error title=TCC Files & Folders → Downloads not usable::no answer within 0.3s: a consent prompt is probably waiting' <<<"$out" \
    && grep -q 'allow /runner/externals/node99/bin/node' <<<"$out" \
    && grep -q 'not usable (blocked)' "$TMP/summary" \
    && ok preflight_blocked_read_fails_fast_naming_grant_and_binary \
    || bad preflight_blocked_read_fails_fast_naming_grant_and_binary "status $status after ${elapsed}ms: $out"

status=0
out="$(preflight env TCC_PREFLIGHT_LS="$TMP/ls-denied" 2>&1)" || status=$?
[ "$status" -eq 1 ] && grep -q '^::error title=TCC Files & Folders → Downloads not usable::refused: ls: .*Operation not permitted' <<<"$out" \
    && ok preflight_denied_read_fails || bad preflight_denied_read_fails "status $status: $out"

# Automation and Accessibility only warn.
cat >"$TMP/osa" <<'EOF'
#!/bin/sh
case "$*" in
    *AXIsProcessTrusted*) echo false ;;
    *) echo "execution error: Not authorized to send Apple events to System Events. (-1743)" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/osa"
PREFLIGHT_ARGS=(--automation --accessibility)
status=0
out="$(preflight env TCC_PREFLIGHT_OSASCRIPT="$TMP/osa" 2>&1)" || status=$?
[ "$status" -eq 0 ] \
    && grep -q '^::warning title=TCC Automation → System Events not usable::refused: .*-1743' <<<"$out" \
    && grep -q '^::warning title=TCC Device Control and Data Access (Accessibility) not usable::refused: AXIsProcessTrusted() is false' <<<"$out" \
    && ok preflight_optional_grants_only_warn || bad preflight_optional_grants_only_warn "status $status: $out"

status=0
"$ROOT/scripts/ci/tcc-preflight.sh" --bogus >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] && ok preflight_usage_error || bad preflight_usage_error "status $status"

# --- leftover-driver reaper ---------------------------------------------------------

list="$TMP/drivers"
# A stand-in for a driver stuck in a blocked call, with a child of its own.
sh -c 'sleep 300 & wait' &
stuck=$!
disown "$stuck"
PIDS="$PIDS $stuck"
poll_until 2 0.1 sh -c "pgrep -P $stuck >/dev/null" || bad reaper_setup "the stand-in has no child"
stuck_child="$(pgrep -P "$stuck")"
PIDS="$PIDS $stuck_child"
# A live process recorded with a different start time: a reused pid, which
# must not be touched.
sleep 300 &
reused=$!
disown "$reused"
PIDS="$PIDS $reused"
{
    printf '%s\t%s\t%s\n' "$stuck" "$(ps -o lstart= -p "$stuck")" e2e-app.sh
    printf '%s\t%s\t%s\n' "$reused" "Thu Jan  1 00:00:00 1970" e2e-app.sh
    printf '%s\t%s\t%s\n' "$$" "$(ps -o lstart= -p $$)" e2e-browser.sh
} >"$list"
out="$(E2E_REAP_UNBLOCK_S=1 e2e_reap_registered_drivers "$list")"
_no_pid_alive "$stuck" "$stuck_child" \
    && ok reaper_ends_the_recorded_driver_and_its_children || bad reaper_ends_the_recorded_driver_and_its_children "still alive: $stuck $stuck_child"
_pid_is_alive "$reused" && ok reaper_spares_a_reused_pid || bad reaper_spares_a_reused_pid "pid $reused was killed"
grep -q "^::warning title=leftover e2e driver::e2e-app.sh (pid $stuck)" <<<"$out" \
    && ok reaper_says_what_it_ended || bad reaper_says_what_it_ended "'$out'"
[ "$(cut -f1 "$list")" = "$$" ] && ok reaper_keeps_its_own_ancestors_listed || bad reaper_keeps_its_own_ancestors_listed "$(cat "$list")"
kill -KILL "$reused" 2>/dev/null || true

# A driver nested in another, the way the callers run it: e2e-channel-fault.sh
# runs `e2e-app.sh --redeploy-only || die` in the foreground under an EXIT-only
# cleanup trap. Both are registered. The inner one's blocked call is what the
# reaper kills; the inner driver itself must be TERMed, not SIGKILLed with the
# other children, and the outer one's cleanup must get to run to its end
# rather than be cut off by a TERM sent after it began.
cat >"$TMP/nested-inner" <<EOF
#!/bin/bash
echo \$\$ >"$TMP/inner.pid"
trap 'echo inner >"$TMP/inner.trap"' EXIT
sleep 300
EOF
cat >"$TMP/nested-outer" <<EOF
#!/bin/bash
echo \$\$ >"$TMP/outer.pid"
trap 'echo start >"$TMP/outer.cleanup"; sleep 0.3; echo done >>"$TMP/outer.cleanup"' EXIT
bash "$TMP/nested-inner" || exit 1
EOF
( bash "$TMP/nested-outer" >/dev/null 2>&1 & )
poll_until 2 0.1 test -s "$TMP/inner.pid" || bad reaper_nested_setup "the inner stand-in did not start"
outer="$(cat "$TMP/outer.pid")"
inner="$(cat "$TMP/inner.pid")"
PIDS="$PIDS $outer $inner"
{
    printf '%s\t%s\t%s\n' "$outer" "$(ps -o lstart= -p "$outer")" e2e-channel-fault.sh
    printf '%s\t%s\t%s\n' "$inner" "$(ps -o lstart= -p "$inner")" e2e-app.sh
} >"$list"
E2E_REAP_UNBLOCK_S=1 E2E_REAP_GRACE_S=3 e2e_reap_registered_drivers "$list" >/dev/null
_no_pid_alive "$outer" "$inner" && [ -s "$TMP/inner.trap" ] \
    && [ "$(tr '\n' ' ' <"$TMP/outer.cleanup" 2>/dev/null)" = "start done " ] \
    && ok reaper_lets_nested_drivers_finish_their_traps \
    || bad reaper_lets_nested_drivers_finish_their_traps "inner trap: '$(cat "$TMP/inner.trap" 2>/dev/null)', outer cleanup: '$(tr '\n' ' ' <"$TMP/outer.cleanup" 2>/dev/null)'"

# A driver that traps only EXIT (e2e-silent-recording.sh) runs its cleanup the
# moment TERM arrives, and that cleanup acts on the app it started as its own
# child, after other work (restoring settings). The child must still be there
# when it does: SIGKILLing the children together with the TERM took it away
# first.
cat >"$TMP/exit-only" <<EOF
#!/bin/bash
sleep 300 &
app=\$!
echo \$\$ >"$TMP/exit-only.pid"
trap 'sleep 0.3; if kill -0 \$app 2>/dev/null; then echo alive; else echo gone; fi >"$TMP/exit-only.cleanup"; kill \$app' EXIT
wait
EOF
( bash "$TMP/exit-only" >/dev/null 2>&1 & )
poll_until 2 0.1 test -s "$TMP/exit-only.pid" || bad reaper_exit_only_setup "the stand-in did not start"
eo="$(cat "$TMP/exit-only.pid")"
PIDS="$PIDS $eo"
printf '%s\t%s\t%s\n' "$eo" "$(ps -o lstart= -p "$eo")" e2e-silent-recording.sh >"$list"
E2E_REAP_UNBLOCK_S=2 E2E_REAP_GRACE_S=4 e2e_reap_registered_drivers "$list" >/dev/null
_no_pid_alive "$eo" && [ "$(cat "$TMP/exit-only.cleanup" 2>/dev/null)" = alive ] \
    && ok reaper_leaves_the_app_child_to_the_drivers_cleanup \
    || bad reaper_leaves_the_app_child_to_the_drivers_cleanup "cleanup saw the app: '$(cat "$TMP/exit-only.cleanup" 2>/dev/null)'"

# Sourcing alone has no side effect: run as a driver would be named, in CI,
# with a writable list directory, and nothing may be recorded.
mkdir -p "$TMP/rt3"
printf '#!/bin/bash\nsource "%s/scripts/lib/e2e-helpers.sh"\n' "$ROOT" >"$TMP/e2e-source-only.sh"
GITHUB_ACTIONS=true RUNNER_TEMP="$TMP/rt3" bash "$TMP/e2e-source-only.sh"
[ ! -e "$TMP/rt3/e2e-driver-pids" ] && ok sourcing_registers_nothing || bad sourcing_registers_nothing "wrote on source: $(cat "$TMP/rt3/e2e-driver-pids")"

# Each driver calls e2e_register_driver right after sourcing the helpers: in
# CI it records the driver; outside CI it does nothing.
printf '#!/bin/bash\nsource "%s/scripts/lib/e2e-helpers.sh"\ne2e_register_driver\necho $$\n' "$ROOT" >"$TMP/e2e-fake.sh"
mkdir -p "$TMP/rt"
fake_pid="$(GITHUB_ACTIONS=true RUNNER_TEMP="$TMP/rt" bash "$TMP/e2e-fake.sh")"
[ "$(cut -f1,3 "$TMP/rt/e2e-driver-pids")" = "$fake_pid"$'\t'"e2e-fake.sh" ] \
    && ok register_records_the_driver || bad register_records_the_driver "$(cat "$TMP/rt/e2e-driver-pids" 2>/dev/null)"
# A driver starting in a later step ends what an earlier step left behind
# before it records itself.
sleep 300 &
left=$!
disown "$left"
PIDS="$PIDS $left"
printf '%s\t%s\t%s\n' "$left" "$(ps -o lstart= -p "$left")" e2e-app.sh >"$TMP/rt/e2e-driver-pids"
fake_pid="$(GITHUB_ACTIONS=true RUNNER_TEMP="$TMP/rt" bash "$TMP/e2e-fake.sh" 2>/dev/null | tail -1)"
_no_pid_alive "$left" && [ "$(cut -f1 "$TMP/rt/e2e-driver-pids")" = "$fake_pid" ] \
    && ok register_ends_a_leftover_driver_first || bad register_ends_a_leftover_driver_first "left $left, list $(cat "$TMP/rt/e2e-driver-pids")"
GITHUB_ACTIONS='' RUNNER_TEMP="$TMP/rt2" bash "$TMP/e2e-fake.sh" >/dev/null
[ ! -e "$TMP/rt2" ] && ok register_is_a_no_op_outside_ci || bad register_is_a_no_op_outside_ci "wrote outside CI"

COMPLETED=1
echo "$PASSED passed"
