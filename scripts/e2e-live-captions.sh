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
RPC_TOKEN_FILE="$HOME/Library/Application Support/MeetingTranscriber/.rpc-token"
RPC_BASE="http://127.0.0.1:9876"
BUNDLE_ID="com.meetingtranscriber.dev"

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

require_command() {
    command -v "$1" >/dev/null || fail "missing command: $1"
}

RPC_TOKEN=""
rpc() {
    local path="$1"
    curl --silent --show-error --max-time 10 \
        --header "Authorization: Bearer $RPC_TOKEN" \
        "$RPC_BASE$path" 2>/dev/null || true
}

# --- preflight ------------------------------------------------------------

require_command curl
require_command jq
require_command swift
require_command codesign

[ -f "$SIMULATOR_FIXTURE" ] || fail "simulator fixture not found: $SIMULATOR_FIXTURE"
if ! system_profiler SPAudioDataType 2>/dev/null | grep -A4 "Default Input" | grep -q "Input Channels"; then
    fail "no default audio input device — install BlackHole 2ch and set it as the default Input"
fi

# Snapshot toggles we'll mutate so cleanup can restore them. Captures the
# state from a previous run on the same host (which might have left
# anything behind).
SAVED_LIVE_TRANS=$(snapshot_default "$BUNDLE_ID" liveTranscriptionEnabled)
SAVED_TRANS_ENGINE=$(snapshot_default "$BUNDLE_ID" transcriptionEngine)
SAVED_DEBUG_RPC=$(snapshot_default "$BUNDLE_ID" debugRPCEnabled)
SAVED_AUTO_WATCH=$(snapshot_default "$BUNDLE_ID" autoWatch)

quit_running_app

# --- build + deploy + sign ------------------------------------------------

if [ "$NO_BUILD" = true ]; then
    [ -d "$DEV_BUNDLE_DEPLOY" ] || fail "--no-build given but $DEV_BUNDLE_DEPLOY doesn't exist"
    log "Skipping build/deploy/re-sign — using existing $DEV_BUNDLE_DEPLOY"
else
    log "Building dev .app bundle"
    "$SCRIPT_DIR/run_app.sh" --build-only

    log "Deploying to $DEV_BUNDLE_DEPLOY"
    mkdir -p "$(dirname "$DEV_BUNDLE_DEPLOY")"
    if [ -d "$DEV_BUNDLE_DEPLOY" ]; then
        rsync -a --delete "$DEV_BUNDLE_BUILD/" "$DEV_BUNDLE_DEPLOY/"
    else
        cp -R "$DEV_BUNDLE_BUILD" "$DEV_BUNDLE_DEPLOY"
    fi

    if [ -n "${DEVELOPER_ID:-}" ]; then
        log "Re-signing with Developer ID '$DEVELOPER_ID'"
        if [ -n "${E2E_SIGNING_KEYCHAIN:-}" ]; then
            "$SCRIPT_DIR/keychain-prepend.sh" "$E2E_SIGNING_KEYCHAIN"
        fi
        SIGN_ARGS=(--force --sign "$DEVELOPER_ID")
        [ -n "${E2E_SIGNING_KEYCHAIN:-}" ] && SIGN_ARGS+=(--keychain "$E2E_SIGNING_KEYCHAIN")
        codesign "${SIGN_ARGS[@]}" "$DEV_BUNDLE_DEPLOY" >/dev/null \
            || fail "codesign with Developer ID failed"
    else
        DEV_KEYCHAIN="$HOME/Library/Keychains/meetingtranscriber-dev.keychain-db"
        DEV_CERT_PATH="/tmp/meetingtranscriber-setup/dev-cert.crt"
        [ -f "$DEV_KEYCHAIN" ] && [ -f "$DEV_CERT_PATH" ] \
            || fail "no Developer ID and dev keychain missing — run scripts/setup-self-hosted-runner.sh first"
        DEV_CERT_HASH="$(openssl x509 -in "$DEV_CERT_PATH" -noout -fingerprint -sha1 \
            | sed 's/^.*=//' | tr -d ':')"
        log "Re-signing with self-signed dev cert ($DEV_CERT_HASH)"
        security unlock-keychain -p "" "$DEV_KEYCHAIN" || true
        codesign --force --sign "$DEV_CERT_HASH" \
            --keychain "$DEV_KEYCHAIN" "$DEV_BUNDLE_DEPLOY" >/dev/null \
            || fail "codesign with dev cert failed"
    fi
fi

if [ ! -x "$SIMULATOR_BIN" ]; then
    log "Building meeting-simulator"
    (cd "$SIMULATOR_PKG" && swift build -c release)
fi

# --- preset live-transcription on, engine Parakeet ------------------------

# These four defaults are the actual production seams the toggle uses.
# Crucially we do NOT set any debug env var that bypasses the real chain
# — the test must catch a regression in the wiring, not in a debug shim.
defaults write "$BUNDLE_ID" liveTranscriptionEnabled -bool true
defaults write "$BUNDLE_ID" transcriptionEngine -string parakeet
defaults write "$BUNDLE_ID" debugRPCEnabled -bool true
defaults write "$BUNDLE_ID" autoWatch -bool true

# --- launch + wait for RPC ------------------------------------------------

fg_user=$(stat -f "%Su" /dev/console)
my_user=$(id -un)
if [ "$fg_user" != "$my_user" ]; then
    fail "Aqua foreground user is '$fg_user', not '$my_user' — Fast User Switching is active."
fi

log "Launching $DEV_BUNDLE_DEPLOY"
open "$DEV_BUNDLE_DEPLOY"

log "Waiting up to ${RPC_READY_TIMEOUT_S}s for RPC /healthz"
deadline=$(( $(date +%s) + RPC_READY_TIMEOUT_S ))
while [ ! -f "$RPC_TOKEN_FILE" ] || ! { RPC_TOKEN="$(cat "$RPC_TOKEN_FILE")" && rpc /healthz >/dev/null; }; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "RPC /healthz did not respond within ${RPC_READY_TIMEOUT_S}s"
    sleep 1
done
log "RPC up"

# Cleanup trap — kill simulator + restore defaults.
SIM_PID=""
on_exit() {
    [ -n "${SIM_PID:-}" ] && kill "$SIM_PID" 2>/dev/null || true
    restore_bool_default  "$BUNDLE_ID" liveTranscriptionEnabled "$SAVED_LIVE_TRANS"
    if [ -n "$SAVED_TRANS_ENGINE" ]; then
        defaults write "$BUNDLE_ID" transcriptionEngine -string "$SAVED_TRANS_ENGINE"
    else
        defaults delete "$BUNDLE_ID" transcriptionEngine 2>/dev/null || true
    fi
    restore_bool_default "$BUNDLE_ID" debugRPCEnabled "$SAVED_DEBUG_RPC"
    restore_bool_default "$BUNDLE_ID" autoWatch       "$SAVED_AUTO_WATCH"
}
trap on_exit EXIT INT TERM

# --- trigger meeting + poll captions --------------------------------------

log "Starting meeting-simulator → $SIMULATOR_FIXTURE"
"$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-live-captions-sim.log 2>&1 &
SIM_PID=$!

log "Polling /state for liveCaptions.recentFinals (timeout ${CAPTION_DEADLINE_S}s)"
deadline=$(( $(date +%s) + CAPTION_DEADLINE_S ))
finals_count=0
finals_json="[]"
last_log_count=-1
while true; do
    assert_app_alive
    IFS='|' read -r finals_count finals_json < <(
        rpc /state | jq -r '[(.liveCaptions.recentFinals | length), (.liveCaptions.recentFinals | tojson)] | join("|")'
    ) || true
    finals_count="${finals_count:-0}"

    if [ "$finals_count" != "$last_log_count" ]; then
        log "  recentFinals.count = $finals_count"
        last_log_count="$finals_count"
    fi

    if [ "$finals_count" -gt 0 ]; then
        break
    fi

    [ "$(date +%s)" -lt "$deadline" ] || fail "no liveCaptions.recentFinals appeared within ${CAPTION_DEADLINE_S}s — wiring broken or model didn't produce text"
    sleep 5
done

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

if [ "$APP_AFTER" = quit ]; then
    quit_running_app
fi
