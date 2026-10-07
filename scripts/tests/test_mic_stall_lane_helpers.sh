#!/bin/bash
# Regression test for the helpers the --mic-stall lane of e2e-app.sh undoes its
# changes with, and for the guard that keeps it away from an installed app.
#
# The lane switches the dev bundle's protocolProvider to `none` and runs the app
# in a throwaway home. Both have to be undone across runs, a killed one
# included, without overwriting a choice made since and without removing a home
# an app still writes into. And it must refuse to run beside a MeetingTranscriber
# that is not the dev app, which would record the lane's synthetic meeting into
# the host's real folders. Each of those is checked in both directions here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

TMP="$(mktemp -d)"
PIDS=""
COMPLETED=0
# Set at the very end; see test_kill_and_verify_gone.sh for why a `set -u`
# abort would otherwise read as a pass.
cleanup() {
    local rc=$? pid
    for pid in $PIDS; do kill -KILL "$pid" 2>/dev/null || true; done
    rm -rf "$TMP"
    if [ "$COMPLETED" -ne 1 ]; then
        echo "FAIL: the test aborted before reaching its end" >&2
        exit 1
    fi
    exit "$rc"
}
trap cleanup EXIT
PASSED=0

ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }
expect() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then ok "$name"; else bad "$name" "expected '$expected', got '$actual'"; fi
}

# --- the defaults helpers, faked --------------------------------------------
#
# One file stands for the dev bundle's preferences: empty means unset.
# WRITES_FAIL makes every write a silent no-op, which is what the real helpers
# do when `defaults` fails, since they swallow its errors.
PREF="$TMP/protocolProvider"
WRITES_FAIL=0
read_dev_default_effective() { cat "$PREF" 2>/dev/null || true; }
write_dev_default() { [ "$WRITES_FAIL" = 1 ] || printf '%s' "$3" >"$PREF"; }
delete_dev_default() { [ "$WRITES_FAIL" = 1 ] || rm -f "$PREF"; }
REC="$TMP/state/mic-stall-protocolProvider"
mkdir -p "$TMP/state"
set_pref() { if [ -n "$1" ]; then printf '%s' "$1" >"$PREF"; else rm -f "$PREF"; fi; }
restore() { mic_stall_restore_protocol app.test "$TMP/none.plist" "$REC" none >/dev/null 2>&1; }

# --- mic_stall_restore_protocol ---------------------------------------------

set_pref none
rc=0; restore || rc=$?
expect no_record_changes_nothing "none/0" "$(read_dev_default_effective)/$rc"

set_pref none; printf 'claudeCLI' >"$REC"
rc=0; restore || rc=$?
expect record_restores_the_value "claudeCLI/0" "$(read_dev_default_effective)/$rc"
expect record_is_removed_after_a_restore "no" "$([ -f "$REC" ] && echo yes || echo no)"

# The lane found the key unset: the restore unsets it again.
set_pref none; : >"$REC"
rc=0; restore || rc=$?
expect empty_record_unsets_the_key "/0" "$(read_dev_default_effective)/$rc"

# A user who chose a provider since the killed run keeps it.
set_pref openAICompatible; printf 'claudeCLI' >"$REC"
rc=0; restore || rc=$?
expect newer_choice_is_kept "openAICompatible/0" "$(read_dev_default_effective)/$rc"
expect record_is_dropped_for_a_newer_choice "no" "$([ -f "$REC" ] && echo yes || echo no)"

# A write that did not land keeps the record, so a later run can still repair it.
set_pref none; printf 'claudeCLI' >"$REC"; WRITES_FAIL=1
rc=0; restore || rc=$?
WRITES_FAIL=0
expect failed_restore_reports "none/1" "$(read_dev_default_effective)/$rc"
expect failed_restore_keeps_the_record "claudeCLI" "$(cat "$REC" 2>/dev/null || echo missing)"
rm -f "$REC"

# --- mic_stall_release_home / mic_stall_sweep_kept_homes --------------------

LIST="$TMP/state/kept-homes"
# The lane makes its homes directly in this directory; here, the test's own.
export MIC_STALL_HOME_PARENT="$TMP"
# A pid that is certainly gone: a process that ran and was reaped.
sh -c 'exit 0' & DEAD=$!; wait "$DEAD" || true
# One that is certainly alive for the length of the test.
sleep 30 & LIVE=$!; PIDS="$PIDS $LIVE"

HOME_GONE="$TMP/e2e-mic-stall-home.gone"; mkdir -p "$HOME_GONE"
mic_stall_release_home "$HOME_GONE" "$DEAD" "$LIST" >/dev/null
expect home_of_an_exited_app_is_removed "no" "$([ -d "$HOME_GONE" ] && echo yes || echo no)"

HOME_KEPT="$TMP/e2e-mic-stall-home.kept"; mkdir -p "$HOME_KEPT"
mic_stall_release_home "$HOME_KEPT" "$LIVE" "$LIST" >/dev/null
expect home_of_a_running_app_is_kept "yes" "$([ -d "$HOME_KEPT" ] && echo yes || echo no)"
expect kept_home_is_listed "$LIVE $HOME_KEPT" "$(cat "$LIST")"

NOT_OURS="$TMP/some-other-dir"; mkdir -p "$NOT_OURS"
mic_stall_release_home "$NOT_OURS" "$DEAD" "$LIST" >/dev/null
expect a_path_not_shaped_like_a_lane_home_is_untouched "yes" "$([ -d "$NOT_OURS" ] && echo yes || echo no)"

# Only a home directly in the lane's directory, named as mktemp names it, is
# ever removed: not one that climbs out of it, not one somewhere else.
PRECIOUS="$TMP/precious"; mkdir -p "$PRECIOUS" "$TMP/e2e-mic-stall-home.abc"
mic_stall_release_home "$TMP/e2e-mic-stall-home.abc/../precious" "$DEAD" "$LIST" >/dev/null
expect a_path_that_climbs_out_is_untouched "yes" "$([ -d "$PRECIOUS" ] && echo yes || echo no)"
ELSEWHERE="$TMP/sub/e2e-mic-stall-home.xyz"; mkdir -p "$ELSEWHERE"
mic_stall_release_home "$ELSEWHERE" "$DEAD" "$LIST" >/dev/null
expect a_home_outside_the_lane_directory_is_untouched "yes" "$([ -d "$ELSEWHERE" ] && echo yes || echo no)"

# A later run: the home a failed run left goes once its own app is gone, and
# one whose app still runs stays listed.
HOME_LEFT="$TMP/e2e-mic-stall-home.left"; mkdir -p "$HOME_LEFT"
printf '%s %s\n' "$DEAD" "$HOME_LEFT" >>"$LIST"
printf '%s %s\n' "$DEAD" "$NOT_OURS" >>"$LIST"
printf '%s %s\n' "$DEAD" "$TMP/e2e-mic-stall-home.abc/../precious" >>"$LIST"
mic_stall_sweep_kept_homes "$LIST"
expect sweep_removes_the_home_of_an_exited_app "no" "$([ -d "$HOME_LEFT" ] && echo yes || echo no)"
expect sweep_keeps_the_home_of_a_running_app "yes" "$([ -d "$HOME_KEPT" ] && echo yes || echo no)"
expect sweep_never_touches_a_path_not_shaped_like_a_lane_home "yes" "$([ -d "$NOT_OURS" ] && echo yes || echo no)"
expect sweep_never_follows_a_path_that_climbs_out "yes" "$([ -d "$PRECIOUS" ] && echo yes || echo no)"
expect sweep_keeps_only_live_entries "$LIVE $HOME_KEPT" "$(cat "$LIST")"

kill -KILL "$LIVE" 2>/dev/null || true; wait "$LIVE" 2>/dev/null || true
mic_stall_sweep_kept_homes "$LIST"
expect sweep_removes_it_once_that_app_is_gone "no" "$([ -d "$HOME_KEPT" ] && echo yes || echo no)"
expect sweep_removes_the_empty_list "no" "$([ -f "$LIST" ] && echo yes || echo no)"

# --- non_dev_meetingtranscriber_pids ----------------------------------------
#
# Processes named exactly MeetingTranscriber: a symlink to sleep takes the
# link's name. One outside a dev bundle, one inside one. Started through a
# subshell that exits at once, so the shell reports no job when they are killed.
mkdir -p "$TMP/bin" "$TMP/MeetingTranscriber-Dev.app/Contents/MacOS"
ln -s /bin/sleep "$TMP/bin/MeetingTranscriber"
ln -s /bin/sleep "$TMP/MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber"
start() { ( "$1" 30 >/dev/null 2>&1 & echo $! ) ; }
DEV_PID="$(start "$TMP/MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber")"
PIDS="$PIDS $DEV_PID"
OTHER_PID="$(start "$TMP/bin/MeetingTranscriber")"
PIDS="$PIDS $OTHER_PID"
sleep 0.2
found="$(non_dev_meetingtranscriber_pids)"
case " $found " in *" $OTHER_PID "*) ok non_dev_app_is_reported ;; *) bad non_dev_app_is_reported "got '$found'" ;; esac
case " $found " in *" $DEV_PID "*) bad dev_app_is_not_reported "got '$found'" ;; *) ok dev_app_is_not_reported ;; esac
kill -KILL "$OTHER_PID" 2>/dev/null || true
sleep 0.1
found="$(non_dev_meetingtranscriber_pids)"
case " $found " in *" $OTHER_PID "*) bad nothing_reported_once_it_is_gone "got '$found'" ;; *) ok nothing_reported_once_it_is_gone ;; esac

# --- the wiring in e2e-app.sh -----------------------------------------------
#
# The helpers above are only as good as the calls to them. Read from the script
# itself: every lane repairs and sweeps after it quit the running app and
# before it launches its own, the mic-stall lane arms its cleanup as soon as it
# has made its home, and the exit handler runs it.
APP_SH="$ROOT/scripts/e2e-app.sh"
line_of() { { grep -n -E "$1" "$APP_SH" || true; } | head -1 | cut -d: -f1; }
QUIT="$(line_of '^quit_running_app$')"
RESTORE="$(line_of '^mic_stall_restore_protocol ')"
SWEEP="$(line_of '^mic_stall_sweep_kept_homes ')"
LAUNCH="$(line_of '^log "Launching ')"
in_order() { [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ]; }
expect every_lane_repairs_the_protocol_before_it_launches "yes" "$(in_order "$QUIT" "$RESTORE" "$LAUNCH" && echo yes || echo no)"
expect every_lane_sweeps_kept_homes_before_it_launches "yes" "$(in_order "$QUIT" "$SWEEP" "$LAUNCH" && echo yes || echo no)"
HOME_MADE="$(line_of 'APP_HOME="\$\(mktemp -d .*e2e-mic-stall-home')"
ARMED="$(line_of "^    trap '_ms_cleanup' EXIT$")"
expect the_cleanup_is_armed_right_after_the_home_is_made "yes" "$([ -n "$HOME_MADE" ] && [ -n "$ARMED" ] && [ "$ARMED" -eq $(( HOME_MADE + 1 )) ] && echo yes || echo no)"
# A call, not a mention: comments inside on_exit name the function too.
ON_EXIT_CALLS="$(awk '/^on_exit\(\) \{/,/^\}/' "$APP_SH" | { grep -E '^[[:space:]]*[^#[:space:]].*_ms_cleanup' || true; })"
expect the_exit_handler_runs_the_cleanup "yes" "$([ -n "$ON_EXIT_CALLS" ] && echo yes || echo no)"

COMPLETED=1
echo "all $PASSED passed"
