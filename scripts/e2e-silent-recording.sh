#!/usr/bin/env bash
# E2E test for the silent-recording detector — the failure mode that shipped
# past PR #286 unnoticed (40 min Teams call → both channels at noise floor →
# no in-app warning).
#
# Unlike scripts/e2e-channel-health.sh, this driver does NOT use a debug
# env-hook to set the observable directly. Instead it:
#   1. Launches the dev .app with autoWatch enabled (via defaults write).
#   2. Launches tools/meeting-simulator with --silent → window with a
#      MeetingDetector-matching title pops, but no audio is played.
#   3. The app's MeetingDetector / PowerAssertionDetector picks up the
#      simulator, WatchLoop transitions to .recording, the recorder taps
#      the (silent) system output + mic.
#   4. AppState's 10-Hz polling task feeds the (-120, -120) readings into
#      SilentRecordingMonitor.
#   5. After `asymmetricSilenceWarningSeconds` of sustained both-silent,
#      .started fires → `recordingSilentActive = true`.
#   6. This script polls `/state.channelHealth.recordingSilent` via the
#      RPC server and asserts true.
#
# Crucially, reverting `activeRecorder = recorder` in `WatchLoop.handleMeeting`
# OR removing the `silentRecordingMonitor.update(...)` wiring in AppState
# will make this assertion fail — that's the contract this e2e enforces:
# the full production chain must work end-to-end.
#
# Runs on:
#   - Any macOS host with auto-login + an Aqua GUI session (for the
#     meeting-simulator window to be visible to CATapDescription)
#   - Self-hosted Mac mini with BlackHole 2ch as default input (so the mic
#     side is genuinely silent under the synthetic meeting)
#
# Usage: bash scripts/e2e-silent-recording.sh [--no-build]

set -euo pipefail

NO_BUILD=false

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) NO_BUILD=true ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_BUNDLE_BUILD="$ROOT/app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app"
# Deploy to a stable path so the dev .app's TCC permissions (granted via
# the self-hosted runner's PPPC profile, keyed on bundle path + cert SHA)
# persist across builds. A `/tmp/...` launch would get a fresh cdhash AND
# a fresh path on every clone — TCC would deny Microphone + Screen
# Recording and the recorder would emit zero-byte WAVs (observed during
# this script's development).
DEV_BUNDLE_DEPLOY="$HOME/Applications/MeetingTranscriber-Dev.app"
BIN="$DEV_BUNDLE_DEPLOY/Contents/MacOS/MeetingTranscriber"
MTCLI="$ROOT/tools/mt-cli/.build/debug/mt-cli"
SIM="$ROOT/tools/meeting-simulator/.build/debug/meeting-simulator"
BUNDLE_ID="com.meetingtranscriber.dev"

# Defaults to restore after the test — empty string means "key wasn't set".
SAVED_AUTOWATCH=""
SAVED_THRESHOLD=""
SAVED_INDICATOR=""

restore_bool() {
    # `defaults read` returns bools as 0/1 but `-bool` only accepts the
    # literal token (true/false/yes/no). Translate before writing back so
    # the cleanup doesn't print the defaults usage screen and bail out on
    # the first restore call.
    local key="$1"
    local saved="$2"
    case "$saved" in
        1) /usr/bin/defaults write "$BUNDLE_ID" "$key" -bool true ;;
        0) /usr/bin/defaults write "$BUNDLE_ID" "$key" -bool false ;;
        *) /usr/bin/defaults delete "$BUNDLE_ID" "$key" 2>/dev/null || true ;;
    esac
}

cleanup() {
    if [ -n "${SIM_PID:-}" ] && kill -0 "$SIM_PID" 2>/dev/null; then
        kill -TERM "$SIM_PID" 2>/dev/null || true
    fi
    if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -9 "$APP_PID" 2>/dev/null || true
    fi
    # Restore defaults to whatever they were before we ran (or delete the
    # keys if they didn't exist).
    restore_bool autoWatch "$SAVED_AUTOWATCH"
    if [ -n "$SAVED_THRESHOLD" ]; then
        /usr/bin/defaults write "$BUNDLE_ID" asymmetricSilenceWarningSeconds -float "$SAVED_THRESHOLD"
    else
        /usr/bin/defaults delete "$BUNDLE_ID" asymmetricSilenceWarningSeconds 2>/dev/null || true
    fi
    restore_bool perChannelIndicatorEnabled "$SAVED_INDICATOR"
    launchctl list 2>/dev/null \
        | awk '$3 ~ /com\.meetingtranscriber\.dev/ {print $3}' \
        | while read -r srv; do
            launchctl bootout "gui/$(id -u)/$srv" 2>/dev/null || true
        done
}
trap cleanup EXIT

# --- 1. Build + deploy ------------------------------------------------------

if [ "$NO_BUILD" = false ]; then
    echo "▸ Building dev .app…"
    "$ROOT/scripts/run_app.sh" --build-only >/dev/null
    # meeting-simulator and mt-cli live under separate `.build/` dirs and
    # share no targets, so they can compile in parallel. Cuts ~5–15 s off
    # the cold-cache path.
    echo "▸ Building meeting-simulator + mt-cli (parallel)…"
    (cd "$ROOT/tools/meeting-simulator" && swift build >/dev/null) &
    SIM_BUILD_PID=$!
    (cd "$ROOT/tools/mt-cli" && swift build >/dev/null) &
    CLI_BUILD_PID=$!
    wait $SIM_BUILD_PID $CLI_BUILD_PID

    # Deploy to the stable path and re-sign with the runner's dev cert so
    # the PPPC profile keeps granting Microphone + Screen Recording. Same
    # pattern as scripts/e2e-app.sh — without this the recorder runs but
    # emits zero-byte WAVs because TCC denies the capture stack.
    echo "▸ Deploying to ${DEV_BUNDLE_DEPLOY} ..."
    mkdir -p "$(dirname "$DEV_BUNDLE_DEPLOY")"
    if [ -d "$DEV_BUNDLE_DEPLOY" ]; then
        rsync -a --delete "$DEV_BUNDLE_BUILD/" "$DEV_BUNDLE_DEPLOY/"
    else
        cp -R "$DEV_BUNDLE_BUILD" "$DEV_BUNDLE_DEPLOY"
    fi
    if [ -n "${DEVELOPER_ID:-}" ]; then
        echo "▸ Re-signing with Developer ID '$DEVELOPER_ID'…"
        SIGN_ARGS=(--force --sign "$DEVELOPER_ID")
        [ -n "${E2E_SIGNING_KEYCHAIN:-}" ] && SIGN_ARGS+=(--keychain "$E2E_SIGNING_KEYCHAIN")
        codesign "${SIGN_ARGS[@]}" "$DEV_BUNDLE_DEPLOY" >/dev/null \
            || { echo "FAIL: Developer ID re-sign failed" >&2; exit 1; }
    else
        # Local-dev path: self-signed cert from setup-self-hosted-runner.sh.
        # Resolve the SHA-1 directly from the keychain (the .pem written
        # to /tmp/ by the setup script is volatile — gone on every reboot
        # on the self-hosted Mini). Unlock with empty password (matches
        # the keychain creation in setup-self-hosted-runner.sh), then
        # sign with the hash.
        DEV_KEYCHAIN="$HOME/Library/Keychains/meetingtranscriber-dev.keychain-db"
        DEV_CERT_NAME="MeetingTranscriberDevSelfHosted"
        if [ -f "$DEV_KEYCHAIN" ]; then
            security unlock-keychain -p "" "$DEV_KEYCHAIN" 2>/dev/null || true
            DEV_CERT_HASH="$(security find-identity -v -p codesigning "$DEV_KEYCHAIN" \
                | awk -v name="$DEV_CERT_NAME" '$0 ~ name { print $2; exit }')"
            if [ -n "$DEV_CERT_HASH" ]; then
                echo "▸ Re-signing with self-signed dev cert (SHA1=${DEV_CERT_HASH})..."
                # codesign honours `--keychain` for the signing identity but
                # still consults the user-domain search list for trust-chain
                # resolution. Prepending the dev keychain matches scripts/e2e-app.sh.
                "$ROOT/scripts/keychain-prepend.sh" "$DEV_KEYCHAIN" 2>/dev/null || true
                codesign --force --sign "$DEV_CERT_HASH" --keychain "$DEV_KEYCHAIN" \
                    "$DEV_BUNDLE_DEPLOY" >/dev/null \
                    || { echo "FAIL: dev-cert re-sign failed" >&2; exit 1; }
            else
                echo "FAIL: dev keychain present but no '$DEV_CERT_NAME' identity inside" >&2
                echo "  Run scripts/setup-self-hosted-runner.sh to (re-)create it"
                exit 1
            fi
        else
            echo "▸ WARNING: no DEVELOPER_ID and no $DEV_KEYCHAIN — TCC may deny capture" >&2
            echo "  (run scripts/setup-self-hosted-runner.sh to fix)"
        fi
    fi
fi

for path in "$BIN" "$MTCLI" "$SIM"; do
    if [ ! -x "$path" ]; then
        echo "FAIL: required binary missing: $path — run without --no-build first" >&2
        exit 1
    fi
done

# --- 2. Snapshot + override defaults so the test is deterministic -----------

SAVED_AUTOWATCH="$(/usr/bin/defaults read "$BUNDLE_ID" autoWatch 2>/dev/null | tr -d '[:space:]' || true)"
SAVED_THRESHOLD="$(/usr/bin/defaults read "$BUNDLE_ID" asymmetricSilenceWarningSeconds 2>/dev/null | tr -d '[:space:]' || true)"
SAVED_INDICATOR="$(/usr/bin/defaults read "$BUNDLE_ID" perChannelIndicatorEnabled 2>/dev/null | tr -d '[:space:]' || true)"

/usr/bin/defaults write "$BUNDLE_ID" autoWatch -bool true
/usr/bin/defaults write "$BUNDLE_ID" asymmetricSilenceWarningSeconds -float 30
/usr/bin/defaults write "$BUNDLE_ID" perChannelIndicatorEnabled -bool true

# --- 3. Kill any running instance -------------------------------------------

if pgrep -f "MeetingTranscriber-Dev" >/dev/null 2>&1; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
    pkill -TERM -f "MeetingTranscriber-Dev" 2>/dev/null || true
    for _ in $(seq 1 10); do
        pgrep -f "MeetingTranscriber-Dev" >/dev/null 2>&1 || break
        sleep 0.5
    done
    pkill -9 -f "MeetingTranscriber-Dev" 2>/dev/null || true
fi

# --- 4. Launch app with RPC enabled -----------------------------------------

env MEETINGTRANSCRIBER_DEBUG_RPC=1 "$BIN" &
APP_PID=$!

echo "▸ Waiting for RPC on 127.0.0.1:9876…"
for i in $(seq 1 30); do
    if "$MTCLI" healthz >/dev/null 2>&1; then
        echo "  RPC up after ${i}s"
        break
    fi
    sleep 1
done
if ! "$MTCLI" healthz >/dev/null 2>&1; then
    echo "FAIL: RPC server did not start within 30 s" >&2
    exit 1
fi

# --- 5. Trigger a "silent meeting" via meeting-simulator --------------------

# Window title matches the simulator MeetingDetector pattern. --silent
# means no audio is played, so the CATapDescription tap sees only zero
# buffers (and the mic side stays at the BlackHole noise floor).
# --duration covers the 30 s detector threshold + slack for the
# polling task to flip the flag.
echo "▸ Launching meeting-simulator (silent, 75 s)…"
# Pass the fixture explicitly — meeting-simulator's findFixture() looks
# at a stale path (`tests/fixtures/...`) that doesn't match the actual
# repo layout (`app/MeetingTranscriber/Tests/Fixtures/...`). We need the
# fixture even in --silent mode so AVAudioPlayer pumps zero-content
# frames through the audio device (see the simulator commit body for why).
FIXTURE="$ROOT/app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav"
"$SIM" "$FIXTURE" "Simulator Meeting | MeetingSimulator" --silent --duration=75 &
SIM_PID=$!

# --- 6. Wait for WatchLoop to enter recording state ------------------------

echo "▸ Waiting for app to detect + start recording (max 30 s)…"
# `isProcessing` flips true while a job is in the queue. It's informational
# only — if it never flips we still let step 7 run and time out there,
# which gives a clearer "recordingSilent never went true" failure than
# bailing here would.
for _ in $(seq 1 30); do
    STATE_JSON="$("$MTCLI" state 2>/dev/null || echo '{}')"
    PROCESSING="$(echo "$STATE_JSON" | jq -r '.pipeline.isProcessing // false')"
    if [ "$PROCESSING" = "true" ]; then
        break
    fi
    sleep 1
done

# --- 7. Poll for recordingSilent flag -----------------------------------------

echo "▸ Polling for channelHealth.recordingSilent (threshold 30 s + 15 s slack)…"
DEADLINE=$(( $(date +%s) + 50 ))
OBSERVED_SILENT=false
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    STATE_JSON="$("$MTCLI" state 2>/dev/null || echo '{}')"
    RECORDING_SILENT="$(echo "$STATE_JSON" | jq -r '.channelHealth.recordingSilent // false')"
    MIC_SILENT="$(echo "$STATE_JSON" | jq -r '.channelHealth.micSilent // false')"
    APP_SILENT="$(echo "$STATE_JSON" | jq -r '.channelHealth.appSilent // false')"
    if [ "$RECORDING_SILENT" = "true" ]; then
        OBSERVED_SILENT=true
        echo "  recordingSilent=true (mic=$MIC_SILENT app=$APP_SILENT)"
        break
    fi
    sleep 2
done

if [ "$OBSERVED_SILENT" != "true" ]; then
    echo "FAIL: channelHealth.recordingSilent never went true within 50 s" >&2
    echo "Final state:" >&2
    "$MTCLI" state 2>/dev/null | jq . >&2 || true
    exit 1
fi

echo
echo "OK — production chain verified:"
echo "  WatchLoop → activeRecorder → 10 Hz polling task → SilentRecordingMonitor"
echo "  → recordingSilentActive → RPC snapshot"
