#!/usr/bin/env bash
# E2E test for the capture-fault path (issue #614): the app must report a
# channel that has stopped delivering, and stay quiet about one that is merely
# quiet.
#
# This is the lane that pins the distinction the old implementation could not
# make. It used to warn whenever one channel was quieter than the other for the
# debounce window, which is what a muted or listening microphone looks like, so
# the warning fired on a large share of ordinary meetings and was dismissed on
# reflex.
#
# One recording, two phases, in this order because the fault latches once per
# recording:
#
#   Phase 1 (the regression): low-level noise plays into BlackHole 2ch, so the
#     microphone track carries real samples below the -60 dBFS silence
#     threshold while the simulator's fixture keeps the app track above the
#     -50 dBFS speech threshold. The asymmetric-silence episode must latch
#     (micSilent == true, proving the pre-fix trigger condition was really
#     met), and nothing may be reported.
#
#   Phase 2 (the control): the noise stops, the microphone track becomes exact
#     zeroes, everything else is unchanged. Now the fault must be reported,
#     exactly once, with the digital-silence wording.
#
# The two phases are each other's control, which is the point of running them
# in one recording. An app that reports nothing at all sails through phase 1
# and fails phase 2; one that reports everything quiet fails phase 1. Neither
# assertion is worth much alone.
#
# Why the noise needs its own player rather than a routing change: BlackHole
# loops back whatever any client plays into it, regardless of the system
# default, so scripts/play-quiet-noise.swift addresses it directly and the
# default output is never touched. Rerouting it (as --mic-only does) would put
# the simulator's fixture into the microphone track at full level and destroy
# the asymmetry. The app track is unaffected either way: it comes from the
# process tap, which reads process output and touches no device.
#
# What this does NOT cover:
#   - noBuffers on a live channel. Producing it means unplugging hardware or
#     killing coreaudiod, neither of which belongs on a shared runner. The
#     two faults differ only in value logic, which unit tests pin.
#   - That the user SEES the notification. `posted` proves the app handed it to
#     UNUserNotificationCenter, nothing more.
#   - The urgency split. The ring-buffer entry carries no urgency field, so
#     that stays at unit level on the pure `captureAlert`.
#   - Whether real hardware mutes deliver zeroes rather than dither. That is
#     the field question this lane cannot answer for any device but BlackHole.
#
# Runs on:
#   - A macOS host with an Aqua GUI session and BlackHole 2ch as the default
#     input (the self-hosted Mac mini's standing configuration).
#
# Usage: bash scripts/e2e-channel-fault.sh [--no-build]

set -euo pipefail

# An app launched over SSH gets silent zero buffers from the microphone: macOS
# attributes the TCC check to the sshd process chain rather than to the bundle
# holding the grant, and an unauthorised client is zeroed rather than refused.
# Buffers still arrive on time, every sample is zero, nothing is logged, and the
# app's own permission probe still reports healthy because it asks about its own
# bundle identity. That is indistinguishable from the fault this lane exists to
# provoke, so a run from an SSH shell can only produce a false pass or a false
# accusation. Measured on the runner: the same app started into the GUI launchd
# domain reads the same audio at -70 dBFS.
if [ -n "${SSH_CONNECTION:-}" ]; then
    echo "This lane cannot run over SSH: the microphone would be silently zeroed" >&2
    echo "by TCC attribution, which looks exactly like the failure it tests for." >&2
    echo "Run it from the GUI session, or in CI." >&2
    exit 2
fi

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
# Stable deploy path so the runner's manual TCC grants survive rebuilds; see
# scripts/e2e-silent-recording.sh for the full reasoning.
DEV_BUNDLE_DEPLOY="$HOME/Applications/MeetingTranscriber-Dev.app"
BIN="$DEV_BUNDLE_DEPLOY/Contents/MacOS/MeetingTranscriber"
MTCLI="$ROOT/tools/mt-cli/.build/debug/mt-cli"
SIM="$ROOT/tools/meeting-simulator/.build/release/meeting-simulator"
NOISE="$ROOT/scripts/play-quiet-noise.swift"
# shellcheck source=lib/bundle-ids.sh
source "$ROOT/scripts/lib/bundle-ids.sh"
BUNDLE_ID="$DEV_BUNDLE_ID"
REC_DIR="$HOME/Library/Application Support/MeetingTranscriber/recordings"
RUN_START_MARKER="$(mktemp "${TMPDIR:-/tmp}/e2e-channel-fault-start.XXXXXX")"

# The loopback device the microphone track reads from. Named, not a UID:
# this is what the runner setup documents and what a person sees in System
# Settings.
NOISE_DEVICE="BlackHole 2ch"
# Comfortably under the -60 dBFS silence threshold and comfortably above
# digital zero, which is the whole state under test.
NOISE_DBFS=-70
# The window both monitors use, pushed to the 30 s floor the production clamp
# allows so the lane costs two minutes rather than six.
WINDOW_SECONDS=30
# The meeting has to outlast both phases with room to spare, and each phase
# waits up to three windows. Derived rather than written down, because the two
# already drifted apart once: widening the phases to three windows left the
# meeting ending in the middle of phase 2, and the lane reported the resulting
# empty state as the app failing to notice a dead channel.
SIM_SECONDS=$((WINDOW_SECONDS * 8))

# The dev bundle has a pre-existing container at
# `~/Library/Containers/<bundle>/…`, and macOS routes the app's UserDefaults
# reads there whether or not this binary is sandboxed. A plain
# `defaults write <bundle>` from outside lands in the standard domain and is
# then silently a no-op, so this lane would run against whatever the container
# happened to hold: a stale 90 s window makes phase 1 wait too little,
# `autoWatch=false` means no recording at all, and a disabled indicator means
# no monitors. Both domains are written, and both are restored. Same reasoning
# and same shape as `_set_dev_default` in scripts/e2e-app.sh.
CONTAINER_PLIST="$(dev_container_plist)"
# The one the app actually uses on this runner. Measured, not assumed: the
# standard file is the one carrying the app's own window geometry, which only a
# running app writes, while every `defaults write <bundle-id>` from a shell
# landed in the container. The helper's note has the redirect the other way
# round, so writing only the two documented targets left the app reading its
# built-in defaults and the lane racing a threshold three times longer than it
# had set.
STANDARD_PLIST="$(dev_standard_plist)"

set_dev_default() {
    local key="$1" value="$2" type="$3"
    write_dev_default "$BUNDLE_ID" "$key" "$value" "$type"
}

SAVED_AUTOWATCH_CONTAINER=""
SAVED_THRESHOLD_CONTAINER=""
SAVED_INDICATOR_CONTAINER=""
SAVED_RPC_CONTAINER=""
SAVED_AUTOWATCH_STANDARD=""
SAVED_THRESHOLD_STANDARD=""
SAVED_INDICATOR_STANDARD=""
SAVED_RPC_STANDARD=""

cleanup() {
    if [ -n "${NOISE_PID:-}" ] && kill -0 "$NOISE_PID" 2>/dev/null; then
        kill -TERM "$NOISE_PID" 2>/dev/null || true
    fi
    if [ -n "${SIM_PID:-}" ] && kill -0 "$SIM_PID" 2>/dev/null; then
        kill -TERM "$SIM_PID" 2>/dev/null || true
    fi
    pkill -f "MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber" 2>/dev/null || true
    sweep_run_artifacts "$REC_DIR" "$RUN_START_MARKER"
    rm -f "${RUN_START_MARKER:-}" 2>/dev/null || true
    # Only the two domains that exist as files. Restoring "$BUNDLE_ID" as a third
    # target would just be the container again wherever the redirect is active,
    # and the standard plist wherever it is not.
    if [ -f "$CONTAINER_PLIST" ]; then
        restore_bool_default  "$CONTAINER_PLIST" autoWatch                       "$SAVED_AUTOWATCH_CONTAINER"
        restore_float_default "$CONTAINER_PLIST" asymmetricSilenceWarningSeconds "$SAVED_THRESHOLD_CONTAINER"
        restore_bool_default  "$CONTAINER_PLIST" perChannelIndicatorEnabled      "$SAVED_INDICATOR_CONTAINER"
        restore_bool_default  "$CONTAINER_PLIST" debugRPCEnabled                  "$SAVED_RPC_CONTAINER"
    fi
    restore_bool_default  "$STANDARD_PLIST" autoWatch                       "$SAVED_AUTOWATCH_STANDARD"
    restore_float_default "$STANDARD_PLIST" asymmetricSilenceWarningSeconds "$SAVED_THRESHOLD_STANDARD"
    restore_bool_default  "$STANDARD_PLIST" perChannelIndicatorEnabled      "$SAVED_INDICATOR_STANDARD"
    restore_bool_default  "$STANDARD_PLIST" debugRPCEnabled                  "$SAVED_RPC_STANDARD"
    bootout_stale_launchctl
}
trap cleanup EXIT

# --- 1. Build + deploy ------------------------------------------------------

# Delegated to e2e-app.sh, the way e2e-browser.sh does it: that script owns the
# deploy path and the re-signing that keeps the runner's TCC grant applicable,
# and a second copy of it here would drift from the original the first time
# either changed.
if [ "$NO_BUILD" = false ]; then
    echo "▸ Building + deploying the dev bundle…"
    "$ROOT/scripts/e2e-app.sh" --redeploy-only || die "build/deploy failed"
    echo "▸ Building mt-cli…"
    (cd "$ROOT/tools/mt-cli" && swift build > /dev/null) || die "mt-cli build failed"
    echo "▸ Building meeting-simulator…"
    (cd "$ROOT/tools/meeting-simulator" && swift build -c release > /dev/null) \
        || die "meeting-simulator build failed"
fi

for path in "$BIN" "$MTCLI" "$SIM" "$NOISE"; do
    [ -x "$path" ] || die "required binary missing: $path — run without --no-build first"
done

# --- 2. Kill any running instance -------------------------------------------

quit_running_app "$BUNDLE_ID"

# --- 3. Snapshot + override defaults so the test is deterministic -----------

# After the running instance is gone, not before. A live app holds its settings
# in memory and writes them back as it quits, so a write followed by a quit is
# undone by the quit: the lane wrote a 30 s window, the departing instance
# restored 90, and every wait below then raced a threshold three times longer
# than it believed. `e2e-app.sh` has always quit first; this lane inherited the
# other order from `e2e-silent-recording.sh`, which has the same defect.

if [ -f "$CONTAINER_PLIST" ]; then
    SAVED_AUTOWATCH_CONTAINER="$(snapshot_default "$CONTAINER_PLIST" autoWatch)"
    SAVED_THRESHOLD_CONTAINER="$(snapshot_default "$CONTAINER_PLIST" asymmetricSilenceWarningSeconds)"
    SAVED_INDICATOR_CONTAINER="$(snapshot_default "$CONTAINER_PLIST" perChannelIndicatorEnabled)"
    SAVED_RPC_CONTAINER="$(snapshot_default "$CONTAINER_PLIST" debugRPCEnabled)"
fi
SAVED_AUTOWATCH_STANDARD="$(snapshot_default "$STANDARD_PLIST" autoWatch)"
SAVED_THRESHOLD_STANDARD="$(snapshot_default "$STANDARD_PLIST" asymmetricSilenceWarningSeconds)"
SAVED_INDICATOR_STANDARD="$(snapshot_default "$STANDARD_PLIST" perChannelIndicatorEnabled)"
SAVED_RPC_STANDARD="$(snapshot_default "$STANDARD_PLIST" debugRPCEnabled)"

set_dev_default autoWatch                       true              bool
set_dev_default asymmetricSilenceWarningSeconds "$WINDOW_SECONDS" float
set_dev_default perChannelIndicatorEnabled      true              bool
# Through the setting rather than the environment, because the app has to be
# started with `open` (see below) and that carries no environment through.
set_dev_default debugRPCEnabled                 true              bool

# --- 4. Launch app with RPC enabled -----------------------------------------

# `open`, not the binary directly. Launching the executable makes the app a
# child of whatever started this lane, and TCC attributes a microphone request
# to the *responsible* process up that chain: under CI that is the runner
# agent, which holds no microphone grant, so the app is refused without being
# told and every buffer arrives full of zeroes. `open` hands the launch to
# launchd, the app becomes its own responsible process, and the grant recorded
# against the bundle is the one that applies. This is why `e2e-app.sh` launches
# this way and why its microphone works; copying the direct launch from
# `e2e-silent-recording.sh` is what made this lane report a zeroed channel on
# the runner for a day.
open "$DEV_BUNDLE_DEPLOY"

echo "▸ Waiting for RPC on 127.0.0.1:9876…"
wait_for_rpc "$MTCLI" 30 || die "RPC server did not start within 30 s"
echo "  RPC up"

# Ask the app what window it is using, rather than reading the file it was
# supposed to read. Those are different questions, and the difference cost a
# night: the plist said 30 while every timing in the lane behaved like 90, the
# default. A preferences write that the app does not pick up looks exactly like
# a lane that is too impatient.
APP_WINDOW="$("$MTCLI" state 2>/dev/null | jq -r '.settings.recording.asymmetricSilenceWarningSeconds // -1')"
[ "${APP_WINDOW%%.*}" = "$WINDOW_SECONDS" ] \
    || die "the app is using a ${APP_WINDOW}s window, not ${WINDOW_SECONDS}s — the preferences write did not reach it, so every wait below would be racing a threshold three times longer than it thinks"

# --- 5. Start the quiet producer BEFORE the meeting -------------------------

# Before, so the microphone track is already alive when the recording opens.
# Starting it afterwards would leave an opening stretch of true zeroes that
# could reach the window on its own and report before phase 1 asserts.
# Prove the loopback carries before anything depends on it. The player plays
# into the device and captures from it in the same run, so this answers "does
# this host's loopback work" without involving the app at all. It reports three
# outcomes, and the third is the reason it exists: exit 4 means the loopback was
# genuinely empty, exit 3 means the capture side was not authorised and the
# question stays open, which is not the same thing and must not read as one.
echo "▸ Checking the loopback on \"$NOISE_DEVICE\"…"
set +e
"$NOISE" --device "$NOISE_DEVICE" --dbfs "$NOISE_DBFS" --seconds 4 --verify
VERIFY_STATUS=$?
set -e
case "$VERIFY_STATUS" in
    0) echo "  loopback carries" ;;
    3) echo "  inconclusive: this process may not capture. Continuing; the app has its own grant." ;;
    4) die "\"$NOISE_DEVICE\" carried nothing back while being played into — the lane cannot test anything on this host" ;;
    *) die "loopback check failed with status $VERIFY_STATUS" ;;
esac

echo "▸ Playing ${NOISE_DBFS} dBFS noise into \"$NOISE_DEVICE\"…"
"$NOISE" --device "$NOISE_DEVICE" --dbfs "$NOISE_DBFS" &
NOISE_PID=$!
sleep 2
kill -0 "$NOISE_PID" 2>/dev/null \
    || die "noise player exited immediately — is \"$NOISE_DEVICE\" installed? (brew install blackhole-2ch)"

# --- 6. Trigger an audible meeting ------------------------------------------

# Audible and looping: the app track has to carry speech for the whole run,
# because digital silence on the microphone is only reported while the other
# channel proves the recording is capturing something. Without --loop the
# fixture would end mid-lane and take the meeting with it.
echo "▸ Launching meeting-simulator (audible, looping, ${SIM_SECONDS} s)…"
"$SIM" --loop --duration="$SIM_SECONDS" &
SIM_PID=$!

echo "▸ Waiting for the app to detect and start recording (max 40 s)…"
_recording_started() {
    assert_app_alive
    local state; state="$("$MTCLI" state 2>/dev/null || echo '{}')"
    [ "$(echo "$state" | jq -r '.watchState // ""')" = "recording" ]
}
poll_until 40 1 _recording_started || die "app never entered the recording state"
echo "  recording"

# --- 7. Phase 1: a live but quiet microphone must not be reported -----------

# First: is the noise actually reaching the capture layer? Everything after this
# reads the microphone track as evidence about the app, so a track that never
# received the noise would be blamed on the code. The first run of this lane
# failed exactly that way, reporting "a channel delivering real samples was
# reported as broken" when the truth was that no real samples were arriving.
echo "▸ Phase 1: confirming the noise reaches the microphone track…"
_mic_carries_energy() {
    assert_app_alive
    local state; state="$("$MTCLI" state 2>/dev/null || echo '{}')"
    local age; age="$(echo "$state" | jq -r '.channelHealth.micSecondsSinceLastEnergy // -1')"
    awk "BEGIN { exit !($age >= 0 && $age < 5) }"
}
if ! poll_until 30 2 _mic_carries_energy; then
    # Two different findings share this symptom, and naming the wrong one has
    # already cost two rounds. If this process was itself refused the
    # microphone, the app almost certainly was too: TCC zeroes an unauthorised
    # client rather than refusing it, so buffers keep arriving full of silence
    # and every layer above reports a channel that is delivering nothing. That
    # is a host that cannot run this lane, not a lane that found something.
    # Being refused the microphone says nothing on its own: a shell script has
    # no grant of its own, which is normal in CI. What separates the two cases
    # is whether the APP may capture, and its own health check answers that.
    APP_MIC_STATE="$("$MTCLI" state 2>/dev/null | jq -r '.permissionHealth.microphone // "unknown"')"
    echo "Final channel health:" >&2
    "$MTCLI" state 2>/dev/null | jq '.channelHealth' >&2 || true
    echo "Recording settings:" >&2
    "$MTCLI" state 2>/dev/null | jq '.settings.recording | {micDeviceUID, micName}' >&2 || true
    echo "Default input device:" >&2
    system_profiler SPAudioDataType 2>/dev/null | grep -B6 "Default Input Device: Yes" >&2 || true
    if [ "$APP_MIC_STATE" != "healthy" ]; then
        die "the microphone is being zeroed on this host: the app reports microphone=$APP_MIC_STATE, so its capture is silenced rather than refused. Grant Microphone to the deployed dev app in the runner GUI session; this is not a finding about the app under test"
    fi
    die "the app may capture (microphone=healthy) and its track still carries no energy, so the noise is not reaching \"$NOISE_DEVICE\" from a process started this way. The same player reaches the same device when started from a login session, so suspect the audio context this lane runs in, not the app"
fi
echo "  the track is alive"

# Event-based rather than a fixed sleep: detection latency varies by several
# seconds, and asserting at a wall-clock offset would race it.
echo "▸ Phase 1: waiting for the silence episode to latch…"
# Traces while it waits. The end state alone cannot tell "the episode never
# started" from "it started and something kept resetting it", and those have
# different causes: the first points at the topology or the thresholds, the
# second at a channel switch or a recording that restarted underneath.
EPISODE_TICK=0
_mic_episode_latched() {
    assert_app_alive
    local state; state="$("$MTCLI" state 2>/dev/null || echo '{}')"
    EPISODE_TICK=$((EPISODE_TICK + 1))
    if [ $((EPISODE_TICK % 5)) -eq 1 ]; then
        echo "    $(echo "$state" | jq -r '"watch=\(.watchState // "-") micSilent=\(.channelHealth.micSilent) appSilent=\(.channelHealth.appSilent) recSilent=\(.channelHealth.recordingSilent) mic=\(.channelHealth.micLevelDBFS // -999 | floor) app=\(.channelHealth.appLevelDBFS // -999 | floor)"')"
    fi
    [ "$(echo "$state" | jq -r '.channelHealth.micSilent // false')" = "true" ]
}
# Three windows, not one plus a little. The episode does not start when the
# recording does: it starts at the first tick where the microphone is under the
# silence threshold AND the app track is over the speech threshold, and the
# fixture opens below it. Replaying the levels observed on the runner through
# the monitor latches after 40 s against a 30 s window, so a 60 s wait was
# racing the very thing it was waiting for.
if ! poll_until $((WINDOW_SECONDS * 3)) 2 _mic_episode_latched; then
    # The levels are what decide latching, so they are what this failure has to
    # show. Both sides can prevent it and they call for opposite fixes: a
    # microphone above the silence threshold means the noise is too loud, an
    # app track below the speech threshold means the far side is not being
    # captured at all, which is not a statement about this lane's subject.
    STATE="$("$MTCLI" state 2>/dev/null || echo '{}')"
    MIC_LEVEL="$(echo "$STATE" | jq -r '.channelHealth.micLevelDBFS // -999')"
    APP_LEVEL="$(echo "$STATE" | jq -r '.channelHealth.appLevelDBFS // -999')"
    echo "Final channel health:" >&2
    echo "$STATE" | jq '.channelHealth' >&2 || true
    if awk "BEGIN { exit !($APP_LEVEL < -50) }"; then
        die "the app track is at ${APP_LEVEL} dBFS, below the -50 dBFS speech threshold, so no asymmetry can arise however quiet the microphone is. The fixture is playing; if the tap is not capturing it, that is a capture problem on this host, not a finding about the channel-fault path"
    fi
    if awk "BEGIN { exit !($MIC_LEVEL > -60) }"; then
        die "the microphone is at ${MIC_LEVEL} dBFS, above the -60 dBFS silence threshold, so the episode cannot latch. Lower ${NOISE_DBFS} dBFS further, or check what else is feeding \"$NOISE_DEVICE\""
    fi
    die "the asymmetric-silence episode never latched (mic ${MIC_LEVEL} dBFS, app ${APP_LEVEL} dBFS) — the pre-fix trigger condition did not occur, so this run proves nothing"
fi

STATE="$("$MTCLI" state)"
MIC_FAULT="$(echo "$STATE" | jq -r '.channelHealth.micFault // "null"')"
MIC_ENERGY_AGE="$(echo "$STATE" | jq -r '.channelHealth.micSecondsSinceLastEnergy // -1')"
SILENT_NOTIFICATIONS="$(echo "$STATE" | jq '[.notifications[]? | select(.title == "Capture Channel Silent")] | length')"

[ "$MIC_FAULT" = "null" ] \
    || die "phase 1: micFault=$MIC_FAULT — a channel delivering real samples was reported as broken"
awk "BEGIN { exit !($MIC_ENERGY_AGE >= 0 && $MIC_ENERGY_AGE < 5) }" \
    || die "phase 1: micSecondsSinceLastEnergy=$MIC_ENERGY_AGE — the noise is not reaching the capture layer, so the phase asserts nothing"
[ "$SILENT_NOTIFICATIONS" = "0" ] \
    || die "phase 1: $SILENT_NOTIFICATIONS 'Capture Channel Silent' notification(s) for a live microphone — this is the issue #614 regression"

echo "  micSilent=true (tint latched), micFault=null, energy age=${MIC_ENERGY_AGE}s, no notification"

# --- 8. Phase 2: the same channel, now delivering zeroes --------------------

echo "▸ Phase 2: stopping the noise, the microphone track goes to digital silence…"
kill -TERM "$NOISE_PID" 2>/dev/null || true
wait "$NOISE_PID" 2>/dev/null || true
NOISE_PID=""

# Traced like phase 1, and for the same reason. The end state shows the two
# microphone ages satisfied and no fault, which leaves corroboration as the
# only remaining condition: digital silence is reported only while the OTHER
# channel carried speech inside the window. Whether it did is a property of the
# fixture over time, not of the final frame.
FAULT_TICK=0
_mic_fault_reported() {
    assert_app_alive
    local state; state="$("$MTCLI" state 2>/dev/null || echo '{}')"
    FAULT_TICK=$((FAULT_TICK + 1))
    if [ $((FAULT_TICK % 5)) -eq 1 ]; then
        echo "    $(echo "$state" | jq -r '"watch=\(.watchState // "-") micFault=\(.channelHealth.micFault // "none") appFault=\(.channelHealth.appFault // "none") micSilent=\(.channelHealth.micSilent) micEnergyAge=\(.channelHealth.micSecondsSinceLastEnergy // -1 | floor) app=\(.channelHealth.appLevelDBFS // -999 | floor) job=\(.lastJob.jobID // "-" | .[0:8])"') sim=$(pgrep -f meeting-simulator >/dev/null && echo up || echo gone)"
    fi
    [ "$(echo "$state" | jq -r '.channelHealth.micFault // "null"')" = "digitalSilence" ]
}
if ! poll_until $((WINDOW_SECONDS * 3)) 2 _mic_fault_reported; then
    echo "Final state:" >&2
    "$MTCLI" state 2>/dev/null | jq '.channelHealth, .watchState' >&2 || true
    die "phase 2: micFault never became digitalSilence — a channel delivering nothing but zeroes went unreported"
fi

STATE="$("$MTCLI" state)"
APP_FAULT="$(echo "$STATE" | jq -r '.channelHealth.appFault // "null"')"
MIC_ENERGY_AGE="$(echo "$STATE" | jq -r '.channelHealth.micSecondsSinceLastEnergy // -1')"
MIC_BUFFER_AGE="$(echo "$STATE" | jq -r '.channelHealth.micSecondsSinceLastBuffer // -1')"
SILENT_NOTIFICATIONS="$(echo "$STATE" | jq '[.notifications[]? | select(.title == "Capture Channel Silent")] | length')"
SILENT_BODY="$(echo "$STATE" | jq -r '[.notifications[]? | select(.title == "Capture Channel Silent")][0].body // ""')"

[ "$SILENT_NOTIFICATIONS" = "1" ] \
    || die "phase 2: expected exactly one 'Capture Channel Silent', got $SILENT_NOTIFICATIONS"
case "$SILENT_BODY" in
    *"delivering silence"*) ;;
    *) die "phase 2: the notification does not carry the digital-silence wording: $SILENT_BODY" ;;
esac
[ "$APP_FAULT" = "null" ] \
    || die "phase 2: appFault=$APP_FAULT — the app track was carrying the fixture and must stay healthy"
awk "BEGIN { exit !($MIC_ENERGY_AGE >= $WINDOW_SECONDS) }" \
    || die "phase 2: micSecondsSinceLastEnergy=$MIC_ENERGY_AGE, below the window — the verdict does not match its own evidence"
# Buffers must still be arriving: that is what separates a muted device from a
# dead one, and reporting the wrong one sends the user after the wrong fix.
awk "BEGIN { exit !($MIC_BUFFER_AGE >= 0 && $MIC_BUFFER_AGE < 5) }" \
    || die "phase 2: micSecondsSinceLastBuffer=$MIC_BUFFER_AGE — the device stopped delivering entirely, which is noBuffers, not digitalSilence"

echo "  micFault=digitalSilence, buffer age=${MIC_BUFFER_AGE}s, energy age=${MIC_ENERGY_AGE}s, one notification"

echo
echo "OK — the capture-fault chain is verified end to end:"
echo "  live but quiet microphone  → tint, no notification"
echo "  same channel, zeroes only  → digitalSilence, one notification"
echo "  app track throughout       → healthy"
