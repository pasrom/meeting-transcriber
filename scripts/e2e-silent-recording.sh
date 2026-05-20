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
# shellcheck source=lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"
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
# `release/` to align with `scripts/e2e-app.sh` — when both scripts run
# in the same CI workflow, e2e-app.sh's release build is reused via
# `--no-build` rather than rebuilt in debug mode.
SIM="$ROOT/tools/meeting-simulator/.build/release/meeting-simulator"
BUNDLE_ID="com.meetingtranscriber.dev"

# Defaults to restore after the test — empty string means "key wasn't set".
SAVED_AUTOWATCH=""
SAVED_THRESHOLD=""
SAVED_INDICATOR=""

cleanup() {
    if [ -n "${SIM_PID:-}" ] && kill -0 "$SIM_PID" 2>/dev/null; then
        kill -TERM "$SIM_PID" 2>/dev/null || true
    fi
    if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -9 "$APP_PID" 2>/dev/null || true
    fi
    # Restore defaults to whatever they were before we ran (or delete the
    # keys if they didn't exist).
    restore_bool_default  "$BUNDLE_ID" autoWatch                       "$SAVED_AUTOWATCH"
    restore_float_default "$BUNDLE_ID" asymmetricSilenceWarningSeconds "$SAVED_THRESHOLD"
    restore_bool_default  "$BUNDLE_ID" perChannelIndicatorEnabled      "$SAVED_INDICATOR"
    bootout_stale_launchctl
}
trap cleanup EXIT

# --- 1. Build + deploy ------------------------------------------------------

if [ "$NO_BUILD" = false ]; then
    echo "▸ Building dev .app…"
    "$ROOT/scripts/run_app.sh" --build-only >/dev/null
    # meeting-simulator and mt-cli live under separate `.build/` dirs and
    # share no targets, so they can compile in parallel. Cuts ~5–15 s off
    # the cold-cache path. meeting-simulator is built in release to match
    # scripts/e2e-app.sh's `SIMULATOR_BIN` path — re-using its
    # pre-existing build under `--no-build` instead of producing a second
    # debug copy.
    echo "▸ Building meeting-simulator + mt-cli (parallel)…"
    (cd "$ROOT/tools/meeting-simulator" && swift build -c release >/dev/null) &
    SIM_BUILD_PID=$!
    (cd "$ROOT/tools/mt-cli" && swift build >/dev/null) &
    CLI_BUILD_PID=$!
    # `wait $PID1 $PID2` only returns the exit code of the LAST PID — an
    # earlier failure would be silently dropped and surface ~60 lines down
    # as the confusing "required binary missing" guard. Wait individually so
    # whichever build failed is the failure that actually halts the script.
    wait "$SIM_BUILD_PID" || die "meeting-simulator build failed"
    wait "$CLI_BUILD_PID" || die "mt-cli build failed"

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
            || die "Developer ID re-sign failed"
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
                    || die "dev-cert re-sign failed"
            else
                echo "  Run scripts/setup-self-hosted-runner.sh to (re-)create it" >&2
                die "dev keychain present but no '$DEV_CERT_NAME' identity inside"
            fi
        else
            echo "▸ WARNING: no DEVELOPER_ID and no $DEV_KEYCHAIN — TCC may deny capture" >&2
            echo "  (run scripts/setup-self-hosted-runner.sh to fix)"
        fi
    fi
fi

for path in "$BIN" "$MTCLI" "$SIM"; do
    [ -x "$path" ] || die "required binary missing: $path — run without --no-build first"
done

# --- 2. Snapshot + override defaults so the test is deterministic -----------

SAVED_AUTOWATCH="$(snapshot_default "$BUNDLE_ID" autoWatch)"
SAVED_THRESHOLD="$(snapshot_default "$BUNDLE_ID" asymmetricSilenceWarningSeconds)"
SAVED_INDICATOR="$(snapshot_default "$BUNDLE_ID" perChannelIndicatorEnabled)"

/usr/bin/defaults write "$BUNDLE_ID" autoWatch -bool true
/usr/bin/defaults write "$BUNDLE_ID" asymmetricSilenceWarningSeconds -float 30
/usr/bin/defaults write "$BUNDLE_ID" perChannelIndicatorEnabled -bool true

# --- 3. Kill any running instance -------------------------------------------

quit_running_app "$BUNDLE_ID"

# --- 4. Launch app with RPC enabled -----------------------------------------

env MEETINGTRANSCRIBER_DEBUG_RPC=1 "$BIN" &
APP_PID=$!

echo "▸ Waiting for RPC on 127.0.0.1:9876…"
wait_for_rpc "$MTCLI" 30 || die "RPC server did not start within 30 s"
echo "  RPC up"

# --- 5. Trigger a "silent meeting" via meeting-simulator --------------------

# Window title matches the simulator MeetingDetector pattern. --silent
# means no audio is played, so the CATapDescription tap sees only zero
# buffers (and the mic side stays at the BlackHole noise floor).
# --duration covers the 30 s detector threshold + slack for the
# polling task to flip the flag.
echo "▸ Launching meeting-simulator (silent, 75 s)…"
# `findFixture()` inside the simulator resolves the repo's bundled
# WAV at compile time — no explicit path needed. The fixture is
# required even in `--silent` mode so AVAudioPlayer pumps zero-content
# frames through the audio device (see the simulator commit body).
"$SIM" --silent --duration=75 &
SIM_PID=$!

# --- 6. Wait for WatchLoop to enter recording state ------------------------

echo "▸ Waiting for app to detect + start recording (max 30 s)…"
# `isProcessing` flips true while a job is in the queue. It's informational
# only — if it never flips we still let step 7 run and time out there,
# which gives a clearer "recordingSilent never went true" failure than
# bailing here would.
for _ in $(seq 1 30); do
    assert_app_alive
    STATE_JSON="$("$MTCLI" state 2>/dev/null || echo '{}')"
    PROCESSING="$(echo "$STATE_JSON" | jq -r '.pipeline.isProcessing // false')"
    if [ "$PROCESSING" = "true" ]; then
        break
    fi
    sleep 1
done

# --- 7. Poll for recordingSilent flag -----------------------------------------

echo "▸ Polling for channelHealth.recordingSilent (threshold 30 s + 20 s slack)…"
DEADLINE=$(( $(date +%s) + 50 ))
OBSERVED_SILENT=false
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    assert_app_alive
    STATE_JSON="$("$MTCLI" state 2>/dev/null || echo '{}')"
    # Extract all three channelHealth flags in one jq pass. Safe here
    # because every field has a `// false` default — no empties possible.
    # `IFS=$'\t' read` would collapse consecutive empties (tab is
    # whitespace-IFS), so if a non-defaulted field is added later, switch
    # to `|`-join (see `_poll_for_new_lastjob_terminal` in e2e-app.sh).
    IFS=$'\t' read -r RECORDING_SILENT MIC_SILENT APP_SILENT < <(
        echo "$STATE_JSON" \
            | jq -r '[.channelHealth.recordingSilent // false, .channelHealth.micSilent // false, .channelHealth.appSilent // false] | @tsv'
    )
    if [ "$RECORDING_SILENT" = "true" ]; then
        OBSERVED_SILENT=true
        echo "  recordingSilent=true (mic=$MIC_SILENT app=$APP_SILENT)"
        break
    fi
    sleep 2
done

if [ "$OBSERVED_SILENT" != "true" ]; then
    echo "Final state:" >&2
    "$MTCLI" state 2>/dev/null | jq . >&2 || true
    die "channelHealth.recordingSilent never went true within 50 s"
fi

echo
echo "OK — production chain verified:"
echo "  WatchLoop → activeRecorder → 10 Hz polling task → SilentRecordingMonitor"
echo "  → recordingSilentActive → RPC snapshot"
