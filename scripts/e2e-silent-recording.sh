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
# A build run additionally needs a way to sign the deployed bundle, either
# DEVELOPER_ID in the environment or the dev keychain from
# scripts/setup-self-hosted-runner.sh, and refuses without one: the TCC grants
# are keyed on the certificate, and a denied capture is indistinguishable from
# the silence this lane asserts.
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
# Ends what a timed-out earlier step left running, then records this
# driver for the next (see e2e_register_driver).
e2e_register_driver
DEV_BUNDLE_BUILD="$ROOT/app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app"
# Deploy to a stable path so the dev .app's TCC permissions (granted once
# manually on the self-hosted runner, keyed on bundle path + cert SHA)
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
# shellcheck source=lib/bundle-ids.sh
source "$ROOT/scripts/lib/bundle-ids.sh"
BUNDLE_ID="$DEV_BUNDLE_ID"
REC_DIR="$HOME/Library/Application Support/MeetingTranscriber/recordings"
# Anchor for the EXIT-trap artifact sweep: created before any recording, so
# every file this run produces is newer than it (see sweep_run_artifacts).
RUN_START_MARKER="$(mktemp "${TMPDIR:-/tmp}/e2e-silent-rec-start.XXXXXX")"

# Defaults to restore after the test — empty string means "key wasn't set".
# Empty until the snapshot below runs. `cleanup` is trapped before that point
# and keys on this being set: an empty snapshot means "delete the key", which
# is right after this lane wrote it and destructive before it ever read it.
_STANDARD_PLIST=""
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
    # The app was kill -9'd mid-recording above, orphaning a raw temp; sweep
    # this run's artifacts so the next run doesn't crash-recover a stale temp.
    sweep_run_artifacts "$REC_DIR" "$RUN_START_MARKER"
    rm -f "${RUN_START_MARKER:-}" "${STATE_ERR_FILE:-}" 2>/dev/null || true
    # Restore defaults to whatever they were before we ran (or delete the
    # keys if they didn't exist).
    # Only restore what was actually snapshotted. An empty snapshot means
    # "delete the key", which is right after this lane set it and catastrophic
    # if the lane exited before the snapshot ran.
    if [ -n "$_STANDARD_PLIST" ]; then
        restore_bool_default  "$_STANDARD_PLIST" autoWatch                       "$SAVED_AUTOWATCH"
        restore_float_default "$_STANDARD_PLIST" asymmetricSilenceWarningSeconds "$SAVED_THRESHOLD"
        restore_bool_default  "$_STANDARD_PLIST" perChannelIndicatorEnabled      "$SAVED_INDICATOR"
    fi
    bootout_stale_launchctl
}
trap cleanup EXIT

# --- 1. Build + deploy ------------------------------------------------------

if [ "$NO_BUILD" = false ]; then
    # Establish the signing identity BEFORE anything is built or deployed.
    #
    # This lane's verdict rests entirely on the TCC grants: without a re-sign
    # the capture stack is denied and the tap delivers zeroes from its first
    # buffer, which is precisely the silence the lane asserts, and the two are
    # indistinguishable from in here. The deploy below also replaces the shared
    # bundle, so a refusal afterwards would strand an unsigned one at the path
    # every `--no-build` sibling lane reuses. See `require_signing_identity`.
    require_signing_identity || exit 1

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
    # the manual TCC grant (keyed on the cert SHA) keeps Microphone + Screen
    # Recording granted. Same pattern as scripts/e2e-app.sh — without this the
    # recorder runs but emits zero-byte WAVs because TCC denies the capture stack.
    echo "▸ Deploying to ${DEV_BUNDLE_DEPLOY} ..."
    mkdir -p "$(dirname "$DEV_BUNDLE_DEPLOY")"
    if [ -d "$DEV_BUNDLE_DEPLOY" ]; then
        rsync -a --delete "$DEV_BUNDLE_BUILD/" "$DEV_BUNDLE_DEPLOY/"
    else
        cp -R "$DEV_BUNDLE_BUILD" "$DEV_BUNDLE_DEPLOY"
    fi
    echo "▸ Re-signing $DEV_BUNDLE_DEPLOY with ${SIGN_IDENTITY}…"
    # Re-assert the search list right before codesign: a parallel job on the
    # Mini's other runner (shared OS user) may have mutated it during our build.
    # codesign honours `--keychain` for the identity but still consults the
    # search list for trust-chain resolution.
    [ -z "$SIGN_KEYCHAIN" ] || "$ROOT/scripts/keychain-prepend.sh" "$SIGN_KEYCHAIN" || true
    resign_deployed_bundle "$DEV_BUNDLE_DEPLOY" "$SIGN_IDENTITY" "$SIGN_KEYCHAIN" \
        || die "re-sign of the deployed bundle failed"
else
    # Under `--no-build` this lane signs nothing: it inherits whatever bundle the
    # step before it left at the shared deploy path, and inherits that step's
    # certificate with it. That matters more here than in any sibling lane,
    # because this lane's PASS condition is silence on both tracks. A bundle TCC
    # will not grant capture to produces exactly that, from the first buffer and
    # with no error anywhere, so a denied run and a working watchdog look
    # identical from in here.
    #
    # The expectation cannot be recomputed here. The workflow sets DEVELOPER_ID
    # per step, and the step this lane runs in is one of the few that does not
    # carry it, so asking "what would this host sign with" would answer with the
    # dev keychain's self-signed certificate and refuse every run. The deploy
    # that signed the bundle records its leaf beside it, and this compares
    # against that record instead.
    assert_deployed_signing_leaf "$DEV_BUNDLE_DEPLOY" \
        || die "the deployed bundle is not the one that was signed — see above"
fi

for path in "$BIN" "$MTCLI" "$SIM"; do
    [ -x "$path" ] || die "required binary missing: $path — run without --no-build first"
done

# --- 2. Snapshot the defaults this lane overrides ---------------------------

# Address the standard-domain plist directly. `defaults <bundle-id>` is
# redirected into the app's container once containermanagerd has registered
# one for the identifier, and the dev .app is not sandboxed, so it resolves
# the standard domain. Reading and restoring the wrong one silently leaks this
# lane's 30 s threshold into whatever runs next, or leaves the app on its
# built-in 90 s while the lane waits 50 s for a flag that cannot flip in time.
#
# The snapshot runs BEFORE the quit below for a reason that has nothing to do
# with preferences and everything to do with the exit trap. `quit_running_app`
# is bare under `set -e`, so an exhausted quit ladder exits the script straight
# into `cleanup` with every SAVED_* still empty, and an empty snapshot restores
# by DELETING the key. Snapshotting first means the trap can never delete a
# developer's real settings that this lane never read.
#
# The writes still run after the quit, which is defensive rather than measured:
# a live instance owning the same domain did NOT clobber an external write in
# testing on macOS 26, but nothing is gained by writing underneath a process
# that is about to be killed anyway.
_STANDARD_PLIST="$(dev_standard_plist "$BUNDLE_ID")"
SAVED_AUTOWATCH="$(snapshot_default "$_STANDARD_PLIST" autoWatch)"
SAVED_THRESHOLD="$(snapshot_default "$_STANDARD_PLIST" asymmetricSilenceWarningSeconds)"
SAVED_INDICATOR="$(snapshot_default "$_STANDARD_PLIST" perChannelIndicatorEnabled)"

# --- 3. Kill any running instance, then override ----------------------------

quit_running_app "$BUNDLE_ID"

write_dev_default "$BUNDLE_ID" autoWatch true bool
write_dev_default "$BUNDLE_ID" asymmetricSilenceWarningSeconds 30 float
write_dev_default "$BUNDLE_ID" perChannelIndicatorEnabled true bool

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

# One /state read into STATE, `{}` when the app did not answer; answers are
# counted and STATE_LAST_ANSWERED says whether the latest read got one. That
# keeps the verdict honest: an app that does not answer reads as "flag false"
# on every poll, and this lane once blamed the detector, with an empty state
# dump, while the app was blocked behind a TCC consent prompt. mt-cli has its
# own 5 s request timeout; the bound is for an mt-cli that blocks before it
# gets that far.
STATE_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/e2e-silent-state-err.XXXXXX")"
_read_state() {
    local status=0
    STATE="$(run_bounded 8 "$MTCLI" state 2>"$STATE_ERR_FILE")" || status=$?
    if [ "$status" -eq 0 ] && [ -n "$STATE" ]; then
        STATE_ANSWERED=$(( ${STATE_ANSWERED:-0} + 1 ))
        STATE_LAST_ANSWERED=1
        STATE_LAST_GOOD="$STATE"
    else
        STATE='{}'
        STATE_LAST_ANSWERED=0
        # What the last failed read said, for the verdict below.
        if [ "$status" -eq 124 ]; then
            STATE_LAST_ERR="mt-cli did not return within 8 s"
        else
            STATE_LAST_ERR="$(tr '\n' ' ' <"$STATE_ERR_FILE")"
        fi
    fi
}

echo "▸ Waiting for app to detect + start recording (max 30 s)…"
# `isProcessing` flips true while a job is in the queue. It's informational
# only — if it never flips we still let step 7 run and time out there,
# which gives a clearer "recordingSilent never went true" failure than
# bailing here would. Hence `|| true`: a timeout here is non-fatal.
_processing_started() {
    assert_app_alive
    _read_state
    [ "$(jq -r '.pipeline.isProcessing // false' <<<"$STATE")" = "true" ]
}
poll_until 30 1 _processing_started || true

# --- 7. Poll for recordingSilent flag -----------------------------------------

echo "▸ Polling for channelHealth.recordingSilent (threshold 30 s + 20 s slack)…"
# Extract all three channelHealth flags in one jq pass. Safe with @tsv
# because every field has a `// false` default — no empties possible.
# `IFS=$'\t' read` would collapse consecutive empties (tab is
# whitespace-IFS), so if a non-defaulted field is added later, switch to
# `|`-join (see `_poll_for_new_lastjob_terminal` in e2e-app.sh). MIC_SILENT
# and APP_SILENT leak to caller scope for the success log line below.
_recording_silent() {
    assert_app_alive
    _read_state
    IFS=$'\t' read -r RECORDING_SILENT MIC_SILENT APP_SILENT < <(
        echo "$STATE" \
            | jq -r '[.channelHealth.recordingSilent // false, .channelHealth.micSilent // false, .channelHealth.appSilent // false] | @tsv'
    )
    [ "$RECORDING_SILENT" = "true" ]
}
STATE_ANSWERED=0
STATE_LAST_GOOD=""
if poll_until 50 2 _recording_silent; then
    echo "  recordingSilent=true (mic=$MIC_SILENT app=$APP_SILENT)"
else
    # No verdict on the flag unless the app answered during the window and is
    # still answering at its end: one more read, and the window's last read or
    # that one must have answered, so a single dropped read does not count.
    # The extra read below only asks whether the app still answers; the
    # verdict and the state printed with it are the window's own last answer.
    window_answered="$STATE_ANSWERED" last_answered="$STATE_LAST_ANSWERED" window_state="${STATE_LAST_GOOD:-}"
    [ -n "$window_state" ] || window_state="{}"
    assert_app_alive
    _read_state
    if [ "$window_answered" -eq 0 ] || { [ "$last_answered" = 0 ] && [ "$STATE_LAST_ANSWERED" = 0 ]; }; then
        die "the app did not answer /state through the end of the 50 s window (answered $window_answered read(s) in it), so whether recordingSilent went true is unknown (last mt-cli error: ${STATE_LAST_ERR:-<none>}). The app process is alive. If mt-cli timed out rather than being refused, the app is blocked, and on the runner the likeliest cause is a TCC consent prompt waiting on its screen (this lane starts the binary directly, so TCC may attribute the app's accesses to the runner's node). Fix: $(tcc_fix_hint 'the pane the prompt names')"
    fi
    echo "Last state the app answered within the window:" >&2
    jq . <<<"$window_state" >&2 || true
    die "channelHealth.recordingSilent never went true within 50 s"
fi

echo
echo "OK — production chain verified:"
echo "  WatchLoop → activeRecorder → 10 Hz polling task → SilentRecordingMonitor"
echo "  → recordingSilentActive → RPC snapshot"
