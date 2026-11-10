#!/bin/bash
# Regression test for launch_dev_app, the launch helper the live-captions and
# cpu-load lanes use to hand the app their settings as launch arguments
# instead of writing them into the host's preferences.
#
# What it must get right: the exact `open` invocation (an argument that does
# not arrive leaves the app on its stored setting, and nothing else would say
# so), the refusal of a key it cannot read back, and a loud failure when the
# app reports a setting other than the one passed. `open` and the two RPC reads
# are stubbed, so nothing here launches anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

TMP="$(mktemp -d)"
# Set at the very end; see test_kill_and_verify_gone.sh for why a `set -u`
# abort would otherwise read as a pass.
COMPLETED=0
cleanup() {
    local rc=$?
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

# `open` records its arguments, one per line; the app is never started.
open() { printf '%s\n' "$@" >"$TMP/open.args"; }
READY=0
rpc_ready() { return "$READY"; }
# What the app would report for its effective settings.
SETTINGS='{"detection": {"autoWatch": true}, "recording": {"recordOnly": false, "liveTranscriptionEnabled": true},
           "transcription": {"engine": "parakeet"}}'
# shellcheck disable=SC2034 # read by launch_dev_app's readback
state_read() { STATE_BODY="{\"settings\": $SETTINGS}"; return 0; }
# shellcheck disable=SC2034 # read by launch_dev_app
RPC_READY_TIMEOUT_S=1

# shellcheck disable=SC2034 # read by launch_dev_app's readback
E2E_LAUNCH_READBACK_S=1

# launch_status <args...> — the helper's status into LAUNCH_STATUS, with the
# open log reset first; in this shell, so E2E_LAUNCH_ERR is visible here.
launch_status() { local st=0; rm -f "$TMP/open.args"; launch_dev_app "$@" >/dev/null 2>&1 || st=$?; LAUNCH_STATUS="$st"; }

launch_status /x/App.app --env MEETINGTRANSCRIBER_DEBUG_RPC=1 -- \
    liveTranscriptionEnabled=true transcriptionEngine=parakeet autoWatch=true
st="$LAUNCH_STATUS"
expected="$(printf '%s\n' --env MEETINGTRANSCRIBER_DEBUG_RPC=1 /x/App.app --args \
    -liveTranscriptionEnabled YES -transcriptionEngine parakeet -autoWatch YES)"
[ "$st" = 0 ] && [ "$(cat "$TMP/open.args")" = "$expected" ] \
    && ok passes_settings_as_launch_arguments || bad passes_settings_as_launch_arguments "status $st, open got: $(tr '\n' ' ' <"$TMP/open.args" 2>/dev/null)"

launch_status /x/App.app -- recordOnly=false
st="$LAUNCH_STATUS"
[ "$st" = 0 ] && grep -qx -- '-recordOnly' "$TMP/open.args" && grep -qx NO "$TMP/open.args" \
    && ! grep -qx -- '--env' "$TMP/open.args" \
    && ok false_is_NO_and_no_env_is_fine || bad false_is_NO_and_no_env_is_fine "status $st"

# The app resolved something else than what was passed: the argument did not
# arrive, and the lane must not run on the stored value.
launch_status /x/App.app -- liveTranscriptionEnabled=false
[ "$LAUNCH_STATUS" = 1 ] && [[ "$E2E_LAUNCH_ERR" == *liveTranscriptionEnabled*false*true* ]] \
    && ok a_setting_that_did_not_arrive_fails || bad a_setting_that_did_not_arrive_fails "status $LAUNCH_STATUS: ${E2E_LAUNCH_ERR:-}"

launch_status /x/App.app -- transcriptionEngine=whisperKit
[ "$LAUNCH_STATUS" = 1 ] && [[ "$E2E_LAUNCH_ERR" == *transcriptionEngine*whisperKit*parakeet* ]] \
    && ok a_string_setting_that_did_not_arrive_fails || bad a_string_setting_that_did_not_arrive_fails "status $LAUNCH_STATUS: ${E2E_LAUNCH_ERR:-}"

# A key the helper cannot read back, or a value it cannot pass, is refused
# before anything is launched.
launch_status /x/App.app -- numSpeakers=2
[ "$LAUNCH_STATUS" = 2 ] && [ ! -e "$TMP/open.args" ] && [[ "$E2E_LAUNCH_ERR" == *numSpeakers* ]] \
    && ok unknown_key_is_refused_before_launch || bad unknown_key_is_refused_before_launch "status $LAUNCH_STATUS: ${E2E_LAUNCH_ERR:-}"
launch_status /x/App.app -- autoWatch=yes
[ "$LAUNCH_STATUS" = 2 ] && [ ! -e "$TMP/open.args" ] \
    && ok non_boolean_value_is_refused || bad non_boolean_value_is_refused "status $LAUNCH_STATUS"
launch_status /x/App.app --bogus -- autoWatch=true
[ "$LAUNCH_STATUS" = 2 ] && [ ! -e "$TMP/open.args" ] \
    && ok unknown_option_is_refused || bad unknown_option_is_refused "status $LAUNCH_STATUS"

# `open` itself failed (no such bundle, LaunchServices refused).
open() { return 1; }
launch_status /x/App.app -- autoWatch=true
[ "$LAUNCH_STATUS" = 1 ] && [[ "$E2E_LAUNCH_ERR" == *open* ]] \
    && ok open_failure_is_reported || bad open_failure_is_reported "status $LAUNCH_STATUS: ${E2E_LAUNCH_ERR:-}"
open() { printf '%s\n' "$@" >"$TMP/open.args"; }

# The RPC server never came up.
READY=1
launch_status /x/App.app -- autoWatch=true
[ "$LAUNCH_STATUS" = 1 ] && [[ "$E2E_LAUNCH_ERR" == *healthz* ]] \
    && ok rpc_not_up_fails || bad rpc_not_up_fails "status $LAUNCH_STATUS: ${E2E_LAUNCH_ERR:-}"
READY=0

# An answer without the settings projection (another app on the port, or an
# older build): no readback is possible, which fails rather than passes.
# shellcheck disable=SC2034 # read by launch_dev_app's readback
state_read() { STATE_BODY='{"pipeline": {}}'; return 0; }
launch_status /x/App.app -- autoWatch=true
[ "$LAUNCH_STATUS" = 1 ] && [[ "$E2E_LAUNCH_ERR" == *settings* ]] \
    && ok no_settings_in_state_fails || bad no_settings_in_state_fails "status $LAUNCH_STATUS: ${E2E_LAUNCH_ERR:-}"

COMPLETED=1
echo "All $PASSED tests passed."
