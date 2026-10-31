#!/bin/bash
# Regression test for the helpers that keep a pending TCC consent prompt from
# hanging an e2e lane, and for scripts/ci/tcc-preflight.sh built on them.
#
# A real prompt cannot be raised here, so the blocked call is a fake that
# sleeps forever: it has to come back as `blocked` within the bound and be
# gone afterwards. A fake that refuses at once has to read as `denied`, and a
# real read as `granted`. Plus the grantee resolution over crafted process
# tables.
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

COMPLETED=1
echo "$PASSED passed"
