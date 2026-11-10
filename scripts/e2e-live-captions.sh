#!/usr/bin/env bash
# Live-recording E2E driver for the live-transcription overlay.
#
# Complements scripts/e2e-app.sh (which asserts on the post-pipeline
# transcript) by asserting on the IN-FLIGHT overlay state — i.e. the
# `liveCaptions.recentFinals` array exposed by the debug RPC server's
# `/state` endpoint. Exercises the full production chain:
#   AudioCaptureSession → DualSourceRecorder → app/mic live sinks →
#   LiveTranscriptionController → StreamingTranscriber → engine →
#   LiveCaptionsState → RPC snapshot.
#
# Runs on the same self-hosted Mac runner as e2e-app.sh and reuses the
# same one-time TCC setup (scripts/setup-self-hosted-runner.sh).
#
# The fixture-based xctest E2E (app/MeetingTranscriber/Tests/
# LiveTranscriptionE2ETests.swift) covers everything from
# LiveTranscriptionController inward; this script covers the parts
# that are outside the xctest harness — CATap tap, AudioCaptureSession,
# DualSourceRecorder, recorder→sink wiring.

set -euo pipefail

# --- args -----------------------------------------------------------------

APP_AFTER=quit           # quit | leave
NO_BUILD=false
SIMULATOR_FIXTURE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --quit-app)         APP_AFTER=quit ;;
        --keep-app)         APP_AFTER=leave ;;
        --no-build)         NO_BUILD=true ;;
        --fixture)          shift; SIMULATOR_FIXTURE="$1" ;;
        -h|--help)
            cat <<'HELP'
Usage: e2e-live-captions.sh [--no-build] [--keep-app] [--fixture path/to.wav]

  --no-build           Skip build/deploy/re-sign; use ~/Applications/MeetingTranscriber-Dev.app as-is.
  --keep-app           Leave the dev app running on exit. Default: quit it.
  --fixture            Audio fixture for meeting-simulator. Default: two_speakers_de.wav.
HELP
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# --- paths ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEV_BUNDLE_BUILD="$ROOT/app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app"
DEV_BUNDLE_DEPLOY="$HOME/Applications/MeetingTranscriber-Dev.app"
SIMULATOR_PKG="$ROOT/tools/meeting-simulator"
SIMULATOR_BIN="$SIMULATOR_PKG/.build/release/meeting-simulator"
DEFAULT_FIXTURE="$ROOT/app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav"
# shellcheck disable=SC2034 # read by the RPC helpers in lib/e2e-helpers.sh
RPC_TOKEN_FILE="$HOME/Library/Application Support/MeetingTranscriber/.rpc-token"
# shellcheck disable=SC2034 # read by the RPC helpers in lib/e2e-helpers.sh
RPC_BASE="http://127.0.0.1:9876"
REC_DIR="$HOME/Library/Application Support/MeetingTranscriber/recordings"

[ -n "$SIMULATOR_FIXTURE" ] || SIMULATOR_FIXTURE="$DEFAULT_FIXTURE"

# --- timing budgets -------------------------------------------------------

# RPC up: same budget as e2e-app.sh (Parakeet model is now pre-warmed at
# launch via the liveTranscriptionEnabled toggle, so first speech can fire
# as soon as the simulator starts playing).
RPC_READY_TIMEOUT_S=30
# Time from simulator start to first finalised caption. Parakeet typically
# emits a finalised utterance ~3-6 s after the first speech segment ends;
# 90 s is generous so a model load on a cold runner doesn't blow the budget.
CAPTION_DEADLINE_S=90

# --- helpers --------------------------------------------------------------

log()  { printf '[e2e-live-captions] %s\n' "$*"; }
fail() { printf '[e2e-live-captions] FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=scripts/lib/e2e-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/e2e-helpers.sh"
# Ends what a timed-out earlier step left running, then records this
# driver for the next (see e2e_register_driver).
e2e_register_driver

require_command() {
    command -v "$1" >/dev/null || fail "missing command: $1"
}

# shellcheck disable=SC2034 # read by the RPC helpers in lib/e2e-helpers.sh
RPC_TOKEN=""

# --- preflight ------------------------------------------------------------

require_command curl
require_command jq
require_command swift
require_command codesign

[ -f "$SIMULATOR_FIXTURE" ] || fail "simulator fixture not found: $SIMULATOR_FIXTURE"
if ! system_profiler SPAudioDataType 2>/dev/null | grep -A4 "Default Input" | grep -q "Input Channels"; then
    fail "no default audio input device — install BlackHole 2ch and set it as the default Input"
fi

# Cleanup trap, armed before anything below changes the host: a build or
# launch failure must still kill the simulator and quit the app.
SIM_PID=""
# Every recording artifact this run creates is newer than this marker; created
# before the app launches, so before anything can record.
RUN_START_MARKER=""
on_exit() {
    [ -n "${SIM_PID:-}" ] && kill "$SIM_PID" 2>/dev/null || true
    if [ "$APP_AFTER" = quit ]; then
        # A no-op after the quit at the end of a passing run. `|| true`: under
        # set -e a wedged app (quit ladder exhausted) must not abort the trap
        # before the sweep and the restore below run.
        quit_running_app || true
        # The quit stops the recording mid-meeting and leaves its audio in the
        # staging dir, where the next lane's launch would recover it as a job
        # (the rationale + the CI guard live in sweep_run_artifacts).
        sweep_run_artifacts "$REC_DIR" "${RUN_START_MARKER:-}"
    fi
    rm -f "${RUN_START_MARKER:-}" 2>/dev/null || true
}
# INT/TERM exit (and so run on_exit once, from EXIT): a trap that only ran
# on_exit would return into the interrupted command and let the lane carry on
# after its cleanup, which a reaper SIGTERM relies on not happening.
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The app must not be running when it is launched below: `open` would only
# activate it and drop the launch arguments.
quit_running_app

# --- build + deploy + sign ------------------------------------------------

if [ "$NO_BUILD" = true ]; then
    [ -d "$DEV_BUNDLE_DEPLOY" ] || fail "--no-build given but $DEV_BUNDLE_DEPLOY doesn't exist"
    log "Skipping build/deploy/re-sign — using existing $DEV_BUNDLE_DEPLOY"
else
    # Establish the signing identity before the build. The deploy below replaces
    # the shared bundle whose TCC grants are keyed on the certificate, and every
    # `--no-build` sibling lane reuses it, so a lane that only discovers it
    # cannot sign afterwards has already stranded an unsigned one there.
    require_signing_identity || exit 1

    log "Building dev .app bundle"
    "$SCRIPT_DIR/run_app.sh" --build-only

    log "Deploying to $DEV_BUNDLE_DEPLOY"
    mkdir -p "$(dirname "$DEV_BUNDLE_DEPLOY")"
    if [ -d "$DEV_BUNDLE_DEPLOY" ]; then
        rsync -a --delete "$DEV_BUNDLE_BUILD/" "$DEV_BUNDLE_DEPLOY/"
    else
        cp -R "$DEV_BUNDLE_BUILD" "$DEV_BUNDLE_DEPLOY"
    fi

    log "Re-signing $DEV_BUNDLE_DEPLOY with $SIGN_IDENTITY"
    # Re-assert the signing keychain right before codesign — a parallel job on
    # the Mini's other runner (shared OS user) may have mutated the user search
    # list during our 60-90 s build. codesign honours `--keychain` for the
    # signing identity but still consults the search list for trust-chain
    # resolution.
    [ -z "$SIGN_KEYCHAIN" ] || "$SCRIPT_DIR/keychain-prepend.sh" "$SIGN_KEYCHAIN" || true
    resign_deployed_bundle "$DEV_BUNDLE_DEPLOY" "$SIGN_IDENTITY" "$SIGN_KEYCHAIN" \
        || fail "re-sign of the deployed bundle failed — see the message above"
fi

if [ ! -x "$SIMULATOR_BIN" ]; then
    log "Building meeting-simulator"
    (cd "$SIMULATOR_PKG" && swift build -c release)
fi

# --- launch + wait for RPC ------------------------------------------------

fg_user=$(stat -f "%Su" /dev/console)
my_user=$(id -un)
if [ "$fg_user" != "$my_user" ]; then
    fail "Aqua foreground user is '$fg_user', not '$my_user' — Fast User Switching is active."
fi

RUN_START_MARKER="$(mktemp "${TMPDIR:-/tmp}/e2e-live-captions-start.XXXXXX")"
# Live transcription on with the Parakeet engine, and watching, as launch
# arguments: the settings the production toggle writes, so the chain under
# test is the real one, but in the argument domain for this process only, so
# the lane leaves the host's preferences as it found them (see
# launch_dev_app). Crucially no debug env var that bypasses the real chain:
# the one env var brings up the RPC server the lane reads, nothing else.
log "Launching $DEV_BUNDLE_DEPLOY (waiting up to ${RPC_READY_TIMEOUT_S}s for RPC /healthz)"
launch_dev_app "$DEV_BUNDLE_DEPLOY" --env MEETINGTRANSCRIBER_DEBUG_RPC=1 -- \
    liveTranscriptionEnabled=true transcriptionEngine=parakeet autoWatch=true \
    || fail "$E2E_LAUNCH_ERR"
log "RPC up; the app reports the launch settings (live transcription on, Parakeet, auto-watch)"

# --- trigger meeting + poll captions --------------------------------------

log "Starting meeting-simulator → $SIMULATOR_FIXTURE"
"$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-live-captions-sim.log 2>&1 &
SIM_PID=$!

log "Polling /state for liveCaptions.recentFinals (timeout ${CAPTION_DEADLINE_S}s)"
# poll_state keeps an app that stopped answering apart from one that answers
# with no captions; before, both read as zero finals.
finals_count=0
finals_json="[]"
last_log_count=-1
_finals_arrived() {
    IFS='|' read -r finals_count finals_json < <(
        jq -r '[(.liveCaptions.recentFinals | length), (.liveCaptions.recentFinals | tojson)] | join("|")' <<<"$STATE_BODY"
    ) || true
    finals_count="${finals_count:-0}"
    if [ "$finals_count" != "$last_log_count" ]; then
        log "  recentFinals.count = $finals_count"
        last_log_count="$finals_count"
    fi
    [ "$finals_count" -gt 0 ]
}
poll_state --each assert_app_alive "$CAPTION_DEADLINE_S" 5 _finals_arrived \
    || fail "$(state_why $? "no liveCaptions.recentFinals appeared within ${CAPTION_DEADLINE_S}s — wiring broken or model didn't produce text")"

log "Got $finals_count finalised caption(s):"
echo "$finals_json" | jq . | sed 's/^/    /'

# Content assertions: at least one final must carry non-empty text and a
# valid channel tag. We don't assert on specific transcript content because
# Parakeet may render the fixture differently across versions, but an
# empty-text final or a missing channel field indicates real wiring damage.
# Single jq invocation emits both booleans tab-separated — same pattern
# PR #304 used to collapse adjacent jq passes.
IFS=$'\t' read -r has_nonempty bad_channel < <(
    jq -r '[any(.[]; (.text | length) > 0),
            any(.[]; (.channel != "mic" and .channel != "app"))]
           | @tsv' <<<"$finals_json"
)
[ "$has_nonempty" = "true" ] || fail "all recentFinals have empty text — engine produced no recognisable output"
[ "$bad_channel" = "false" ] || fail "recentFinals contain a final with invalid channel (not 'mic'/'app'): $finals_json"

log "PASS — live transcription chain produced finalised captions through the production seam"

# The simulator before the quit, so the app is not quit in the middle of a
# meeting; the trap then sweeps what the recording left.
kill "$SIM_PID" 2>/dev/null || true
SIM_PID=""
if [ "$APP_AFTER" = quit ]; then
    quit_running_app
fi
