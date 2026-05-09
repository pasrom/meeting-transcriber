#!/usr/bin/env bash
# Pattern-C E2E driver for the Meeting Transcriber dev app.
#
# Builds the dev .app, deploys it to a stable path so its TCC permissions
# persist across runs, launches it, triggers a synthetic meeting via the
# meeting-simulator tool, polls the DebugRPCServer for the resulting
# pipeline job, and asserts on the transcript output.
#
# This is the production-app E2E path, intentionally separate from the
# fixture-based component E2E tests in `app/MeetingTranscriber/Tests/*E2E*.swift`
# (which run on PR-CI). Rationale and history: see CLAUDE.md > E2E architecture.
#
# Prerequisites on the runner host (one-time setup):
#   - Xcode at /Applications/Xcode.app (xcode-select pointed there)
#   - GUI session for the runner user (CATapDescription needs a logged-in
#     loginwindow context — service-mode runners get silent audio capture)
#   - A virtual input device (BlackHole 2ch) so AVAudioEngine has something
#     to bind to on Mac mini hosts without a built-in mic
#   - System Settings → Privacy: Microphone + Screen & System Audio Recording
#     granted to ~/Applications/MeetingTranscriber-Dev.app
#   See scripts/setup-self-hosted-runner.sh for the bootstrap flow.

set -euo pipefail

# --- args -----------------------------------------------------------------

KEEP_APP=false           # leave the app running after assertions
QUIT_APP=false           # quit the app on exit (overrides KEEP_APP)
SIMULATOR_FIXTURE=""     # custom audio fixture for the simulator
NO_BUILD=false           # skip build/deploy/re-sign — use whatever's at ~/Applications already

while [ $# -gt 0 ]; do
    case "$1" in
        --keep-app)   KEEP_APP=true ;;
        --quit-app)   QUIT_APP=true ;;
        --no-build)   NO_BUILD=true ;;
        --fixture)    shift; SIMULATOR_FIXTURE="$1" ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# //;s/^#//'
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
RPC_TOKEN_FILE="$HOME/Library/Application Support/MeetingTranscriber/.rpc-token"
RPC_BASE="http://127.0.0.1:9876"

[ -n "$SIMULATOR_FIXTURE" ] || SIMULATOR_FIXTURE="$DEFAULT_FIXTURE"

# --- timing budgets -------------------------------------------------------

# Cold first run downloads ~50 MB Parakeet model — give it room. Hot run
# under 10 s easily.
RPC_READY_TIMEOUT_S=30
PIPELINE_TIMEOUT_S=240

# --- helpers --------------------------------------------------------------

log()  { printf '[e2e-app] %s\n' "$*"; }
fail() { printf '[e2e-app] FAIL: %s\n' "$*" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null || fail "missing command: $1"
}

# Read the RPC bearer token written by the running app at start-up.
read_token() {
    [ -f "$RPC_TOKEN_FILE" ] || fail "RPC token file not found: $RPC_TOKEN_FILE (is the app running with debugRPC enabled?)"
    cat "$RPC_TOKEN_FILE"
}

# Curl the RPC with bearer auth. Returns empty string + exit 0 on
# transient failure (timeout, connection refused) so callers in `set -e`
# poll loops can keep trying. The 15 s timeout is generous because the
# app's main thread can briefly block during model load + audio teardown.
rpc() {
    local path="$1"
    local token; token="$(read_token)"
    local response
    if response=$(curl --silent --show-error --max-time 15 \
            --header "Authorization: Bearer $token" \
            "$RPC_BASE$path" 2>/dev/null); then
        printf '%s' "$response"
    else
        printf ''
    fi
}

# --- preflight ------------------------------------------------------------

require_command curl
require_command jq
require_command swift
require_command codesign

[ -f "$SIMULATOR_FIXTURE" ] || fail "simulator fixture not found: $SIMULATOR_FIXTURE"

# Sanity check: a virtual input device is set as default. If the runner
# host has no built-in mic and no BlackHole/Loopback, AVAudioEngine binds
# to a no-input device and the dual-source recorder hits a libmalloc abort
# (observed on Mac mini hosts). Surface the misconfiguration up-front.
if ! system_profiler SPAudioDataType 2>/dev/null | grep -A4 "Default Input" | grep -q "Input Channels"; then
    fail "no default audio input device — install BlackHole 2ch (brew install blackhole-2ch + reboot/coreaudiod restart) and set it as the default Input in System Settings → Sound"
fi

if [ "$NO_BUILD" = true ]; then
    [ -d "$DEV_BUNDLE_DEPLOY" ] || fail "--no-build given but $DEV_BUNDLE_DEPLOY doesn't exist — deploy a signed bundle there first"
    log "Skipping build/deploy/re-sign — using existing $DEV_BUNDLE_DEPLOY"
else
    # --- 1. build dev bundle ----------------------------------------------

    log "Building dev .app bundle"
    "$SCRIPT_DIR/run_app.sh" --build-only

    # --- 3. deploy to stable path (preserve bundle dir → preserve TCC) ----

    log "Deploying to $DEV_BUNDLE_DEPLOY"
    mkdir -p "$(dirname "$DEV_BUNDLE_DEPLOY")"
    if [ -d "$DEV_BUNDLE_DEPLOY" ]; then
        # cp -R into the existing bundle (NOT delete + copy) — TCC keys off
        # the bundle path; a fresh dir would invalidate granted permissions.
        rsync -a --delete "$DEV_BUNDLE_BUILD/" "$DEV_BUNDLE_DEPLOY/"
    else
        cp -R "$DEV_BUNDLE_BUILD" "$DEV_BUNDLE_DEPLOY"
    fi

    # Re-sign so TCC sees the same designated requirement across rebuilds.
    # rsync above brought in whatever run_app.sh signed with (typically
    # ad-hoc — run_app.sh's `find-identity -v` doesn't pick up our
    # identities), which would invalidate the TCC grant tied to the cert
    # SHA.
    #
    # Two paths:
    #   - CI / Apple Developer ID — `DEVELOPER_ID` env var set (provided
    #     by e2e-app.yml after importing the cert from secrets). Apple
    #     roots are system-trusted; this just works.
    #   - Local dev — `DEVELOPER_ID` empty; fall back to the self-signed
    #     cert installed by setup-self-hosted-runner.sh.
    if [ -n "${DEVELOPER_ID:-}" ]; then
        log "Re-signing $DEV_BUNDLE_DEPLOY with Developer ID '$DEVELOPER_ID'"
        SIGN_ARGS=(--force --sign "$DEVELOPER_ID")
        [ -n "${E2E_SIGNING_KEYCHAIN:-}" ] && SIGN_ARGS+=(--keychain "$E2E_SIGNING_KEYCHAIN")
        codesign "${SIGN_ARGS[@]}" "$DEV_BUNDLE_DEPLOY" >/dev/null \
            || fail "codesign with Developer ID failed — check DEVELOPER_ID + E2E_SIGNING_KEYCHAIN env vars"
    else
        DEV_KEYCHAIN="$HOME/Library/Keychains/meetingtranscriber-dev.keychain-db"
        DEV_CERT_PATH="/tmp/meetingtranscriber-setup/dev-cert.crt"
        if [ ! -f "$DEV_KEYCHAIN" ] || [ ! -f "$DEV_CERT_PATH" ]; then
            fail "no Developer ID and dev keychain missing ($DEV_KEYCHAIN / $DEV_CERT_PATH) — set DEVELOPER_ID env or run scripts/setup-self-hosted-runner.sh first"
        fi
        DEV_CERT_HASH="$(openssl x509 -in "$DEV_CERT_PATH" -noout -fingerprint -sha1 \
            | sed 's/^.*=//' | tr -d ':')"
        log "Re-signing $DEV_BUNDLE_DEPLOY with self-signed dev cert ($DEV_CERT_HASH)"
        security unlock-keychain -p "" "$DEV_KEYCHAIN" || true
        codesign --force --sign "$DEV_CERT_HASH" \
            --keychain "$DEV_KEYCHAIN" \
            "$DEV_BUNDLE_DEPLOY" >/dev/null \
            || fail "codesign with dev cert failed — try re-running scripts/setup-self-hosted-runner.sh"
    fi
fi

# --- 2. build meeting-simulator (cached after first run) ------------------

if [ ! -x "$SIMULATOR_BIN" ]; then
    log "Building meeting-simulator"
    (cd "$SIMULATOR_PKG" && swift build -c release)
fi

# --- 4. ensure debug RPC + auto-watch will be on -------------------------

# Persistent toggles survive across launches. Set them before launching so
# the server comes up immediately and the WatchLoop auto-starts 3 s after
# init (without an explicit click on "Start Watching" in the menu, which
# isn't reachable over SSH). The autoWatch path is already wired in
# MeetingTranscriberApp via the `.autoWatchStart` notification; we just
# flip the persistent flag it checks.
defaults write com.meetingtranscriber.dev debugRPCEnabled -bool true
defaults write com.meetingtranscriber.dev autoWatch -bool true

# --- 5. launch app --------------------------------------------------------

# If a previous instance is still around, leave it — `open` brings the
# existing PID to the front rather than re-launching with the new bundle.
# That's fine: the deploy step above overwrote the bundle in-place.
log "Launching $DEV_BUNDLE_DEPLOY"
open "$DEV_BUNDLE_DEPLOY"

# --- 6. wait for RPC ------------------------------------------------------

log "Waiting up to ${RPC_READY_TIMEOUT_S}s for RPC /healthz"
deadline=$(( $(date +%s) + RPC_READY_TIMEOUT_S ))
until [ -f "$RPC_TOKEN_FILE" ] && rpc /healthz >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "RPC /healthz did not respond within ${RPC_READY_TIMEOUT_S}s"
    sleep 1
done
log "RPC up"

# --- 7. snapshot pre-trigger state ---------------------------------------

PRE_LAST_JOB_ID="$(rpc /state | jq -r '.lastJob.jobID // empty')"
log "Pre-trigger lastJob.jobID: ${PRE_LAST_JOB_ID:-<none>}"

# --- 8. trigger meeting-simulator ----------------------------------------

log "Starting meeting-simulator → $SIMULATOR_FIXTURE"
"$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-app-sim.log 2>&1 &
SIM_PID=$!
trap '[ -n "${SIM_PID:-}" ] && kill "$SIM_PID" 2>/dev/null || true' EXIT

# --- 9. poll for new lastJob ---------------------------------------------

log "Polling /state every 5s for new lastJob (timeout ${PIPELINE_TIMEOUT_S}s)"
deadline=$(( $(date +%s) + PIPELINE_TIMEOUT_S ))
last_state=""
new_job_id=""
while true; do
    snap="$(rpc /state)"
    lj_id="$(jq -r '.lastJob.jobID // empty' <<<"$snap")"
    lj_state="$(jq -r '.lastJob.state // empty' <<<"$snap")"
    pipe_active="$(jq -r '.pipeline.activeJobCount' <<<"$snap")"
    pipe_processing="$(jq -r '.pipeline.isProcessing' <<<"$snap")"

    if [ "$lj_state" != "$last_state" ] || [ "$lj_id" != "$new_job_id" ]; then
        log "  pipeline.active=$pipe_active processing=$pipe_processing lastJob=$lj_id state=$lj_state"
        last_state="$lj_state"
        new_job_id="$lj_id"
    fi

    # Done when a NEW lastJob has terminal state.
    if [ -n "$lj_id" ] && [ "$lj_id" != "$PRE_LAST_JOB_ID" ] \
        && { [ "$lj_state" = "done" ] || [ "$lj_state" = "error" ]; }; then
        break
    fi

    [ "$(date +%s)" -lt "$deadline" ] || fail "no new pipeline job reached terminal state within ${PIPELINE_TIMEOUT_S}s (active=$pipe_active processing=$pipe_processing)"
    sleep 5
done

# --- 10. assertions ------------------------------------------------------

log "Final state: $lj_state"
final_snapshot="$(rpc /state)"
echo "$final_snapshot" | jq '.lastJob'

[ "$lj_state" = "done" ] || fail "lastJob.state == \"$lj_state\", expected \"done\". Error: $(jq -r '.lastJob.error // "<none>"' <<<"$final_snapshot")"

transcript_path="$(jq -r '.lastJob.transcriptPath // empty' <<<"$final_snapshot")"
[ -n "$transcript_path" ] || fail "lastJob.transcriptPath is empty"
[ -f "$transcript_path" ] || fail "transcript file does not exist: $transcript_path"

transcript_size="$(wc -c <"$transcript_path" | tr -d ' ')"
[ "$transcript_size" -gt 100 ] || fail "transcript suspiciously short: $transcript_size bytes (expected > 100)"

log "Transcript: $transcript_path ($transcript_size bytes)"
log "Preview:"
head -c 500 "$transcript_path" | sed 's/^/    /'
echo

# --- 11. cleanup ---------------------------------------------------------

[ -n "${SIM_PID:-}" ] && kill "$SIM_PID" 2>/dev/null || true
trap - EXIT

if [ "$QUIT_APP" = true ]; then
    log "Quitting app"
    osascript -e 'tell application "MeetingTranscriber-Dev" to quit' 2>/dev/null || true
elif [ "$KEEP_APP" = false ]; then
    log "App still running (use --quit-app to quit)"
fi

log "PASS"
