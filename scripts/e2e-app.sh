#!/usr/bin/env bash
# Live-recording E2E driver for the Meeting Transcriber dev app.
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

APP_AFTER=quit           # quit | leave
SIMULATOR_FIXTURE=""     # custom audio fixture for the simulator
NO_BUILD=false           # skip build/deploy/re-sign — use whatever's at ~/Applications already
TWO_MEETINGS=false       # trigger two back-to-back meetings to validate cooldown + state reset
MIC_ONLY=false           # drive a microphone-only recording over /v1/record and assert its sidecar
RECORD_ONLY=false        # validate record-only mode (sidecar+WAV instead of transcript)
REIMPORT_RECORDED=false  # chain a record-only meeting with re-import via POST /action/enqueueFile
REIMPORT_LATEST=false    # skip live-record phase, re-import the freshest *_mix.wav already on disk
KEEP_RECORDINGS=false    # leave record-only output on disk for a follow-up --reimport-latest run
MIC_DEVICE_CHANGE=false  # build the issue #379 fault-injection seam + assert the app survives it
CRASH_RECOVERY=false     # kill mid-recording + assert the orphan is recovered into the pipeline on relaunch (issue #379 part 3)
REDEPLOY_ONLY=false      # rebuild + redeploy the canonical (non-fault) bundle and exit — restores a clean bundle after --mic-device-change
NAMING_CONFIRM=false     # drive the speaker-naming CONFIRM path end-to-end via POST /v1/jobs/<id>/naming (see run_naming_confirm)
NAMING_ESCAPE=false      # press a real Escape on the naming dialog + assert it dismisses without resolving (issue #577)
TITLE_SOURCE=false       # drive the window-title lookup with a no-usable-title case + assert the clean placeholder (issue #501 title source)
ECHO_BLEED=false         # feed a synthesised affected + clean pair through /v1/jobs and assert the echo verdict (see run_echo_bleed)

while [ $# -gt 0 ]; do
    case "$1" in
        --quit-app)         APP_AFTER=quit ;;     # explicit alias for the default
        --keep-app)         APP_AFTER=leave ;;
        --no-build)         NO_BUILD=true ;;
        --fixture)          shift; SIMULATOR_FIXTURE="$1" ;;
        --two-meetings)     TWO_MEETINGS=true ;;
        --mic-only)         MIC_ONLY=true ;;
        --record-only)      RECORD_ONLY=true ;;
        --reimport-recorded) REIMPORT_RECORDED=true ;;
        --reimport-latest)  REIMPORT_LATEST=true ;;
        --keep-recordings)  KEEP_RECORDINGS=true ;;
        --mic-device-change) MIC_DEVICE_CHANGE=true ;;
        --crash-recovery)   CRASH_RECOVERY=true ;;
        --redeploy-only)    REDEPLOY_ONLY=true ;;
        --naming-confirm)   NAMING_CONFIRM=true ;;
        --naming-escape)    NAMING_ESCAPE=true ;;
        --title-source)     TITLE_SOURCE=true ;;
        --echo-bleed)       ECHO_BLEED=true ;;
        -h|--help)
            cat <<'HELP'
Usage: e2e-app.sh [--no-build] [--keep-app] [--two-meetings] [--record-only]
                  [--reimport-recorded | --reimport-latest] [--keep-recordings]
                  [--naming-escape] [--echo-bleed]
                  [--naming-confirm] [--fixture path/to.wav]

  --no-build           Skip build/deploy/re-sign; use ~/Applications/MeetingTranscriber-Dev.app as-is.
  --keep-app           Leave the dev app running on exit. Default: quit it.
  --two-meetings       Run two meetings back-to-back (cooldown + state-reset coverage).
  --mic-only           Record the microphone with no app audio (issue #633) via
                       POST /v1/record, and assert the sidecar carries a mic track
                       and NO app track. Reroutes the default OUTPUT to BlackHole
                       2ch for the lane's duration so the loopback input has
                       something to hear, and restores it on any exit.
  --record-only        Enable record-only mode: assert on sidecar JSON + mix WAV instead
                       of transcript/protocol. Exercises the WatchLoop branch that
                       skips VAD/transcription/diarization/protocol generation.
  --reimport-recorded  Chain a record-only meeting with a re-import via the
                       POST /action/enqueueFile RPC: capture audio live, write
                       a WAV, then feed that WAV back in through the "Open from
                       Recording" pipeline and assert the transcript. Covers
                       both the recorder's WAV-encoding correctness and the
                       AudioMixer 3-tier file-load fallback in one pass.
                       Self-contained — no prior run required.
  --reimport-latest    Skip the live-record phase and re-import the freshest
                       *_mix.wav already in ~/Downloads/MeetingTranscriber/recordings/.
                       Pair with a previous `--record-only --keep-recordings`
                       run (CI uses this to chain steps without re-recording;
                       locally also useful for silent fast iteration on the
                       import pipeline).
  --keep-recordings    Suppress the on-exit cleanup of record-only output, so
                       a follow-up --reimport-latest can pick the WAV up.
                       Only meaningful with --record-only.
  --mic-device-change  Build with the issue #379 fault-injection seam
                       (-DE2E_FAULT_INJECTION) and run one meeting. The app
                       self-triggers a mic device-change restart mid-recording
                       that installs the tap with an invalid format — the
                       condition that raises an uncatchable NSException from
                       installTapOnBus. Asserts the app SURVIVES (no SIGABRT)
                       and the recording still completes. Pre-fix this crashes;
                       the fix must catch + recover. Requires a build (incompatible
                       with --no-build).
  --crash-recovery     Issue #379 part 3: start a meeting, wait until the
                       recorder is writing its raw app temp, then SIGKILL the
                       app mid-recording (no stop() -> the raw _app16k_raw.tmp +
                       unfinalized _mic.wav survive, no _mix.wav). Relaunch and
                       assert the recovered recording enters the pipeline and a
                       job reaches done (the re-mixed _mix.wav is transient — the
                       pipeline consumes it into its workdir within seconds).
                       Pre-fix the launch cleanup deletes the temp -> no
                       recovery (RED); the fix re-mixes + enqueues it (GREEN).
  --redeploy-only      Rebuild + redeploy the canonical (non-fault-injection)
                       bundle to ~/Applications/MeetingTranscriber-Dev.app and
                       exit without launching or running a meeting. Used as an
                       always() cleanup after --mic-device-change to restore a
                       clean bundle (that run leaves a deliberately-crashing
                       fault-injection build deployed). Requires a build
                       (incompatible with --no-build and --mic-device-change).
  --naming-confirm     Drive the speaker-naming CONFIRM path end-to-end. Enqueues
                       the 2-speaker fixture with diarization on and expected
                       speakers = 2 via POST /v1/jobs, waits for the job to park
                       at speaker-naming (does NOT auto-skip like the other
                       lanes), reads GET /v1/jobs/<id>/naming, POSTs an anonymous
                       Speaker A / Speaker B mapping, then asserts the confirmed
                       names land as transcript speaker labels, the raw
                       diarization labels are gone, and the speaker DB learned the
                       voices. Standalone lane (incompatible with the other lane
                       flags). Under CI it snapshots + restores the runner's real
                       speakers.json / recognition_log.jsonl so confirming never
                       pollutes the persistent speaker DB; that snapshot/restore
                       is $GITHUB_ACTIONS-gated, so a LOCAL run enrolls voices
                       into your real speaker DB (a warning is printed).
  --title-source       Issue #501: run meeting-simulator with a window title equal
                       to the app name (no usable meeting-window title), then assert
                       the detected meeting title is the clean "MeetingSimulator Call"
                       placeholder — not the raw IOKit assertion name. Fails against
                       the pre-fix detector, so it proves the deployed
                       detection → title-selection chain end-to-end.
  --echo-bleed         Assert the echo-bleed verdict end to end. Synthesises two
                       dual-source pairs from the shipped fixtures — one whose
                       microphone track carries the app track back from the
                       loudspeaker, one clean control differing by exactly that
                       term — enqueues each via POST /v1/jobs, and asserts the
                       verdict on GET /v1/jobs/<id>: detected on the affected
                       pair, present-and-false on the control. The control is
                       what keeps the lane from passing on a detector that says
                       yes to everything. Standalone lane. Needs python3.
                       Leaves two finished jobs and a recognition-log row behind
                       (it skips their naming so nothing stays parked); it never
                       enrolls a voice, so speakers.json is untouched.
  --fixture            Audio fixture for meeting-simulator. Default: two_speakers_de.wav.
HELP
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# --reimport-recorded and --reimport-latest are advertised as alternatives
# in the help text — enforce that here so a typo can't silently fall
# through to whichever branch the dispatch chain checks first.
if [ "$REIMPORT_RECORDED" = true ] && [ "$REIMPORT_LATEST" = true ]; then
    echo "Error: --reimport-recorded and --reimport-latest are mutually exclusive" >&2
    exit 2
fi

# --naming-confirm is a standalone lane (its own enqueue + poll + confirm flow).
# Reject combinations up-front so a typo can't silently fall through to another
# lane's branch in the dispatch chain below.
if [ "$NAMING_ESCAPE" = true ] && { [ "$NAMING_CONFIRM" = true ] || [ "$RECORD_ONLY" = true ] \
    || [ "$REIMPORT_RECORDED" = true ] || [ "$REIMPORT_LATEST" = true ] || [ "$MIC_DEVICE_CHANGE" = true ] \
    || [ "$CRASH_RECOVERY" = true ] || [ "$REDEPLOY_ONLY" = true ] || [ "$TWO_MEETINGS" = true ]; }; then
    echo "Error: --naming-escape is a standalone lane; incompatible with the other lane flags" >&2
    exit 2
fi
if [ "$NAMING_CONFIRM" = true ] && { [ "$RECORD_ONLY" = true ] || [ "$REIMPORT_RECORDED" = true ] \
    || [ "$REIMPORT_LATEST" = true ] || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] \
    || [ "$REDEPLOY_ONLY" = true ] || [ "$TWO_MEETINGS" = true ]; }; then
    echo "Error: --naming-confirm is a standalone lane; incompatible with the other lane flags" >&2
    exit 2
fi
# --naming-confirm always enqueues the known 2-speaker fixture, so a custom
# --fixture would be silently ignored. Reject the combination rather than
# mislead. (SIMULATOR_FIXTURE is only non-empty here when --fixture was passed;
# it defaults to the 2-speaker fixture further below.)
if [ "$NAMING_CONFIRM" = true ] && [ -n "$SIMULATOR_FIXTURE" ]; then
    echo "Error: --naming-confirm ignores --fixture (it always uses the 2-speaker fixture)" >&2
    exit 2
fi
# --mic-only drives its own recording over /v1/record and reroutes the machine's
# audio output; sharing a run with a meeting lane would have the detector start a
# second recording next to it.
if [ "$MIC_ONLY" = true ] && { [ "$RECORD_ONLY" = true ] || [ "$NAMING_CONFIRM" = true ] \
    || [ "$NAMING_ESCAPE" = true ] || [ "$REIMPORT_RECORDED" = true ] || [ "$REIMPORT_LATEST" = true ] \
    || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] || [ "$REDEPLOY_ONLY" = true ] \
    || [ "$TWO_MEETINGS" = true ] || [ "$ECHO_BLEED" = true ] || [ "$TITLE_SOURCE" = true ]; }; then
    echo "Error: --mic-only is a standalone lane; incompatible with the other lane flags" >&2
    exit 2
fi
# --echo-bleed builds its own audio from the shipped fixtures and never records,
# so it shares nothing with the meeting lanes and would only mask a typo.
if [ "$ECHO_BLEED" = true ] && { [ "$NAMING_CONFIRM" = true ] || [ "$NAMING_ESCAPE" = true ] \
    || [ "$RECORD_ONLY" = true ] || [ "$REIMPORT_RECORDED" = true ] || [ "$REIMPORT_LATEST" = true ] \
    || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] || [ "$REDEPLOY_ONLY" = true ] \
    || [ "$TWO_MEETINGS" = true ] || [ "$TITLE_SOURCE" = true ] || [ -n "$SIMULATOR_FIXTURE" ]; }; then
    echo "Error: --echo-bleed is a standalone lane; incompatible with the other lane flags and --fixture" >&2
    exit 2
fi

# --mic-device-change needs the fault-injection seam compiled in, so it must
# build — `defaults`/runtime flags can't add the -DE2E_FAULT_INJECTION code.
if [ "$MIC_DEVICE_CHANGE" = true ] && [ "$NO_BUILD" = true ]; then
    echo "Error: --mic-device-change requires a build; incompatible with --no-build" >&2
    exit 2
fi
# --redeploy-only rebuilds the canonical bundle, so it must build (not --no-build)
# and must NOT carry the fault-injection seam it exists to clean up.
if [ "$REDEPLOY_ONLY" = true ] && [ "$NO_BUILD" = true ]; then
    echo "Error: --redeploy-only rebuilds the bundle; incompatible with --no-build" >&2
    exit 2
fi
if [ "$REDEPLOY_ONLY" = true ] && [ "$MIC_DEVICE_CHANGE" = true ]; then
    echo "Error: --redeploy-only restores the canonical bundle; incompatible with --mic-device-change" >&2
    exit 2
fi
# Export before the build step below so run_app.sh adds -DE2E_FAULT_INJECTION.
if [ "$MIC_DEVICE_CHANGE" = true ]; then
    export MTT_FAULT_INJECTION=1
fi

# --reimport-recorded chains a record-only meeting with a follow-up
# enqueueFile RPC. Phase 1 needs the recordOnly toggle on so WatchLoop
# writes a WAV instead of running the pipeline — flip it on implicitly
# rather than requiring callers to pass both flags.
if [ "$REIMPORT_RECORDED" = true ]; then
    RECORD_ONLY=true
fi

# --- paths ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEV_BUNDLE_BUILD="$ROOT/app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app"
DEV_BUNDLE_DEPLOY="$HOME/Applications/MeetingTranscriber-Dev.app"
SIMULATOR_PKG="$ROOT/tools/meeting-simulator"
SIMULATOR_BIN="$SIMULATOR_PKG/.build/release/meeting-simulator"
MTCLI_PKG="$ROOT/tools/mt-cli"
MTCLI="$MTCLI_PKG/.build/release/mt-cli"
DEFAULT_FIXTURE="$ROOT/app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav"
RPC_TOKEN_FILE="$HOME/Library/Application Support/MeetingTranscriber/.rpc-token"
RPC_BASE="http://127.0.0.1:9876"

# Record-only output lands here — `AppPaths.downloadsProtocolsDir` +
# `/recordings`. Unsandboxed (Homebrew variant) so this is a real path,
# not a container-mapped one.
RECORDINGS_DIR="$HOME/Downloads/MeetingTranscriber/recordings"
# `find -newer` marker so cleanup only touches THIS run's files — never
# pre-existing user data (see CLAUDE.md feedback on destructive FS scans).
RECORD_ONLY_MARKER="/tmp/e2e-app-record-only-marker.$$"

[ -n "$SIMULATOR_FIXTURE" ] || SIMULATOR_FIXTURE="$DEFAULT_FIXTURE"

# Content-assertion keywords for the default two_speakers_de fixture. The
# `run_one_meeting` transcript check greps for these German content words so a
# live-recorded run can't go green on a >100-byte GARBAGE transcript: an empty
# file, a wrong-language hallucination, or silent-capture noise all clear the
# size check but hit zero of these. This list is identical to the xctest E2E's
# `expectedKeywords` (ParakeetE2ETests.swift / WhisperKitE2ETests.swift) and
# must stay in sync with them if the fixture is regenerated. The fixture also
# speaks "Meeting", but neither this list nor the xctest set includes it: it is
# the one English word, so requiring only German words proves the German
# fixture actually transcribed rather than an English hallucination.
# The check itself lives in lib/e2e-helpers.sh as `transcript_is_german` and
# keys on common German words, NOT on the fixture's script. Recording starts
# only once the app has DETECTED the meeting, so the opening seconds are never
# captured and which sentences land shifts run to run; a script-derived list
# therefore measured recording-start timing, not transcription quality.
# Applied only when the simulator plays the known fixture (and not the
# mic-device-change survival lane); a custom --fixture keeps only the
# >100-byte size check.
IS_DEFAULT_FIXTURE=false
[ "$SIMULATOR_FIXTURE" = "$DEFAULT_FIXTURE" ] && IS_DEFAULT_FIXTURE=true

# --- timing budgets -------------------------------------------------------

# Cold first run downloads ~50 MB Parakeet model — give it room. Hot run
# under 10 s easily.
RPC_READY_TIMEOUT_S=30
PIPELINE_TIMEOUT_S=240

# Record-only skips the whole pipeline, so the budget is just: detector
# notices the simulator stopped (~1 s poll) + endGrace (≥1 s) + recorder
# finalize (~3 s) + sidecar write (instant). 60 s gives ample buffer.
RECORD_ONLY_DEADLINE_S=60

# wav-verdict calibration, shared by every lane that asserts a track carries
# signal. The threshold is the analyzer's own silence floor; the active-seconds
# floor is what separates a real capture from a "one second then silence"
# wedge, so it is set against the fixture's measured content (two_speakers_de.wav
# is 49.8 s long and carries 37.5 s above the threshold) rather than at a token
# value that any partial capture would clear.
WAV_VERDICT_THRESHOLD_DBFS=-50
WAV_VERDICT_MIN_ACTIVE_S=3
WAV_VERDICT_FIXTURE_MIN_ACTIVE_S=25

# Sidecar write completes before the recorder's async tail bytes do — give
# the WAV's AVAudioFile close a moment before re-feeding it to the engine.
# Observed worst case on Mini is ~1 s; 2 s is honest margin.
RECORDER_FINALIZE_WAIT_S=2

# WatchLoop's per-app cooldown (`MeetingDetector.swift` cooldownDuration
# = 5 s) plus a 3 s buffer so the second meeting isn't suppressed as a
# re-detection. Bump if MeetingDetector.cooldownDuration grows.
INTER_MEETING_COOLDOWN_S=8

# --- helpers --------------------------------------------------------------

log()  { printf '[e2e-app] %s\n' "$*"; }
fail() { printf '[e2e-app] FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/e2e-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/e2e-helpers.sh"

require_command() {
    command -v "$1" >/dev/null || fail "missing command: $1"
}

RPC_TOKEN=""  # populated once when the token file appears

# Returns empty string + exit 0 on transient curl failure so callers in
# `set -e` poll loops keep going. 15 s timeout covers brief main-thread
# blocks during model load + audio teardown.
rpc() {
    local path="$1"
    curl --silent --show-error --max-time 15 \
        --header "Authorization: Bearer $RPC_TOKEN" \
        "$RPC_BASE$path" 2>/dev/null || true
}


# --- Mic-only lane: audio routing ------------------------------------------
#
# The lane needs one invariant that no default configuration guarantees: the
# default INPUT must be a loopback of the default OUTPUT, so that playing a
# fixture is the same as speaking into the microphone. It arranges the second
# half itself, pointing the default output at the loopback device for its own
# duration, and asserts the first half in its preflight rather than assuming it.
#
# Why it is needed at all, measured 2026-08-18: with the output on the speakers,
# four mic tracks sampled from earlier runs on this host each read -120 dBFS
# (a sample, not a census), while the analyzer reports -22 dBFS for the shipped
# fixture. With the output routed into the loopback this lane records -22 dBFS.
# The app track is unaffected either way because it comes from the CATap, which
# reads process output and touches no device at all.
#
# Restoring the routing matters more than setting it. A machine left on the
# loopback goes silent AND records, on every later dual-source lane, a mic track
# that is a bit-perfect copy of the app track. That is textbook echo bleed: it
# would skew the echo detector on runs that have nothing to do with this lane,
# and no lane asserts against it, so CI would stay green while the meaning of
# every recording quietly changed. Hence:
#
#   - the marker is written BEFORE the switch, so a kill can never strand the
#     machine with no record of where to go back to;
#   - it is deleted only AFTER the restore has been verified by re-reading the
#     device, so a restore that fails keeps its own repair instructions;
#   - it carries the owning PID, so a concurrent run heals a dead run's marker
#     and never steals a live one;
#   - the self-heal runs before every early exit, not just before the lane.
_MIC_ONLY_DEVICE="BlackHole 2ch"
_MIC_ONLY_OUTPUT_MARKER="$HOME/Library/Application Support/MeetingTranscriber/.e2e-mic-only-previous-output"

# Read the current default output, or empty on failure.
_mic_only_current_output() {
    SwitchAudioSource -c -t output 2>/dev/null || true
}

_mic_only_switch_output() {
    local previous
    previous="$(_mic_only_current_output)"
    [ -n "$previous" ] || fail "[mic-only] could not read the current default output device"
    # No benign "already on the loopback" path: on this host that is never a
    # resting state, it is the signature of a previous run that failed to
    # restore, and skipping would hide exactly the damage this file guards.
    [ "$previous" != "$_MIC_ONLY_DEVICE" ] \
        || fail "[mic-only] default output is already $_MIC_ONLY_DEVICE, which means an earlier run never restored it; fix the machine's audio output before re-running"
    mkdir -p "$(dirname "$_MIC_ONLY_OUTPUT_MARKER")"
    # PID first so a reader can tell a live owner from a dead one; the device
    # name may contain spaces, so it takes the whole rest of the line.
    printf '%s %s' "$$" "$previous" >"$_MIC_ONLY_OUTPUT_MARKER"
    SwitchAudioSource -t output -s "$_MIC_ONLY_DEVICE" >/dev/null \
        || fail "[mic-only] could not set default output to $_MIC_ONLY_DEVICE"
    local now
    now="$(_mic_only_current_output)"
    [ "$now" = "$_MIC_ONLY_DEVICE" ] \
        || fail "[mic-only] default output is '$now' after switching; expected $_MIC_ONLY_DEVICE"
    log "[mic-only] default output $previous -> $_MIC_ONLY_DEVICE (restores on exit)"
}

# Restore and only then forget. $1 = "trap" when called from the exit trap,
# where a failure must warn rather than mask the run's real status; any other
# caller gets a hard failure, because a self-heal that cannot repair the machine
# must stop the run rather than hand the next lane a poisoned device.
_mic_only_restore_output() {
    local mode="${1:-trap}"
    [ -f "$_MIC_ONLY_OUTPUT_MARKER" ] || return 0
    local raw owner previous now
    raw="$(cat "$_MIC_ONLY_OUTPUT_MARKER" 2>/dev/null || true)"
    owner="${raw%% *}"
    previous="${raw#* }"
    if [ -z "$raw" ] || [ -z "$previous" ] || [ "$owner" = "$raw" ]; then
        _mic_only_report "$mode" "[mic-only] output marker is unreadable ('$raw'); set the default output by hand"
        return 0
    fi
    if ! SwitchAudioSource -t output -s "$previous" >/dev/null 2>&1; then
        _mic_only_report "$mode" "[mic-only] could not restore default output to '$previous' (device gone?); marker kept at $_MIC_ONLY_OUTPUT_MARKER"
        return 0
    fi
    now="$(_mic_only_current_output)"
    if [ "$now" != "$previous" ]; then
        _mic_only_report "$mode" "[mic-only] default output is '$now' after restoring; expected '$previous'; marker kept"
        return 0
    fi
    # Verified: only now is the marker safe to drop.
    rm -f "$_MIC_ONLY_OUTPUT_MARKER"
    log "[mic-only] default output restored to $previous"
}

_mic_only_report() {
    local mode="$1" message="$2"
    if [ "$mode" = "trap" ]; then
        log "WARNING: $message"
    else
        fail "$message"
    fi
}

# Startup self-heal, run by every invocation of this script before any lane can
# record. Only acts on a marker whose owner is gone: a live owner means another
# run holds the routing, and restoring it under that run would both break it and
# strand the machine once it switches again.
_mic_only_self_heal_output() {
    [ -f "$_MIC_ONLY_OUTPUT_MARKER" ] || return 0
    local owner
    owner="$(cut -d' ' -f1 <"$_MIC_ONLY_OUTPUT_MARKER" 2>/dev/null || true)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        fail "[mic-only] another run (pid $owner) currently holds the audio routing; wait for it to finish"
    fi
    log "[mic-only] leftover output-routing marker from a dead run detected; self-healing"
    _mic_only_restore_output heal
}

# Heal a dead run's routing before anything else happens on this machine.
# Deliberately here and not after the traps: `--redeploy-only` and every
# preflight `fail` exit long before those, and the marker they would leave
# unhealed poisons the mic track of every later lane on this host.
_mic_only_self_heal_output

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

# Always — even with --no-build, since UserDefaults below take effect
# only on launch and the running RPC server would shadow the new one.
quit_running_app

if [ "$NO_BUILD" = true ]; then
    [ -d "$DEV_BUNDLE_DEPLOY" ] || fail "--no-build given but $DEV_BUNDLE_DEPLOY doesn't exist — deploy a signed bundle there first"
    log "Skipping build/deploy/re-sign — using existing $DEV_BUNDLE_DEPLOY"
else
    log "Building dev .app bundle"
    "$SCRIPT_DIR/run_app.sh" --build-only

    log "Deploying to $DEV_BUNDLE_DEPLOY"
    mkdir -p "$(dirname "$DEV_BUNDLE_DEPLOY")"
    # rsync into the existing bundle dir — TCC keys off the bundle path,
    # so a delete+copy would invalidate granted permissions.
    if [ -d "$DEV_BUNDLE_DEPLOY" ]; then
        rsync -a --delete "$DEV_BUNDLE_BUILD/" "$DEV_BUNDLE_DEPLOY/"
    else
        cp -R "$DEV_BUNDLE_BUILD" "$DEV_BUNDLE_DEPLOY"
    fi

    # Re-sign with our stable identity. run_app.sh signs with whatever
    # `find-identity -v | head -1` returns (often ad-hoc on CI hosts), so
    # without re-signing TCC would see a different cert SHA on every
    # rebuild and lose the grant. CI path uses the imported Developer ID;
    # local-dev path falls back to the self-signed cert from
    # setup-self-hosted-runner.sh. resign_deployed_bundle carries the dev
    # entitlements through that re-sign, and skips it entirely when the build
    # already used this certificate — a bare codesign would silently strip both
    # the microphone and the time-sensitive entitlement (issue #609).
    if [ -n "${DEVELOPER_ID:-}" ]; then
        log "Re-signing $DEV_BUNDLE_DEPLOY with Developer ID '$DEVELOPER_ID'"
        # Re-assert the signing keychain right before codesign — a parallel
        # job on the Mini's other runner (shared OS user) may have mutated
        # the user search list during our 60–90 s build. codesign honours
        # `--keychain` for the signing identity but still consults the
        # search list for trust-chain resolution.
        if [ -n "${E2E_SIGNING_KEYCHAIN:-}" ]; then
            "$SCRIPT_DIR/keychain-prepend.sh" "$E2E_SIGNING_KEYCHAIN"
        fi
        resign_deployed_bundle "$DEV_BUNDLE_DEPLOY" "$DEVELOPER_ID" "${E2E_SIGNING_KEYCHAIN:-}" \
            || fail "codesign with Developer ID failed — check DEVELOPER_ID + E2E_SIGNING_KEYCHAIN env vars"
    else
        DEV_CERT_HASH="$(dev_signing_identity)"
        [ -n "$DEV_CERT_HASH" ] \
            || fail "no Developer ID and no '$DEV_CERT_NAME' identity in $DEV_KEYCHAIN — set DEVELOPER_ID env or run scripts/setup-self-hosted-runner.sh first"
        log "Re-signing $DEV_BUNDLE_DEPLOY with self-signed dev cert ($DEV_CERT_HASH)"
        resign_deployed_bundle "$DEV_BUNDLE_DEPLOY" "$DEV_CERT_HASH" "$DEV_KEYCHAIN" \
            || fail "codesign with dev cert failed — try re-running scripts/setup-self-hosted-runner.sh"
    fi
fi

# --redeploy-only stops here: the canonical bundle is rebuilt + deployed +
# signed above, which is the whole job. Don't launch, don't run a meeting.
# This is the always() cleanup the --mic-device-change workflow runs to leave
# a clean (non-fault-injection) bundle at the shared deploy path.
if [ "$REDEPLOY_ONLY" = true ]; then
    log "Redeployed the canonical (non-fault-injection) bundle to $DEV_BUNDLE_DEPLOY; exiting (--redeploy-only)"
    exit 0
fi

if [ ! -x "$SIMULATOR_BIN" ]; then
    log "Building meeting-simulator"
    (cd "$SIMULATOR_PKG" && swift build -c release)
fi

# Record-only lanes assert the captured app track is non-silent via
# `mt-cli wav-verdict` (the same analyzer the browser lane uses). Only that
# mode needs it, so build lazily to keep the processing lane unchanged.
if { [ "$RECORD_ONLY" = true ] || [ "$MIC_ONLY" = true ]; } && [ ! -x "$MTCLI" ]; then
    # record-only asserts the app track carries signal; mic-only needs the same
    # analyzer for its mic track AND drives `record start/stop` through it.
    log "Building mt-cli (track silence guard + record control)"
    (cd "$MTCLI_PKG" && swift build -c release) || fail "mt-cli build failed"
fi

if [ "$MIC_ONLY" = true ]; then
    command -v SwitchAudioSource >/dev/null 2>&1 \
        || fail "--mic-only needs SwitchAudioSource to route the default output into the loopback input: brew install switchaudio-osx"
    SwitchAudioSource -a -t output 2>/dev/null | grep -qx "$_MIC_ONLY_DEVICE" \
        || fail "--mic-only needs $_MIC_ONLY_DEVICE as an output device: brew install blackhole-2ch (then reboot or restart coreaudiod)"
    # The lane's actual premise, asserted rather than assumed: it feeds the
    # default OUTPUT, and only a default input that loops that back turns the
    # fixture into captured microphone audio. Without this check a host with a
    # real default microphone silences its speakers, records the room, and
    # fails 60 s later with a message blaming microphone capture.
    _MIC_ONLY_INPUT="$(SwitchAudioSource -c -t input 2>/dev/null || true)"
    [ "$_MIC_ONLY_INPUT" = "$_MIC_ONLY_DEVICE" ] \
        || fail "--mic-only needs the default INPUT to be $_MIC_ONLY_DEVICE (the loopback it routes the output into), but it is '$_MIC_ONLY_INPUT'. Set it in System Settings > Sound, or unplug the device that took over."
fi

# `autoWatch` triggers the same `.autoWatchStart` notification an
# explicit "Start Watching" menu click would — necessary because that
# menu isn't reachable over SSH. `debugRPCEnabled` brings the RPC up at
# launch instead of after a Settings toggle.
defaults write "$DEV_BUNDLE_ID" debugRPCEnabled -bool true
defaults write "$DEV_BUNDLE_ID" autoWatch -bool true

if [ "$MIC_ONLY" = true ]; then
    # Record-only so the lane needs no ASR models, and auto-watch OFF so nothing
    # detects a meeting and starts a second recording next to the manual one.
    log "Enabling record-only mode and disabling auto-watch for the mic-only lane"
    defaults write "$DEV_BUNDLE_ID" recordOnly -bool true
    defaults write "$DEV_BUNDLE_ID" autoWatch -bool false
    mkdir -p "$RECORDINGS_DIR"
    touch "$RECORD_ONLY_MARKER"
    RECORD_ONLY=true   # reuse the record-only cleanup + marker-bounded sweep
elif [ "$RECORD_ONLY" = true ]; then
    log "Enabling record-only mode (no transcript/protocol generation)"
    defaults write "$DEV_BUNDLE_ID" recordOnly -bool true
    mkdir -p "$RECORDINGS_DIR"
    touch "$RECORD_ONLY_MARKER"
else
    # Reset stale toggle from a previous --record-only run on the same host
    # so a plain `--two-meetings` invocation isn't silently still in record-only.
    defaults delete "$DEV_BUNDLE_ID" recordOnly 2>/dev/null || true
fi

# Optional diarizer-mode override. `MTT_DIARIZER_MODE=sortformer` flips the
# dev .app into Sortformer mode for this run — used by the Sortformer-naming
# lane to assert that Phase 1 of issue #165 (post-hoc WeSpeaker embeddings)
# actually lights up the naming dialog in production-chain. Always cleared
# on exit so subsequent runs return to the default `.offline` mode.
#
# `defaults write $DEV_BUNDLE_ID` from outside writes to the
# *standard* preferences domain. The dev .app's bundle has a pre-existing
# container at `~/Library/Containers/$DEV_BUNDLE_ID/...` —
# from a prior App Store-variant build or interactive use — and macOS
# routes the app's UserDefaults reads to that container regardless of
# whether the current binary is sandboxed. A naïve `defaults write` is
# silently a no-op there. Write to both: container if it exists (covers
# this runner) AND standard domain (covers a clean runner where the
# container hasn't been created yet).
_CONTAINER_PLIST="$(dev_container_plist)"
_set_dev_default() {
    local key="$1" value="$2" type="${3:-string}"
    # `numSpeakers` is read as `defaults.object(forKey:) as? Int`, so it must be
    # written with `-int`; a string-typed write would fail the `as? Int` cast
    # and silently fall back to the auto-detect sentinel (0).
    case "$type" in
        bool)
            defaults write "$DEV_BUNDLE_ID" "$key" -bool "$value" 2>/dev/null || true
            [ -f "$_CONTAINER_PLIST" ] && defaults write "$_CONTAINER_PLIST" "$key" -bool "$value" 2>/dev/null || true
            ;;
        int)
            defaults write "$DEV_BUNDLE_ID" "$key" -int "$value" 2>/dev/null || true
            [ -f "$_CONTAINER_PLIST" ] && defaults write "$_CONTAINER_PLIST" "$key" -int "$value" 2>/dev/null || true
            ;;
        *)
            defaults write "$DEV_BUNDLE_ID" "$key" "$value" 2>/dev/null || true
            [ -f "$_CONTAINER_PLIST" ] && defaults write "$_CONTAINER_PLIST" "$key" "$value" 2>/dev/null || true
            ;;
    esac
}
_delete_dev_default() {
    local key="$1"
    defaults delete "$DEV_BUNDLE_ID" "$key" 2>/dev/null || true
    [ -f "$_CONTAINER_PLIST" ] && defaults delete "$_CONTAINER_PLIST" "$key" 2>/dev/null || true
}
if [ -n "${MTT_DIARIZER_MODE:-}" ]; then
    log "Overriding diarizerMode=$MTT_DIARIZER_MODE for this run"
    _set_dev_default diarizerMode "$MTT_DIARIZER_MODE"
else
    _delete_dev_default diarizerMode
fi

# --- speaker-DB snapshot/restore (naming-confirm lane, CI ONLY) -----------
#
# Confirming speaker names enrolls the voices into the real
# `speakers.json` and appends a row to `recognition_log.jsonl` (both under
# Application Support, via AppPaths). Left unmanaged that would permanently
# pollute the Mac mini runner's persistent speaker DB, which the
# Sortformer-naming lane's recognition expectations depend on. Snapshot both
# files before the lane and restore them from the exit trap (success AND
# failure). The snapshot also resets speakers.json to empty so the fixture's
# voices are guaranteed UNMATCHED, the clean precondition the transcript
# relabel assertion relies on (auto-name == raw SPEAKER_n label).
#
# GUARDED to CI via `$GITHUB_ACTIONS` (never set in a developer's shell), like
# the pipeline-queue reset above: the destructive reset/restore machinery must
# never touch a developer's real speaker DB. A LOCAL run therefore does NOT
# snapshot, so the confirm will enroll into your real DB (warned below).
_APP_SUPPORT_DIR="$HOME/Library/Application Support/MeetingTranscriber"
# Durable, DETERMINISTIC backup siblings (not a random /tmp dir): a hard kill
# between the reset and the trap-restore would strand a random mktemp backup
# nothing ever finds again, losing the runner's real DB. Deterministic sibling
# paths let _naming_confirm_self_heal_db (run at every CI lane's startup) detect
# and restore a dead run's DB.
_NC_DB_FILES=(speakers.json recognition_log.jsonl)
_NC_DB_BACKUP_SUFFIX=".e2e-nc-backup"
_NC_DB_ABSENT_SUFFIX=".e2e-nc-absent"
# Per-domain (standard + container) pre-lane values of the settings this lane
# overrides, so cleanup restores EACH domain to exactly its own snapshot. A
# container-first read paired with a both-domain delete would wipe a
# standard-domain value that was never snapshotted. Initialised empty so the
# exit trap is `set -u`-safe even if it fires before the snapshot ran.
_NC_PRE_DIARIZE_STD=""
_NC_PRE_DIARIZE_CTR=""
_NC_PRE_NUMSPK_STD=""
_NC_PRE_NUMSPK_CTR=""
# Temp dir holding this lane's private COPY of the fixture (see run_naming_confirm
# for why a copy is mandatory). Cleaned up by _naming_confirm_cleanup on any exit.
_NC_FIXTURE_DIR=""

# Temp dir holding the echo lane's synthesised dual-source pairs. Its own mktemp
# dir, removed by on_exit; the shipped fixtures it is built from are read-only.
_EB_FIXTURE_DIR=""

# True when any durable backup / absent marker exists on disk.
_naming_confirm_backup_present() {
    local f
    for f in "${_NC_DB_FILES[@]}"; do
        [ -f "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" ] && return 0
        [ -f "$_APP_SUPPORT_DIR/$f$_NC_DB_ABSENT_SUFFIX" ] && return 0
    done
    return 1
}

_naming_confirm_snapshot_db() {
    [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
    local f
    for f in "${_NC_DB_FILES[@]}"; do
        rm -f "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" "$_APP_SUPPORT_DIR/$f$_NC_DB_ABSENT_SUFFIX"
        if [ -f "$_APP_SUPPORT_DIR/$f" ]; then
            # `|| true` so a copy failure falls through to the verify below (which
            # fails with a clear message) instead of a raw abort mid-loop.
            cp -p "$_APP_SUPPORT_DIR/$f" "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" || true
        else
            : >"$_APP_SUPPORT_DIR/$f$_NC_DB_ABSENT_SUFFIX"
        fi
    done
    # NEVER destroy the live DB until its durable backup verifiably exists.
    if [ -f "$_APP_SUPPORT_DIR/speakers.json" ] \
        && [ ! -f "$_APP_SUPPORT_DIR/speakers.json$_NC_DB_BACKUP_SUFFIX" ]; then
        fail "[naming-confirm] durable speaker-DB backup failed; refusing to reset the live speakers.json"
    fi
    rm -f "$_APP_SUPPORT_DIR/speakers.json"
    log "[naming-confirm] CI: durable speaker-DB backup written; reset speakers.json to empty"
}

# Restore from the durable backup + clear the markers, verifying byte-identity.
# Shared by the exit-trap cleanup AND the startup self-heal, so a run that died
# mid-lane is recovered on the next lane's startup. Idempotent: no markers = no-op.
_naming_confirm_restore_db() {
    [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
    _naming_confirm_backup_present || return 0
    local f mismatch=""
    for f in "${_NC_DB_FILES[@]}"; do
        # cp guarded (this runs from a trap; a failed cp must log, not abort the
        # rest of cleanup). cmp confirms the restore is byte-identical.
        if [ -f "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" ]; then
            if cp -p "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" "$_APP_SUPPORT_DIR/$f"; then
                cmp -s "$_APP_SUPPORT_DIR/$f" "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" || mismatch="$mismatch $f"
            else
                mismatch="$mismatch $f(copy-failed)"
            fi
        elif [ -f "$_APP_SUPPORT_DIR/$f$_NC_DB_ABSENT_SUFFIX" ]; then
            rm -f "$_APP_SUPPORT_DIR/$f"
        fi
        rm -f "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" "$_APP_SUPPORT_DIR/$f$_NC_DB_ABSENT_SUFFIX"
    done
    # Log a diff rather than fail: this runs from a trap, and a restore warning
    # must not mask the run's real exit status.
    if [ -n "$mismatch" ]; then
        log "[naming-confirm] WARNING: speaker-DB restore diff:$mismatch"
    else
        log "[naming-confirm] CI: speaker DB restored from durable backup (verified)"
    fi
}

# Startup self-heal: if a prior naming-confirm run died between the reset and its
# restore, its durable backup is still on disk. Restore it before anything else
# touches the DB. Runs for EVERY lane (CI-gated) so a different lane following a
# dead naming-confirm run still recovers the real DB. Logs even when clean, so
# its execution is visible in the run log.
_naming_confirm_self_heal_db() {
    [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
    if _naming_confirm_backup_present; then
        log "[naming-confirm] CI: leftover durable speaker-DB backup from a prior run detected; self-healing"
        _naming_confirm_restore_db
    else
        log "[naming-confirm] CI: no leftover speaker-DB backup to self-heal"
    fi
}

# Full naming-confirm teardown: restore the DB + the lane's diarize/numSpeakers
# overrides (per domain, to their exact pre-lane values), then log the restored
# effective values. Registered as the naming-confirm hook of the single on_exit
# trap (no second trap arming); idempotent (DB restore no-ops once markers clear,
# a re-restore of an already-restored default is a harmless re-write/delete).
_naming_confirm_cleanup() {
    # Remove the lane's private fixture copy (our own mktemp dir; not CI-gated).
    if [ -n "${_NC_FIXTURE_DIR:-}" ] && [ -d "$_NC_FIXTURE_DIR" ]; then
        rm -rf "$_NC_FIXTURE_DIR"
        _NC_FIXTURE_DIR=""
    fi
    _naming_confirm_restore_db
    # Restore each domain to exactly its own snapshot. The shared restore_*_default
    # helpers translate `defaults read`'s 1/0 into the -bool true/false tokens and
    # write -int for numSpeakers (a raw 1/0 into `-bool` errors; see the helpers).
    restore_bool_default "$DEV_BUNDLE_ID" diarize "$_NC_PRE_DIARIZE_STD"
    restore_int_default "$DEV_BUNDLE_ID" numSpeakers "$_NC_PRE_NUMSPK_STD"
    if [ -f "$_CONTAINER_PLIST" ]; then
        restore_bool_default "$_CONTAINER_PLIST" diarize "$_NC_PRE_DIARIZE_CTR"
        restore_int_default "$_CONTAINER_PLIST" numSpeakers "$_NC_PRE_NUMSPK_CTR"
    fi
    local now_diarize now_num
    now_diarize="$(read_dev_default_effective "$DEV_BUNDLE_ID" "$_CONTAINER_PLIST" diarize)"
    now_num="$(read_dev_default_effective "$DEV_BUNDLE_ID" "$_CONTAINER_PLIST" numSpeakers)"
    log "[naming-confirm] settings restored (effective diarize='$now_diarize' numSpeakers='$now_num')"
}

# Self-heal a dead prior run's DB before anything touches it (CI-gated, all lanes).
_naming_confirm_self_heal_db
if [ "$NAMING_CONFIRM" = true ] || [ "$NAMING_ESCAPE" = true ]; then
    log "Enabling naming lane (diarize on, expected speakers = 2)"
    # Snapshot BOTH domains (standard + container) BEFORE overriding so cleanup
    # restores each domain to exactly its own pre-lane state.
    _NC_PRE_DIARIZE_STD="$(snapshot_default "$DEV_BUNDLE_ID" diarize)"
    _NC_PRE_NUMSPK_STD="$(snapshot_default "$DEV_BUNDLE_ID" numSpeakers)"
    if [ -f "$_CONTAINER_PLIST" ]; then
        _NC_PRE_DIARIZE_CTR="$(snapshot_default "$_CONTAINER_PLIST" diarize)"
        _NC_PRE_NUMSPK_CTR="$(snapshot_default "$_CONTAINER_PLIST" numSpeakers)"
    fi
    log "[naming-confirm] pre-lane diarize(std='$_NC_PRE_DIARIZE_STD' ctr='$_NC_PRE_DIARIZE_CTR') numSpeakers(std='$_NC_PRE_NUMSPK_STD' ctr='$_NC_PRE_NUMSPK_CTR')"
    _set_dev_default diarize true bool
    _set_dev_default numSpeakers 2 int
    if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "$NAMING_ESCAPE" != true ]; then
        # Escape-lane runs never confirm — they dismiss — so nothing reaches
        # updateSpeakerDB and the warning would be a false alarm on the one run
        # people are told to perform by hand (the TCC setup run).
        log "[naming-confirm] WARNING: not running under CI. The speaker-DB"
        log "[naming-confirm] snapshot/restore is \$GITHUB_ACTIONS-gated, so this run"
        log "[naming-confirm] WILL enroll the fixture voices into your real"
        log "[naming-confirm] $_APP_SUPPORT_DIR/speakers.json (+ recognition_log.jsonl)."
    fi
    # Durably back up + reset the DB. No interim trap here (one-trap design): the
    # window before on_exit is armed is covered by _naming_confirm_self_heal_db
    # (called above), which restores a dead run's durable backup at the next
    # lane's startup, and the snapshot verifies the backup exists before the reset.
    _naming_confirm_snapshot_db
fi

# LaunchServices' `open` routes to the WindowServer of the *foreground* Aqua
# session, not just any session with our UID loaded. If a second user is
# signed in via Fast User Switching and currently has the foreground, our
# LaunchAgent's `open` lands in an inactive session and LaunchServices
# returns the misleading `procNotFound (-600)`. Catch this before the call
# so the failure is actionable instead of cryptic.
fg_user=$(stat -f "%Su" /dev/console)
my_user=$(id -un)
if [ "$fg_user" != "$my_user" ]; then
    fail "Aqua foreground user is '$fg_user', not '$my_user' — Fast User Switching is active. On the Mac mini, log '$fg_user' out completely (Apple menu → Log Out '$fg_user'…), then re-trigger this workflow."
fi

# Stale pipeline-queue reset (CI ONLY). A persisted errored job in
# `ipc/pipeline_queue.json` is recovered on every launch and surfaces as
# `lastJob`, so a single genuine silent-capture flake turns into a permanent
# red across all later runs — the same job UUID + frozen `enqueuedAt` reappear
# run-to-run (observed 2026-06-03: 7ABA2BA8… with a monotonically growing
# durationSec). The app was already stopped above (`quit_running_app`), so the
# snapshot is static here.
#
# GUARDED to CI via `$GITHUB_ACTIONS` — that variable is set only inside a
# GitHub Actions runner, NEVER in a developer's shell, so this branch can
# never execute on a local / production machine. It also removes ONLY the
# regenerable queue snapshot — never recordings, speakers.json, protocols, or
# any other user content.
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    _ipc_dir="$HOME/Library/Application Support/MeetingTranscriber/ipc"
    rm -f "$_ipc_dir/pipeline_queue.json" "$_ipc_dir/pipeline_queue.tmp"
    log "CI: reset stale pipeline-queue snapshot ($_ipc_dir/pipeline_queue.json)"
fi

log "Launching $DEV_BUNDLE_DEPLOY"
open "$DEV_BUNDLE_DEPLOY"

log "Waiting up to ${RPC_READY_TIMEOUT_S}s for RPC /healthz"
# Assigns RPC_TOKEN in caller scope on success so subsequent `rpc` calls
# carry the bearer token.
_rpc_ready() { [ -f "$RPC_TOKEN_FILE" ] && RPC_TOKEN="$(cat "$RPC_TOKEN_FILE")" && rpc /healthz >/dev/null 2>&1; }
poll_until "$RPC_READY_TIMEOUT_S" 1 _rpc_ready \
    || fail "RPC /healthz did not respond within ${RPC_READY_TIMEOUT_S}s"
log "RPC up"

# Single trap covers the simulator process + record-only side-effects for
# any exit path (success, fail, signal). Set before the first `&` line so
# a kill between fork and the trap line doesn't orphan the subprocess.
SIM_PID=""
_ON_EXIT_RAN=""
on_exit() {
    # Run exactly once. The INT/TERM traps below run on_exit then `exit`, and
    # that exit re-fires the EXIT trap, and without this guard on_exit would run
    # twice on a signal (harmless because every step is idempotent, but noisy).
    [ -n "$_ON_EXIT_RAN" ] && return 0
    _ON_EXIT_RAN=1
    [ -n "${SIM_PID:-}" ] && kill "$SIM_PID" 2>/dev/null || true
    if [ "$MIC_ONLY" = true ]; then
        # The lane turns auto-watch off; nothing else here would turn it back
        # on, and a human using the dev app on this host would find detection
        # silently disabled.
        defaults write "$DEV_BUNDLE_ID" autoWatch -bool true 2>/dev/null || true
    fi
    if [ "$RECORD_ONLY" = true ]; then
        defaults delete "$DEV_BUNDLE_ID" recordOnly 2>/dev/null || true
        # Marker-bounded cleanup: only files created since `touch $MARKER`
        # at launch — never touches pre-existing user data. See feedback
        # memory `no_destructive_fs_on_real_dirs`. Skipped under
        # --keep-recordings so a follow-up --reimport-latest run can pick
        # the WAV up.
        if [ "$KEEP_RECORDINGS" = false ] && [ -f "$RECORD_ONLY_MARKER" ]; then
            find "$RECORDINGS_DIR" -type f -newer "$RECORD_ONLY_MARKER" -delete 2>/dev/null || true
            rm -f "$RECORD_ONLY_MARKER"
        fi
    fi
    # Always clear the diarizerMode override so the next run on this host
    # starts from the AppSettings default (.offline) regardless of which
    # lane left it set. Clears both standard and container plists for the
    # same reason `_set_dev_default` writes to both.
    if [ -n "${MTT_DIARIZER_MODE:-}" ]; then
        _delete_dev_default diarizerMode
    fi
    # Crash-recovery: remove only THIS run's recording artifacts (the exact
    # stem we created). Stem-targeted, so it never touches pre-existing user
    # recordings. See feedback memory `no_destructive_fs_on_real_dirs`.
    if [ "$CRASH_RECOVERY" = true ] && [ -n "${CRASH_STEM:-}" ]; then
        rm -f "$CRASH_RECORDINGS/${CRASH_STEM}"* 2>/dev/null || true
        [ -n "${CRASH_MARKER:-}" ] && rm -f "$CRASH_MARKER"
    fi
    # Naming-confirm: restore the runner's real speaker DB (CI-gated, no-op
    # locally) and the lane's diarize/numSpeakers overrides so a later run on
    # this host starts from the AppSettings defaults.
    if [ "$NAMING_CONFIRM" = true ] || [ "$NAMING_ESCAPE" = true ]; then
        _naming_confirm_cleanup
    fi
    # Mic-only: hand the machine's audio output back before anything else runs
    # on this host. Unconditional, not gated on $MIC_ONLY, so a marker left by a
    # previous run is cleared even when this run never touched the routing.
    _mic_only_restore_output
    # Echo lane: drop the synthesised pairs (our own mktemp dir, never a real
    # recordings directory).
    if [ -n "${_EB_FIXTURE_DIR:-}" ] && [ -d "$_EB_FIXTURE_DIR" ]; then
        rm -rf "$_EB_FIXTURE_DIR"
        _EB_FIXTURE_DIR=""
    fi
}
# Single cleanup hook, but the signal paths must EXIT after cleaning up: a
# trapped INT/TERM otherwise returns into the interrupted command and execution
# continues (e.g. the confirm would re-pollute a just-restored DB). Only the
# EXIT trap runs cleanup-without-exit (the shell is already leaving). 130 = 128+SIGINT,
# 143 = 128+SIGTERM, the conventional shell exit codes for those signals.
trap on_exit EXIT
trap 'on_exit; exit 130' INT
trap 'on_exit; exit 143' TERM


# Trigger one meeting, poll until a new pipeline job reaches a terminal
# state, assert it landed in `done` with a non-trivial transcript. Reads
# `$1` as a human label for log lines ("meeting 1 of 2", etc.). Mutates
# `PRE_LAST_JOB_ID` so the next call recognises the next job as new.
PRE_LAST_JOB_ID=""
# Capture the pre-trigger baseline only AFTER the app's async
# `recoverOrphanedRecordings()` / `loadSnapshot()` has settled. Those run off
# the main actor a beat after launch, so a job they recover isn't yet visible
# the instant RPC comes up. If we baseline too early, a recovered job appears
# *after* the baseline and the poll loop's `id != PRE_LAST_JOB_ID` test
# mistakes it for the job THIS trigger produced — and a recovered *errored*
# job (see the CI reset above) fails the run before the fresh recording even
# finishes. Poll until `lastJob.jobID` is stable across two reads (bounded
# ~15 s), then baseline. Read-only — touches no files, safe on any machine.
_pre_prev="" _pre_stable=0
for _ in $(seq 1 15); do
    _pre_cur="$(rpc /state | jq -r '.lastJob.jobID // ""')" || _pre_cur=""
    if [ "$_pre_cur" = "$_pre_prev" ]; then
        _pre_stable=$(( _pre_stable + 1 ))
        [ "$_pre_stable" -ge 2 ] && break
    else
        _pre_stable=0
    fi
    _pre_prev="$_pre_cur"
    sleep 1
done
PRE_LAST_JOB_ID="$(rpc /state | jq -r '.lastJob.jobID // empty')"
log "Pre-trigger lastJob.jobID: ${PRE_LAST_JOB_ID:-<none>}"

# Shared poll loop used by every flow that triggers a pipeline job
# (`run_one_meeting`, `run_one_reimport`). Polls /state every 5 s, drains
# speaker-naming dialogs along the way, breaks when a NEW lastJob (id
# different from $PRE_LAST_JOB_ID) reaches `.done` or `.error`.
#
# On success: sets globals POLL_LJ_ID, POLL_LJ_STATE for the caller's
# post-poll assertions. On PIPELINE_TIMEOUT_S elapsed: calls `fail()`.
#
# One jq invocation, four fields out via `|`-joined output saves 3 forks
# per poll. `|` (not `@tsv`) keeps consecutive empty fields as boundaries
# — bash `IFS=$'\t' read` collapses them and misparses a fully-null
# lastJob. Trailing `|| true` survives transient curl --max-time hits
# during model load: jq emits no output → read hits EOF → returns 1 →
# `set -e` would otherwise kill the script silently.
POLL_LJ_ID=""
POLL_LJ_STATE=""
_poll_for_new_lastjob_terminal() {
    local label="$1"
    # When $2 is non-empty, launch-recovery jobs ("Recovered Recording (...)")
    # never satisfy the wait: a stale orphan from a previous run is recovered
    # at app launch and races the simulator-triggered job — three CI reds in
    # one day came from lanes mistaking that recovery job for their own. The
    # crash-recovery lane omits the flag; its expected job IS the recovered one.
    local ignore_recovered="${2:-}"
    log "$label: polling /state every 5s for new lastJob (timeout ${PIPELINE_TIMEOUT_S}s)"
    local deadline=$(( $(date +%s) + PIPELINE_TIMEOUT_S ))
    local last_state="" last_id="" noted_recovered=""
    local lj_id="" lj_state="" lj_recovered="" pipe_active="" pipe_processing="" pending_naming=""

    while true; do
        # Fail fast if the dev .app died — otherwise the loop just sees
        # the `|| true` swallow rpc/state errors and we'd burn the full
        # ${PIPELINE_TIMEOUT_S}s before surfacing as "no new pipeline
        # job reached terminal state", masking the real crash.
        assert_app_alive

        lj_id=""; lj_state=""; lj_recovered=""; pipe_active=""; pipe_processing=""; pending_naming=""
        IFS='|' read -r lj_id lj_state lj_recovered pipe_active pipe_processing pending_naming < <(
            rpc /state | jq -r '[.lastJob.jobID // "", .lastJob.state // "", ((.lastJob.meetingTitle // "") | startswith("Recovered Recording")), .pipeline.activeJobCount, .pipeline.isProcessing, .pipeline.pendingNamingJobCount] | join("|")'
        ) || true

        # Drain speaker-naming dialogs so headless runs don't deadlock on a
        # UI click. Fire-and-forget; the endpoint is a no-op when nothing
        # is pending and the next tick picks up the state change.
        if [ "${pending_naming:-0}" != "0" ] && [ -n "$pending_naming" ]; then
            # Capture pendingNamingJobs[0].speakerCount the FIRST time we
            # observe a pending naming job — before /action/skipNaming
            # clears the queue. Surfaces the speaker-count Phase 1 of
            # issue #165 promises: Sortformer mode must populate
            # `result.embeddings` so the naming dialog sees N>0 speakers.
            # Without this capture there's no production-chain signal that
            # the embedding-extraction wiring is actually producing output.
            if [ -z "${OBSERVED_NAMING_SPEAKERS:-}" ]; then
                OBSERVED_NAMING_SPEAKERS="$(rpc /state | jq -r '.pendingNamingJobs[0].speakerCount // 0')" || OBSERVED_NAMING_SPEAKERS=0
                log "$label:   First observed pendingNamingJobs[0].speakerCount=$OBSERVED_NAMING_SPEAKERS"
            fi
            log "$label:   Auto-skipping ${pending_naming} pending naming job(s) via /action/skipNaming"
            curl --silent --show-error --max-time 5 -X POST \
                --header "Authorization: Bearer $RPC_TOKEN" \
                "$RPC_BASE/action/skipNaming" >/dev/null 2>&1 || true
        fi

        if [ "$lj_state" != "$last_state" ] || [ "$lj_id" != "$last_id" ]; then
            log "$label:   pipeline.active=$pipe_active processing=$pipe_processing lastJob=$lj_id state=$lj_state pending_naming=$pending_naming"
            last_state="$lj_state"
            last_id="$lj_id"
        fi

        if [ -n "$ignore_recovered" ] && [ "$lj_recovered" = "true" ] \
            && [ "$lj_id" != "$PRE_LAST_JOB_ID" ] && [ "$lj_id" != "${noted_recovered:-}" ]; then
            log "$label:   ignoring launch-recovery job $lj_id (state=$lj_state) — waiting for the simulator-triggered job"
            noted_recovered="$lj_id"
        fi
        if [ -n "$lj_id" ] && [ "$lj_id" != "$PRE_LAST_JOB_ID" ] \
            && { [ -z "$ignore_recovered" ] || [ "$lj_recovered" != "true" ]; } \
            && { [ "$lj_state" = "done" ] || [ "$lj_state" = "error" ]; }; then
            break
        fi

        [ "$(date +%s)" -lt "$deadline" ] || fail "$label: no new pipeline job reached terminal state within ${PIPELINE_TIMEOUT_S}s (active=$pipe_active processing=$pipe_processing)"
        sleep 5
    done

    POLL_LJ_ID="$lj_id"
    POLL_LJ_STATE="$lj_state"
}

# Fail the lane unless the transcript reads as German. Guards the
# live-recording lanes against a transcript that clears the >100-byte size
# check but is actually garbage — wrong-language hallucination, silent-capture
# noise, or an empty-ish file. Logs which words matched so a near-miss is
# diagnosable straight from the CI log.
assert_transcript_is_german() {
    local label="$1" transcript_path="$2"
    if ! transcript_is_german "$transcript_path"; then
        fail "$label: transcript does not read as German — matched only $GERMAN_MARKER_MATCHED/${#GERMAN_MARKER_WORDS[@]} common German words (need >= $GERMAN_MARKER_WORDS_MIN), so it is likely an English hallucination or garbage despite passing the >100-byte size check. matched=[$GERMAN_MARKER_HITS]. Preview:"$'\n'"$(head -c 500 "$transcript_path")"
    fi
    log "$label: transcript content OK — matched $GERMAN_MARKER_MATCHED/${#GERMAN_MARKER_WORDS[@]} German words [$GERMAN_MARKER_HITS]"
}

run_one_meeting() {
    local label="$1"
    # Reset between meetings so --two-meetings captures each run's first
    # observed naming-dialog speaker count, not just meeting 1's stale value.
    OBSERVED_NAMING_SPEAKERS=""
    log "$label: starting meeting-simulator → $SIMULATOR_FIXTURE"
    "$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-app-sim.log 2>&1 &
    SIM_PID=$!

    _poll_for_new_lastjob_terminal "$label" ignore-recovered
    local lj_id="$POLL_LJ_ID" lj_state="$POLL_LJ_STATE"

    log "$label: final state: $lj_state"
    local final_snapshot
    final_snapshot="$(rpc /state)"
    echo "$final_snapshot" | jq '.lastJob'

    [ "$lj_state" = "done" ] || fail "$label: lastJob.state == \"$lj_state\", expected \"done\". Error: $(jq -r '.lastJob.error // "<none>"' <<<"$final_snapshot")"

    local transcript_path
    transcript_path="$(jq -r '.lastJob.transcriptPath // empty' <<<"$final_snapshot")"
    [ -n "$transcript_path" ] || fail "$label: lastJob.transcriptPath is empty"
    [ -f "$transcript_path" ] || fail "$label: transcript file does not exist: $transcript_path"

    local transcript_size
    transcript_size="$(wc -c <"$transcript_path" | tr -d ' ')"
    [ "$transcript_size" -gt 100 ] || fail "$label: transcript suspiciously short: $transcript_size bytes (expected > 100)"

    log "$label: transcript $transcript_path ($transcript_size bytes)"
    log "$label: preview:"
    head -c 500 "$transcript_path" | sed 's/^/    /'

    # Content assertion: a >100-byte transcript can still be garbage (an
    # empty-ish file, a wrong-language hallucination, or silent-capture noise
    # all clear the size gate). For the known fixture, require its German
    # content words actually appear so this lane can't go green on a broken
    # audio-path or wrong-language regression.
    if [ "$MIC_DEVICE_CHANGE" = true ]; then
        # Survival lane (issue #379): the injected mid-recording tap fault can
        # degrade capture, and its PASS criterion is "app survived + recording
        # completed", not ASR content quality. A content gate here would risk a
        # false regression that masks the real survival signal, so skip it.
        log "$label: mic-device-change survival lane — skipping content keyword assertion"
    elif [ "$IS_DEFAULT_FIXTURE" = true ]; then
        assert_transcript_is_german "$label" "$transcript_path"
    else
        # Custom --fixture: unknown spoken content, so keep only the size check.
        log "$label: custom fixture — skipping content keyword assertion (size check only)"
    fi

    # Phase 1 of #165 production-chain assertion: when caller sets
    # MTT_EXPECT_NAMING_SPEAKERS_MIN, require that the pending naming
    # dialog observed during this run carried at least N speakers.
    # `OBSERVED_NAMING_SPEAKERS` is populated inside the poll loop when
    # the first `pendingNamingJobs[0]` appears (before /action/skipNaming
    # drains it). Default lane (offline) doesn't set the gate; the
    # Sortformer-mode lane wires it via `MTT_EXPECT_NAMING_SPEAKERS_MIN=1`
    # so a regression that returns `embeddings: nil` would surface as
    # "speakerCount=0, naming dialog never opened".
    if [ -n "${MTT_EXPECT_NAMING_SPEAKERS_MIN:-}" ]; then
        observed="${OBSERVED_NAMING_SPEAKERS:-0}"
        if [ "$observed" -lt "$MTT_EXPECT_NAMING_SPEAKERS_MIN" ]; then
            fail "$label: pendingNamingJobs[0].speakerCount=$observed < MTT_EXPECT_NAMING_SPEAKERS_MIN=$MTT_EXPECT_NAMING_SPEAKERS_MIN — naming dialog did not fire with the expected speaker count (Phase 1 #165 production-chain regression?)"
        fi
        log "$label: naming-dialog speaker count assertion passed (observed=$observed >= min=$MTT_EXPECT_NAMING_SPEAKERS_MIN)"
    fi
    echo

    PRE_LAST_JOB_ID="$lj_id"
    SIM_PID=""
}

# --- Shared sidecar assertions ---------------------------------------------
#
# Extracted so the record-only and mic-only lanes cannot drift on the parts that
# are properties of a *sidecar* rather than of a lane. Each lane keeps its own
# jq for what makes it that lane (trigger, which track must be present).

# Wait for a `*_meta.json` newer than $2 to appear, then dump it.
# Sets $SIDECAR_PATH; an out-variable rather than stdout because `log` writes
# there and command substitution would swallow the run log into the value.
await_new_sidecar() {
    local label="$1" marker="$2"
    log "$label: polling $RECORDINGS_DIR for sidecar (timeout ${RECORD_ONLY_DEADLINE_S}s)"
    local deadline=$(( $(date +%s) + RECORD_ONLY_DEADLINE_S ))
    SIDECAR_PATH=""
    while true; do
        SIDECAR_PATH="$(find "$RECORDINGS_DIR" -type f -name '*_meta.json' -newer "$marker" -print 2>/dev/null | head -1)"
        [ -n "$SIDECAR_PATH" ] && break
        [ "$(date +%s)" -lt "$deadline" ] || fail "$label: no *_meta.json appeared in $RECORDINGS_DIR within ${RECORD_ONLY_DEADLINE_S}s"
        sleep 2
    done
    log "$label: found sidecar $SIDECAR_PATH"
    jq -C . "$SIDECAR_PATH" | sed 's/^/    /'
}

# The lane-independent half of the schema: shape and timestamps.
assert_sidecar_common() {
    local label="$1" sidecar="$2" check
    check="$(jq -r '
        if .version != 2 then "version != 2 (got: \(.version))"
        elif (.startedAt | type) != "string" then "startedAt not string"
        elif (.stoppedAt | type) != "string" then "stoppedAt not string"
        elif (.startedAt | fromdateiso8601? // -1) < 0 then "startedAt not ISO8601"
        elif (.stoppedAt | fromdateiso8601? // -1) < 0 then "stoppedAt not ISO8601"
        elif (.stoppedAt | fromdateiso8601) <= (.startedAt | fromdateiso8601) then "stoppedAt <= startedAt"
        else "ok"
        end
    ' "$sidecar")"
    [ "$check" = "ok" ] || fail "$label: sidecar schema invalid: $check"
}

# Assert one track named in the sidecar exists and carries audio.
# $4 is the active-seconds floor: pass the fixture-calibrated one where the
# lane controls what is played, so a capture that dies partway is caught.
assert_sidecar_track_has_signal() {
    local label="$1" sidecar="$2" key="$3" min_active="$4" hint="$5"
    local name path verdict
    name="$(jq -r ".files.$key // empty" "$sidecar")"
    [ -n "$name" ] || fail "$label: sidecar has no $key track (.files.$key is null). $hint"
    path="$(dirname "$sidecar")/$name"
    [ -f "$path" ] || fail "$label: $key track WAV not found: $path"
    # `=` form for the negative threshold: ArgumentParser reads a bare `-50` as
    # another flag and errors out.
    if verdict="$("$MTCLI" wav-verdict "$path" --threshold-dbfs=$WAV_VERDICT_THRESHOLD_DBFS --min-active-seconds="$min_active")"; then
        log "$label: $key track $name capture OK: $verdict"
    else
        fail "$label: $key track $name is silent/too quiet (reason above). $hint"
    fi
}

# Record-only short-circuits before the pipeline, so `lastJob` must not move.
assert_last_job_unchanged() {
    local label="$1" lj_id
    lj_id="$(rpc /state | jq -r '.lastJob.jobID // empty')"
    [ "$lj_id" = "$PRE_LAST_JOB_ID" ] \
        || fail "$label: lastJob.jobID changed to '$lj_id' (was '$PRE_LAST_JOB_ID') — the pipeline should have been skipped in record-only mode"
}

# Mic-only lane (issue #633): no meeting, no detector, no app audio. Starts the
# recording over POST /v1/record, plays the fixture into the loopback input so
# the microphone has something to capture, stops over the same route, and asserts
# the sidecar describes a single-track recording.
#
# `afplay` rather than the meeting-simulator, and auto-watch off: this lane wants
# sound, not a detectable meeting. The simulator holds a power assertion, and the
# watch loop would start an auto recording alongside the manual one.
run_mic_only() {
    local label="[mic-only]"

    _mic_only_switch_output

    log "$label: starting microphone recording over POST /v1/record"
    "$MTCLI" record start >/dev/null || fail "$label: mt-cli record start failed"

    # Assert the app agrees it is recording before feeding it audio: a start that
    # answered 200 while nothing runs would otherwise surface later as a
    # confusing "no sidecar appeared".
    local status
    status="$("$MTCLI" record)" || fail "$label: mt-cli record status failed"
    echo "$status" | jq -e '.recording == true' >/dev/null \
        || fail "$label: /v1/record reports recording=false right after a 200 start: $status"
    log "$label: recording confirmed: $status"

    log "$label: playing $SIMULATOR_FIXTURE into the loopback input"
    afplay "$SIMULATOR_FIXTURE" || fail "$label: afplay failed; the microphone had nothing to capture"

    log "$label: stopping recording"
    "$MTCLI" record stop >/dev/null || fail "$label: mt-cli record stop failed"

    # `record stop` is synchronous through mix + sidecar write, so this resolves
    # on the first iteration or never; the deadline only bounds a regression.
    local sidecar
    await_new_sidecar "$label" "$RECORD_ONLY_MARKER"
    sidecar="$SIDECAR_PATH"

    # `trigger` is what tells a fleet consumer a short recording was deliberate
    # rather than a false detection, and this lane is its only live producer.
    # The identity fields are asserted for the same reason: nothing else records
    # under them, so a drift would ship unnoticed.
    local schema_check
    schema_check="$(jq -r '
        if .trigger != "manual" then "trigger != manual (got: \(.trigger // "absent"))"
        elif .appName != "Microphone" then "appName != Microphone (got: \(.appName // "absent"))"
        elif .title != "Microphone Recording" then "title != Microphone Recording (got: \(.title // "absent"))"
        elif (.micDelaySeconds // 0) != 0 then "micDelaySeconds != 0 (got: \(.micDelaySeconds)) — there is no app track to align against"
        elif (.files.mic // "") == "" then "files.mic missing"
        elif (.files.mic | endswith("_mic.wav") | not) then "files.mic doesn'"'"'t end with _mic.wav (got: \(.files.mic))"
        else "ok"
        end
    ' "$sidecar")"
    [ "$schema_check" = "ok" ] || fail "$label: sidecar schema invalid: $schema_check"
    assert_sidecar_common "$label" "$sidecar"

    # THE assertion this lane exists for. Everything else here would also hold
    # for an ordinary dual-source recording.
    #
    # Known limit, worth stating rather than implying: `.files.app` is written
    # only when the tap delivered bytes, so this catches a tap that opens AND
    # captures, not one that opens and yields nothing. Distinguishing those needs
    # the recording source on `/state`, which it does not expose today.
    local app_filename
    app_filename="$(jq -r '.files.app // empty' "$sidecar")"
    [ -z "$app_filename" ] || fail "$label: sidecar carries an app track ($app_filename); a microphone-only recording must open no process tap"
    log "$label: no app track in the sidecar, as required"

    assert_sidecar_track_has_signal "$label" "$sidecar" mic "$WAV_VERDICT_FIXTURE_MIN_ACTIVE_S" \
        "Either the default output is no longer routed into the loopback input, or microphone capture regressed."

    # Negative: record-only short-circuits before VAD/transcription/protocol, and
    # a manual trigger must not be the exception that slips past it.
    local unexpected
    unexpected="$(find "$RECORDINGS_DIR" -maxdepth 1 -type f -newer "$RECORD_ONLY_MARKER" \
        \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | head -5)"
    [ -z "$unexpected" ] || fail "$label: a microphone recording must not produce transcript/protocol; found: $unexpected"
    assert_last_job_unchanged "$label"
    assert_app_alive

    log "$label: PASS"
}

# Record-only counterpart: trigger one meeting, wait for sidecar+WAV to
# land in `recordings/`, assert schema/files, negative-assert that no
# transcript/protocol got written and `lastJob` didn't advance.
run_one_record_only_meeting() {
    local label="$1"

    # Per-meeting marker so iteration 2 of --two-meetings doesn't see the
    # iteration-1 sidecar as "new". Outer $RECORD_ONLY_MARKER still bounds
    # the cleanup sweep on exit.
    local meeting_marker="/tmp/e2e-app-record-only-meeting-marker.$$"
    rm -f "$meeting_marker"
    touch "$meeting_marker"

    log "$label: starting meeting-simulator (record-only) → $SIMULATOR_FIXTURE"
    "$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-app-sim.log 2>&1 &
    SIM_PID=$!

    # Block until the simulator finishes playing the fixture. Exit code is
    # irrelevant; we assert on filesystem state below.
    wait "$SIM_PID" || true
    SIM_PID=""

    log "$label: simulator done; polling $RECORDINGS_DIR for sidecar (timeout ${RECORD_ONLY_DEADLINE_S}s)"
    local deadline=$(( $(date +%s) + RECORD_ONLY_DEADLINE_S ))
    local sidecar=""
    while true; do
        sidecar="$(find "$RECORDINGS_DIR" -type f -name '*_meta.json' -newer "$meeting_marker" -print 2>/dev/null | head -1)"
        [ -n "$sidecar" ] && break
        [ "$(date +%s)" -lt "$deadline" ] || fail "$label: no *_meta.json appeared in $RECORDINGS_DIR within ${RECORD_ONLY_DEADLINE_S}s"
        sleep 2
    done

    log "$label: found sidecar $sidecar"
    jq -C . "$sidecar" | sed 's/^/    /'

    # Schema check in one jq invocation — emits "ok" or a human-readable reason.
    local schema_check
    schema_check="$(jq -r '
        if .trigger != "auto" then "trigger != auto (got: \(.trigger // "absent"))"
        elif (.files.mix // "") == "" then "files.mix missing"
        elif (.files.mix | endswith("_mix.wav") | not) then "files.mix doesn'\''t end with _mix.wav (got: \(.files.mix))"
        else "ok"
        end
    ' "$sidecar")"
    [ "$schema_check" = "ok" ] || fail "$label: sidecar schema invalid: $schema_check"
    assert_sidecar_common "$label" "$sidecar"

    # Mix WAV must live next to the sidecar and be non-trivial.
    local sidecar_dir mix_filename mix_path mix_size
    sidecar_dir="$(dirname "$sidecar")"
    mix_filename="$(jq -r '.files.mix' "$sidecar")"
    mix_path="$sidecar_dir/$mix_filename"
    [ -f "$mix_path" ] || fail "$label: mix WAV not found: $mix_path"
    mix_size="$(wc -c <"$mix_path" | tr -d ' ')"
    # 16 kHz mono 16-bit PCM = 32 KB/sec. Fixture two_speakers_de.wav is 49.8 s,
    # so expect > 64 KB even after heavy truncation.
    [ "$mix_size" -gt 65536 ] || fail "$label: mix WAV suspiciously small: $mix_size bytes (expected > 64 KB)"
    log "$label: mix WAV $mix_path ($mix_size bytes)"

    # The mix-size check above only proves bytes were written. Two capture
    # failures slip past it: (a) an all-zeros app track is byte-for-byte the
    # same size as a good one, and the mic masks it in the mix via speaker
    # bleed; (b) a tap that never attaches leaves no app track at all, and the
    # mix falls back to mic-only at full size. This meeting is always
    # dual-source (the simulator plays the fixture the whole time), so assert
    # the app track both exists AND carries energy, via the same mt-cli
    # wav-verdict analyzer the browser lane uses (windowed peak RMS, robust to
    # the trailing grace-period silence). A missing or silent app track means
    # system-audio capture produced no signal (a wrong tap PID set, a missing
    # TCC audio-capture grant, or a regressed capture path).
    # `=` form for the negative threshold: ArgumentParser reads a bare `-50` as
    # another flag and errors out.
    assert_sidecar_track_has_signal "$label" "$sidecar" app "$WAV_VERDICT_FIXTURE_MIN_ACTIVE_S" \
        "System-audio capture produced no usable signal: likely a wrong tap PID set, a missing TCC audio-capture grant, or a regressed capture path."

    # Negative: record-only short-circuits before VAD/transcription/protocol.
    # No `.txt`/`.md` files from THIS meeting should exist in recordings/.
    local unexpected
    unexpected="$(find "$RECORDINGS_DIR" -maxdepth 1 -type f -newer "$meeting_marker" \
        \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | head -5)"
    [ -z "$unexpected" ] || fail "$label: record-only should not produce transcript/protocol; found: $unexpected"

    # Negative: PipelineQueue.enqueue() was skipped, so `lastJob.jobID`
    # must still equal whatever it was before this meeting fired.
    local snapshot lj_id
    snapshot="$(rpc /state)"
    lj_id="$(jq -r '.lastJob.jobID // empty' <<<"$snapshot")"
    [ "$lj_id" = "$PRE_LAST_JOB_ID" ] || fail "$label: lastJob.jobID changed to '$lj_id' (was '$PRE_LAST_JOB_ID') — pipeline should have been skipped in record-only mode"

    # Surface the produced mix path so the optional reimport chain picks
    # it up without re-globbing. Reset by each caller's `local` line.
    LAST_RECORDED_MIX_PATH="$mix_path"

    rm -f "$meeting_marker"
}

# Re-import a previously-recorded WAV via POST /action/enqueueFile — same
# code path the menu's "Open from Recording" entry takes. Polls /state for
# a new lastJob in `done`, asserts transcript exists, is non-trivial, and
# contains the expected fixture keyword. Confirms the round-trip:
# recorder-produced WAV is loadable + transcribable.
run_one_reimport() {
    local label="$1"
    local audio_path="$2"
    local expected_phrase="${3:-meeting}"  # case-insensitive substring

    [ -f "$audio_path" ] || fail "$label: re-import source not found: $audio_path"

    log "$label: POST /action/enqueueFile path=$audio_path"
    local enq_status
    enq_status="$(curl --silent --show-error --max-time 10 -o /dev/null -w "%{http_code}" \
        -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$(jq -nc --arg p "$audio_path" '{path: $p}')" \
        "$RPC_BASE/action/enqueueFile" 2>/dev/null || echo "000")"
    [ "$enq_status" = "200" ] || fail "$label: enqueueFile returned HTTP $enq_status (expected 200)"

    _poll_for_new_lastjob_terminal "$label"
    local lj_id="$POLL_LJ_ID" lj_state="$POLL_LJ_STATE"

    log "$label: final state: $lj_state"
    local final_snapshot
    final_snapshot="$(rpc /state)"
    echo "$final_snapshot" | jq '.lastJob'

    [ "$lj_state" = "done" ] || fail "$label: lastJob.state == \"$lj_state\", expected \"done\". Error: $(jq -r '.lastJob.error // "<none>"' <<<"$final_snapshot")"

    local transcript_path
    transcript_path="$(jq -r '.lastJob.transcriptPath // empty' <<<"$final_snapshot")"
    [ -n "$transcript_path" ] || fail "$label: lastJob.transcriptPath is empty"
    [ -f "$transcript_path" ] || fail "$label: transcript file does not exist: $transcript_path"

    local transcript_size
    transcript_size="$(wc -c <"$transcript_path" | tr -d ' ')"
    [ "$transcript_size" -gt 100 ] || fail "$label: transcript suspiciously short: $transcript_size bytes (expected > 100)"

    # Content assertion: re-imported WAV came from the live recording stack,
    # so a successful round-trip means the engine actually recognised the
    # fixture's spoken content — not just emitted any non-empty file.
    # `meeting` is case-insensitive-robust (Parakeet may capitalise/translate;
    # WhisperKit may emit "Meeting" or "meeting" depending on punctuation).
    grep -qi "$expected_phrase" "$transcript_path" \
        || fail "$label: transcript does not contain '$expected_phrase' (case-insensitive). Preview:$(printf '\n')$(head -c 500 "$transcript_path")"

    log "$label: transcript $transcript_path ($transcript_size bytes, contains '$expected_phrase')"
    log "$label: preview:"
    head -c 500 "$transcript_path" | sed 's/^/    /'
    echo

    PRE_LAST_JOB_ID="$lj_id"
}

LAST_RECORDED_MIX_PATH=""

# Issue #379 part 3 — crash recovery. Record via the live stack, SIGKILL the
# app mid-recording so `stop()` never runs (the raw `_app16k_raw.tmp` + unfinalized
# `_mic.wav` survive, no `_mix.wav`), then relaunch and assert the recovered
# recording enters the pipeline and a job reaches done. The re-mixed `_mix.wav`
# is transient (recoverOrphanedRecordings enqueues it + the pipeline consumes it
# into its workdir within seconds), so the assertion is on the pipeline job, not
# the file. Pre-fix the launch cleanup deletes the temp first → no recovery
# (RED); the fix re-mixes + enqueues it (GREEN).
#
# Live temps go to AppPaths.recordingsDir (Application Support), NOT the
# record-only Downloads dir — recovery scans the same path.
CRASH_RECORDINGS="$HOME/Library/Application Support/MeetingTranscriber/recordings"
CRASH_MARKER=""
CRASH_STEM=""
run_crash_recovery() {
    local label="[crash-recovery]"
    mkdir -p "$CRASH_RECORDINGS"
    CRASH_MARKER="/tmp/e2e-crash-recovery-marker.$$"
    rm -f "$CRASH_MARKER"; touch "$CRASH_MARKER"

    # Baseline the pre-crash lastJob now (RPC is already up from launch). The
    # recovered recording gets a fresh job id after relaunch, so this stable
    # baseline can never equal the recovered job — avoids a race where recovery
    # enqueues before we could sample a post-relaunch baseline.
    PRE_LAST_JOB_ID="$(rpc /state | jq -r '.lastJob.jobID // empty')"
    log "$label: pre-crash baseline lastJob.jobID=${PRE_LAST_JOB_ID:-<none>}"

    # 1. Start a meeting so the app begins recording.
    log "$label: starting meeting-simulator -> $SIMULATOR_FIXTURE"
    "$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-app-sim.log 2>&1 &
    SIM_PID=$!

    # 2. Wait until the recorder is writing the raw app temp (recording active).
    local orphan_tmp=""
    _crash_tmp_appeared() {
        orphan_tmp="$(find "$CRASH_RECORDINGS" -maxdepth 1 -name '*_app16k_raw.tmp' -newer "$CRASH_MARKER" -print 2>/dev/null | head -1)"
        [ -n "$orphan_tmp" ]
    }
    log "$label: waiting for an active recording (*_app16k_raw.tmp)"
    poll_until 40 1 _crash_tmp_appeared || fail "$label: no *_app16k_raw.tmp appeared — recording never started"
    sleep 3   # let a little audio accumulate before the kill

    CRASH_STEM="$(basename "$orphan_tmp")"; CRASH_STEM="${CRASH_STEM%_app16k_raw.tmp}"
    local stem="$CRASH_STEM"
    log "$label: recording active, orphan stem=$stem"

    # 3. Simulate a crash: SIGKILL the app (no stop() → temp survives, no mix).
    #    Kill the simulator too so the relaunch sees no active meeting — the
    #    only recording that can surface post-relaunch is the recovered one.
    log "$label: SIGKILL the app mid-recording (simulating a crash)"
    pkill -KILL -f "MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber" 2>/dev/null || true
    [ -n "${SIM_PID:-}" ] && kill "$SIM_PID" 2>/dev/null || true
    SIM_PID=""
    sleep 2

    # 4. Verify the crashed-orphan state on disk.
    [ -f "$CRASH_RECORDINGS/${stem}_app16k_raw.tmp" ] || fail "$label: orphan ${stem}_app16k_raw.tmp did not survive the crash"
    [ ! -f "$CRASH_RECORDINGS/${stem}_mix.wav" ] || fail "$label: a _mix.wav exists — stop() ran, this wasn't a crash"
    log "$label: confirmed crashed state (raw temp present, no mix)"

    # 5. Backdate the orphan past recovery's in-progress guard (a real
    #    crash→relaunch gap is minutes; keeps the e2e fast + deterministic).
    local old; old="$(date -v-5M +%Y%m%d%H%M.%S)"
    touch -t "$old" "$CRASH_RECORDINGS/${stem}_app16k_raw.tmp"
    [ -f "$CRASH_RECORDINGS/${stem}_mic.wav" ] && touch -t "$old" "$CRASH_RECORDINGS/${stem}_mic.wav" || true

    # 6. Relaunch — recovery runs at the launch queue-build.
    log "$label: relaunching $DEV_BUNDLE_DEPLOY"
    open "$DEV_BUNDLE_DEPLOY"
    poll_until "$RPC_READY_TIMEOUT_S" 1 _rpc_ready || fail "$label: RPC did not come back after relaunch"
    log "$label: RPC back up after relaunch"

    # 7. Assert recovery: the recovered recording enters the pipeline. The
    #    re-mixed `_mix.wav` is TRANSIENT — `recoverOrphanedRecordings` enqueues
    #    it and the pipeline moves it into its workdir within a few seconds — so
    #    asserting the file persists is wrong (it races the pipeline). Assert on
    #    a NEW pipeline job instead: any active / pending-naming / waiting job.
    #    The CI snapshot reset (above, $GITHUB_ACTIONS-gated) zeroes the queue
    #    first, so a non-zero count here is the recovered recording. Pre-fix the
    #    orphan is deleted with no recovery → the queue stays empty (RED).
    log "$label: waiting for the recovered recording to enter the pipeline (timeout 120s)"
    _crash_recovered_job() {
        local n
        n="$(rpc /state | jq -r '(.pipeline.activeJobCount // 0) + (.pipeline.pendingNamingJobCount // 0) + (.pipeline.waitingJobCount // 0)')"
        [ "${n:-0}" -gt 0 ] 2>/dev/null
    }
    poll_until 120 3 _crash_recovered_job \
        || fail "$label: orphan NOT recovered — no recovered recording entered the pipeline within 120s (recovery missing, or the orphan was deleted by launch cleanup)"
    log "$label: recovered recording entered the pipeline ✅"

    # 8. Full chain: drive the recovered job to a terminal state (the poll loop
    #    auto-skips the speaker-naming dialog) and assert it reached done — the
    #    crashed recording was re-mixed AND transcribed end-to-end.
    _poll_for_new_lastjob_terminal "$label"
    [ "$POLL_LJ_STATE" = "done" ] || fail "$label: recovered job state=$POLL_LJ_STATE, expected done"
    log "$label: recovered recording transcribed (lastJob done) ✅"
}

# Speaker-naming CONFIRM lane. Every other lane's shared poll loop auto-skips
# each naming dialog (POST /action/skipNaming), so the confirm path (assign
# names → the names land as transcript speaker labels → the speaker DB learns
# the voices) has ZERO live coverage. That path is exactly the bug family the
# late-rerun transcript-rebuild fix addressed (a confirm that renamed labels but
# never re-segmented the persisted .txt), so it needs a standing regression net.
#
# Suppression of the auto-skip is scoped to this lane BY CONSTRUCTION: it drives
# the whole flow itself (enqueue → poll pendingNamingJobs → GET/POST
# /v1/jobs/<id>/naming → poll the job to done) and never calls
# `_poll_for_new_lastjob_terminal`, so the global auto-skip other lanes rely on
# is untouched.
# --- Escape-dismisses-naming lane (issue #577) ----------------------------
# Presses a REAL Escape on the open speaker-naming dialog and asserts the one
# thing the fix is about: the window goes away and the job does NOT resolve.
#
# Why a WindowServer keystroke and not an RPC endpoint. A synthetic NSEvent
# cannot do this: keycode 53 only becomes `cancelOperation:` inside
# `interpretKeyEvents:`, which only text-input responders call, so with no name
# field focused SwiftUI's exit command never sees it. Measured three ways (both
# NSWindow.sendEvent and NSApplication.sendEvent in the live app, plus xctest)
# — every one reports a clean dispatch and changes nothing, which is why an
# in-process endpoint for this was built, found inert, and reverted.
#
# Deliberately does NOT click into a name field first. The dialog binds dismiss
# twice — `onExitCommand` for the focused case and a `.cancelAction` carrier for
# the rest — and it is the unfocused path that the fix nearly shipped broken,
# so that is the one worth a lane.
#
# RUNNER PREREQUISITE: the shell running this needs an Accessibility grant
# (System Settings → Privacy & Security → Accessibility), same one-time,
# cert-independent shape as the existing mic / screen-recording grants. Checked
# up front so a missing grant fails with its own message instead of looking like
# a broken dismiss.
run_naming_escape() {
    local label="[naming-escape]"
    [ -f "$DEFAULT_FIXTURE" ] || fail "$label: 2-speaker fixture not found: $DEFAULT_FIXTURE"

    # Preflight both grants this lane needs, because they fail in different ways
    # and only one of them fails loudly.
    #
    # Accessibility (posting keystrokes) refuses with a clear error. Automation
    # (driving another process through System Events) does not: without it the
    # AppleEvent simply never gets an answer and osascript sits there for its
    # default 120 s timeout, which reads as a hung lane rather than a missing
    # permission. So the probe wraps the *same* operation the lane performs in a
    # short explicit timeout and treats the timeout as the diagnosis.
    local probe
    probe="$(osascript -e 'tell application "System Events" to key code 53' 2>&1)" || true
    case "$probe" in
        *"not allowed"*|*"assistive"*|*"1002"*)
            # SKIP for the same reason the Automation arm skips: this is a host
            # prerequisite that only a human at the GUI can satisfy, so failing
            # on it would redden every PR for something unrelated to the change.
            # The two grants are separate and can be half-configured — Automation
            # granted, Accessibility not — so both arms need the same treatment
            # or the lane just moves its red one step later.
            log "$label: SKIP — this host may drive System Events but not post keystrokes."
            log "$label: cause: $probe"
            log "$label: fix: System Settings → Privacy & Security → Accessibility, enable the entry for the shell that runs this lane (it is usually already listed, unchecked)."
            if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
                {
                    echo "### naming-escape lane skipped"
                    echo
                    echo "This host has Automation but is missing the **Accessibility** grant, so the real-Escape assertion did not run."
                    echo "Enable the runner's shell under System Settings → Privacy & Security → Accessibility, then this lane gates normally."
                } >> "$GITHUB_STEP_SUMMARY"
            fi
            return 0 ;;
    esac
    # The probe's window is short by default so a missing grant is reported in
    # seconds rather than waited out. For the one-time setup run it has to be
    # long enough for a human to answer the prompt it raises, hence the knob:
    # E2E_TCC_PROMPT_TIMEOUT=300 bash scripts/e2e-app.sh --naming-escape
    local tcc_timeout="${E2E_TCC_PROMPT_TIMEOUT:-10}"
    probe="$(osascript -e "with timeout of ${tcc_timeout} seconds" \
        -e 'tell application "System Events" to get name of first process whose frontmost is true' \
        -e 'end timeout' 2>&1)" || true
    case "$probe" in
        *"timed out"*|*"-1712"*|*"not authori"*|*"-1743"*)
            # SKIP, not FAIL. The grant can only be given by clicking Allow in
            # the host's GUI session — no MDM profile here, and tccutil can only
            # reset — so on an ungranted host this would turn every PR red for a
            # reason unrelated to the change under test. Failing after this point
            # still fails: only the missing prerequisite is tolerated, and it is
            # reported loudly enough that nobody mistakes it for coverage.
            log "$label: SKIP — this host cannot drive System Events (probe window ${tcc_timeout}s)."
            log "$label: cause: $probe"
            log "$label: fix: System Settings → Privacy & Security → Automation, allow the runner's shell to control System Events (and Accessibility for keystrokes). Both prompt on first use, so run this lane once by hand in the GUI session and click Allow."
            if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
                {
                    echo "### naming-escape lane skipped"
                    echo
                    echo "This host is missing the **Automation** grant, so the real-Escape assertion did not run."
                    echo "Grant it once in the GUI session (System Settings → Privacy & Security → Automation), then this lane gates normally."
                } >> "$GITHUB_STEP_SUMMARY"
            fi
            return 0 ;;
    esac
    log "$label: frontmost process is '$probe'"

    local fixture_dir fixture_copy
    fixture_dir="$(mktemp -d /tmp/e2e-naming-escape-fixture.XXXXXX)"
    fixture_copy="$fixture_dir/two_speakers_de.wav"
    cp "$DEFAULT_FIXTURE" "$fixture_copy" || fail "$label: could not copy fixture to $fixture_copy"

    local enq job_id
    enq="$(curl --silent --show-error --max-time 10 -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$(jq -nc --arg p "$fixture_copy" '{paths: [$p]}')" \
        "$RPC_BASE/v1/jobs" 2>/dev/null || echo '{}')"
    job_id="$(jq -r '.jobIDs[0] // empty' <<<"$enq")"
    [ -n "$job_id" ] || fail "$label: POST /v1/jobs did not return a job id (response: $enq)"
    log "$label: enqueued job $job_id"

    _naming_escape_parked() {
        [ "$(rpc "/v1/jobs/$job_id" | jq -r '.state // empty')" = "speakerNamingPending" ]
    }
    poll_until "$PIPELINE_TIMEOUT_S" 5 _naming_escape_parked \
        || fail "$label: job $job_id never parked at speaker-naming within ${PIPELINE_TIMEOUT_S}s"

    _naming_window_visible() {
        [ "$(rpc /state | jq -r '[.windows[] | select(.id == "speaker-naming") | .isVisible] | first // false')" = "true" ]
    }
    poll_until 30 2 _naming_window_visible \
        || fail "$label: naming window never became visible"
    log "$label: naming window open, job parked"

    # Front the app so the keystroke lands on it, then Escape. No click into the
    # dialog: the point is that dismiss works without a focused field.
    local front_err
    front_err="$(osascript -e 'with timeout of 15 seconds' \
        -e 'tell application "System Events" to tell process "MeetingTranscriber" to set frontmost to true' \
        -e 'end timeout' 2>&1)" \
        || fail "$label: could not front the app: $front_err"
    sleep 1
    local key_err
    key_err="$(osascript -e 'tell application "System Events" to key code 53' 2>&1)" \
        || fail "$label: could not post Escape: $key_err"

    _naming_window_gone() {
        ! _naming_window_visible
    }
    poll_until 15 1 _naming_window_gone \
        || fail "$label: Escape did not dismiss the naming window (windows=$(rpc /state | jq -c '[.windows[]|{id,isVisible}]'))"
    log "$label: window dismissed"

    # The half that separates a dismiss from a Skip: the job must be untouched
    # and still resolvable. A Skip here would have committed the auto-names and
    # deleted the naming data.
    local state
    state="$(rpc "/v1/jobs/$job_id" | jq -r '.state // empty')"
    [ "$state" = "speakerNamingPending" ] \
        || fail "$label: Escape resolved the job (state=$state, expected speakerNamingPending)"
    log "$label: job still parked — dismiss did not resolve it"

    # Leave nothing pending behind; the dialog would reopen on the next launch.
    curl --silent --show-error --max-time 10 -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" --header "Content-Length: 0" \
        "$RPC_BASE/v1/jobs/$job_id/naming/skip" >/dev/null 2>&1 || true
    rm -rf "$fixture_dir"
    log "$label: PASS"
}

run_naming_confirm() {
    local label="[naming-confirm]"
    [ -f "$DEFAULT_FIXTURE" ] || fail "$label: 2-speaker fixture not found: $DEFAULT_FIXTURE"

    # Confirm the app actually resolved the diarization settings the lane
    # configured via `defaults write`; /state.settings is the running
    # process's effective view (a blind `defaults read` is unreliable for the
    # dev bundle's container-plist redirect). Read the DB baseline from the
    # same snapshot.
    local snap diarize num_speakers record_only pre_db_count
    snap="$(rpc /state)"
    [ -n "$snap" ] || fail "$label: /state returned empty (RPC down?)"
    diarize="$(jq -r '.settings.diarization.diarize' <<<"$snap")"
    num_speakers="$(jq -r '.settings.diarization.numSpeakers' <<<"$snap")"
    record_only="$(jq -r '.settings.recording.recordOnly' <<<"$snap")"
    pre_db_count="$(jq -r '.speakerDB.count // 0' <<<"$snap")"
    log "$label: resolved settings diarize=$diarize numSpeakers=$num_speakers recordOnly=$record_only; speakerDB.count=$pre_db_count"
    [ "$diarize" = "true" ] || fail "$label: settings.diarization.diarize is '$diarize', expected true"
    [ "$num_speakers" = "2" ] || fail "$label: settings.diarization.numSpeakers is '$num_speakers', expected 2"
    [ "$record_only" = "false" ] || fail "$label: settings.recording.recordOnly is '$record_only', expected false"

    # Enqueue a PRIVATE COPY of the fixture, never the shared Tests/Fixtures
    # path. The pipeline leaves a user-picked import where it is nowadays, so
    # this is a safety margin rather than load-bearing: it also keeps the lane
    # from leaving its own artifacts next to the shared fixture, and it survives
    # a future change to what counts as relocatable audio. Copy into a temp dir
    # cleaned up on exit by _naming_confirm_cleanup.
    _NC_FIXTURE_DIR="$(mktemp -d /tmp/e2e-naming-confirm-fixture.XXXXXX)"
    local fixture_copy="$_NC_FIXTURE_DIR/two_speakers_de.wav"
    cp "$DEFAULT_FIXTURE" "$fixture_copy" || fail "$label: could not copy fixture to $fixture_copy"

    # Enqueue on the /v1 automation surface (returns the job id). autoSkipNaming
    # is false on this path, so the job parks at speaker-naming.
    log "$label: POST /v1/jobs paths=[$fixture_copy]"
    local enq job_id
    enq="$(curl --silent --show-error --max-time 10 -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$(jq -nc --arg p "$fixture_copy" '{paths: [$p]}')" \
        "$RPC_BASE/v1/jobs" 2>/dev/null || echo '{}')"
    job_id="$(jq -r '.jobIDs[0] // empty' <<<"$enq")"
    [ -n "$job_id" ] || fail "$label: POST /v1/jobs did not return a job id (response: $enq)"
    log "$label: enqueued job $job_id"

    # Poll /state.pendingNamingJobs until OUR job parks at speaker-naming. No
    # /action/skipNaming here; driving the confirm is the whole point.
    local pending_count=""
    _naming_pending() {
        assert_app_alive
        pending_count="$(rpc /state | jq -r --arg id "$job_id" \
            '[.pendingNamingJobs[] | select(.jobID == $id)] | .[0].speakerCount // empty')"
        [ -n "$pending_count" ]
    }
    log "$label: waiting for job $job_id to reach speaker-naming (timeout ${PIPELINE_TIMEOUT_S}s)"
    poll_until "$PIPELINE_TIMEOUT_S" 5 _naming_pending \
        || fail "$label: job $job_id never reached speaker-naming within ${PIPELINE_TIMEOUT_S}s (diarization produced no naming dialog?)"
    log "$label: job parked at naming with speakerCount=$pending_count"
    [ "${pending_count:-0}" -ge 2 ] 2>/dev/null \
        || fail "$label: naming dialog speakerCount=$pending_count, expected >= 2 (numSpeakers=2 on a 2-speaker fixture)"

    # --- #504 regression net: the speaker-naming window must be PINNED --------
    # It floats + joins all Spaces + shows over full-screen apps so it stays
    # reachable when the user switches apps, instead of being swept away by
    # Stage Manager or a full-screen Space. Assert on the window PROPERTIES, not
    # mere visibility: an un-pinned NSWindow also stays visible on deactivation,
    # so a visibility-only check would stay green even with the fix reverted
    # (vacuous). Reverting NamingWindowPolicy flips floating -> false here, which
    # is what turns this lane red.
    local naming_win=""
    # Capture the speaker-naming window's RPC projection into $naming_win;
    # non-zero if the window is not present.
    _naming_window() {
        assert_app_alive
        naming_win="$(rpc /state | jq -c '[.windows[] | select(.id == "speaker-naming")] | .[0] // empty')"
        [ -n "$naming_win" ]
    }
    # Assert only the environment-STABLE pin properties. `.fullScreenAuxiliary`
    # is deliberately NOT asserted: apply() sets it and it holds on a normal
    # desktop, but on the headless/virtual-display CI mini AppKit normalises it
    # off (observed false there, true on a real display), so asserting it flakes.
    # `.canJoinAllSpaces` already covers cross-Space reachability, and `floating`
    # is the load-bearing stays-on-top property; reverting NamingWindowPolicy
    # flips floating -> false, which still turns this lane red.
    _naming_window_pinned() {
        _naming_window || return 1
        jq -e '.floating and .canJoinAllSpaces' <<<"$naming_win" >/dev/null
    }
    # Phase-2 predicate (used after deactivation): present AND on-screen AND
    # floating. isVisible is the load-bearing new signal a hidesOnDeactivate
    # regression would flip.
    _naming_window_visible_pinned() {
        _naming_window || return 1
        jq -e '.isVisible and .floating' <<<"$naming_win" >/dev/null
    }
    # The window opens asynchronously (.showSpeakerNaming -> bringWindowToFront
    # on the next runloop), so poll rather than assert once.
    log "$label: asserting speaker-naming window is pinned (floating + all-Spaces)"
    poll_until 30 2 _naming_window_pinned \
        || fail "$label: speaker-naming window not pinned (#504 regression): $(rpc /state | jq -c '[.windows[] | select(.id=="speaker-naming")]')"
    log "$label: naming window pinned OK: $naming_win"

    # And it must SURVIVE the app losing focus: bring another app to the front,
    # then re-assert. The pin flags are focus-invariant, so the load-bearing new
    # signal here is isVisible: a "window hides when the app loses focus"
    # regression (e.g. hidesOnDeactivate flipped back on) flips isVisible to
    # false only AFTER deactivation, which phase 1 (app still active) cannot see.
    # RPC + the naming confirm are localhost HTTP, so leaving our menu-bar app
    # in the background does not block the rest of the lane.
    osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
    sleep 2
    # Poll rather than single-shot: a transient localhost RPC hiccup at this one
    # instant would otherwise fail the lane with a misleading "regression"
    # message. A genuine hide-on-deactivate regression stays red the whole window.
    poll_until 20 2 _naming_window_visible_pinned \
        || fail "$label: speaker-naming window not visible + pinned after the app was deactivated (#504 regression): $(rpc /state | jq -c '.windows')"
    log "$label: naming window still visible + pinned after deactivating the app"
    # -------------------------------------------------------------------------

    # Read the naming choice: raw labels + auto-name suggestions + speaking time.
    local naming speaker_count
    naming="$(curl --silent --show-error --max-time 10 \
        --header "Authorization: Bearer $RPC_TOKEN" \
        "$RPC_BASE/v1/jobs/$job_id/naming" 2>/dev/null || echo '{}')"
    echo "$naming" | jq '.' | sed 's/^/    /'
    speaker_count="$(jq -r '.speakers | length' <<<"$naming")"
    [ "${speaker_count:-0}" -ge 2 ] 2>/dev/null \
        || fail "$label: GET naming returned $speaker_count speakers, expected >= 2"

    # Build a mapping assigning ANONYMOUS names (Speaker A, Speaker B, …).
    # Repo rule: never real first names. Keys MUST be the DTO's raw labels so
    # the confirm relabel anchors on the right transcript slots. The parallel
    # arrays (labels, in-transcript suggestions, assigned names) feed the
    # post-confirm assertions.
    local mapping labels_json suggested_json names_json
    mapping="$(jq -c '[.speakers[].label]
        | to_entries
        | map({key: .value, value: ("Speaker " + ([65 + .key] | implode))})
        | from_entries' <<<"$naming")"
    labels_json="$(jq -c '[.speakers[].label]' <<<"$naming")"
    suggested_json="$(jq -c '[.speakers[].suggested]' <<<"$naming")"
    names_json="$(jq -c '[.speakers[].label] | to_entries | map("Speaker " + ([65 + .key] | implode))' <<<"$naming")"
    log "$label: confirming mapping: $mapping"

    local confirm_status
    confirm_status="$(curl --silent --show-error --max-time 10 -o /dev/null -w '%{http_code}' \
        -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$(jq -nc --argjson m "$mapping" '{mapping: $m}')" \
        "$RPC_BASE/v1/jobs/$job_id/naming" 2>/dev/null || echo '000')"
    [ "$confirm_status" = "200" ] || fail "$label: POST naming returned HTTP $confirm_status (expected 200)"
    log "$label: naming confirmed; polling job to a terminal state"

    # Poll GET /v1/jobs/<id> (never /state → no auto-skip) until terminal.
    local state=""
    _job_terminal() {
        assert_app_alive
        state="$(curl --silent --show-error --max-time 10 \
            --header "Authorization: Bearer $RPC_TOKEN" \
            "$RPC_BASE/v1/jobs/$job_id" 2>/dev/null | jq -r '.state // empty')"
        [ "$state" = "done" ] || [ "$state" = "error" ]
    }
    poll_until "$PIPELINE_TIMEOUT_S" 5 _job_terminal \
        || fail "$label: job $job_id did not reach a terminal state within ${PIPELINE_TIMEOUT_S}s"

    local final transcript_path
    final="$(curl --silent --show-error --max-time 10 \
        --header "Authorization: Bearer $RPC_TOKEN" \
        "$RPC_BASE/v1/jobs/$job_id" 2>/dev/null || echo '{}')"
    echo "$final" | jq '.' | sed 's/^/    /'
    [ "$state" = "done" ] || fail "$label: job state=$state, expected done. Error: $(jq -r '.error // "<none>"' <<<"$final")"
    transcript_path="$(jq -r '.transcriptPath // empty' <<<"$final")"
    [ -n "$transcript_path" ] || fail "$label: job has no transcriptPath"
    [ -f "$transcript_path" ] || fail "$label: transcript file missing: $transcript_path"
    log "$label: transcript $transcript_path"
    head -c 600 "$transcript_path" | sed 's/^/    /'
    echo

    # --- Assertion 1: the confirmed names landed as speaker labels ---
    # A transcript line is "[MM:SS] Speaker: text"; the confirm relabel anchors
    # on "] <label>:", so assert on that exact slot form (fixed-string grep).
    local names_present=0 name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if grep -Fq "] $name:" "$transcript_path"; then
            names_present=$((names_present + 1))
        fi
    done < <(jq -r '.[]' <<<"$names_json")
    [ "$names_present" -ge 2 ] \
        || fail "$label: only $names_present assigned name(s) present as speaker labels; expected >= 2 (confirm did not relabel the transcript, the late-rerun rebuild regression)"
    log "$label: $names_present confirmed speaker names present in transcript ✅"

    # --- Assertion 2: raw diarization labels no longer appear ---
    # Both the DTO raw label (SPEAKER_n / R_/M_-prefixed) and its pre-confirm
    # in-transcript suggestion must be gone from every speaker slot.
    local leaked="" raw
    while IFS= read -r raw; do
        [ -n "$raw" ] || continue
        if grep -Fq "] $raw:" "$transcript_path"; then
            leaked="$leaked $raw"
        fi
    done < <(jq -r '.[]' <<<"$labels_json"; jq -r '.[]' <<<"$suggested_json")
    [ -z "$leaked" ] \
        || fail "$label: raw diarization label(s) still present as speaker slots after confirm:$leaked"
    log "$label: no raw diarization labels remain in transcript ✅"

    # --- Assertion 3 (CI only): the speaker DB learned the confirmed voices ---
    # Reliable only against the empty baseline the CI snapshot reset guarantees;
    # a local run starts from the dev's real DB (voices may already match, so a
    # confirm updates in place with no count change). Locally, just log.
    # Retry the readback: a single transient RPC hiccup would leave post_db_count
    # empty and turn the integer comparison into a misleading red.
    local post_db_count="" _i
    for _i in 1 2 3 4 5; do
        post_db_count="$(rpc /state | jq -r '.speakerDB.count // empty' 2>/dev/null || true)"
        [ -n "$post_db_count" ] && break
        sleep 1
    done
    [ -n "$post_db_count" ] || post_db_count=0
    log "$label: speakerDB.count after confirm: $post_db_count (was $pre_db_count)"
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        [ "$post_db_count" -gt "$pre_db_count" ] 2>/dev/null \
            || fail "$label: speakerDB.count did not grow ($pre_db_count → $post_db_count); confirm did not enroll the named voices"
        log "$label: speaker DB learned the confirmed voices ✅"
    fi

    # --- Runtime settings readback ---
    # Re-read /state.settings and confirm the lane didn't drift the app's
    # effective settings mid-run vs the lane-start values. The app instance is
    # stable, so these must match; a diff would mean the pipeline mutated
    # settings unexpectedly. Log-only (a standing lane must not go red on a
    # diagnostic); the exit-trap cleanup separately verifies the persisted
    # UserDefaults + speakers.json are restored to their pre-lane state.
    local end_snap
    end_snap="$(rpc /state)"
    if [ -n "$end_snap" ]; then
        local end_diarize end_num end_record
        end_diarize="$(jq -r '.settings.diarization.diarize' <<<"$end_snap")"
        end_num="$(jq -r '.settings.diarization.numSpeakers' <<<"$end_snap")"
        end_record="$(jq -r '.settings.recording.recordOnly' <<<"$end_snap")"
        if [ "$end_diarize" = "$diarize" ] && [ "$end_num" = "$num_speakers" ] && [ "$end_record" = "$record_only" ]; then
            log "$label: /state.settings unchanged across the lane (diarize=$end_diarize numSpeakers=$end_num recordOnly=$end_record) ✅"
        else
            log "$label: WARNING: /state.settings drifted during the lane: diarize $diarize->$end_diarize, numSpeakers $num_speakers->$end_num, recordOnly $record_only->$end_record"
        fi
    else
        log "$label: (could not re-read /state.settings for the runtime readback)"
    fi

    # Guard against a future regression that enqueues the shared fixture path
    # directly: the pipeline would MOVE it out of Tests/Fixtures and poison
    # every later lane in this checkout. Assert it still exists here so such a
    # bug fails loudly in THIS lane instead of surfacing as a cryptic
    # "fixture not found" in a downstream lane.
    [ -f "$DEFAULT_FIXTURE" ] \
        || fail "$label: shared fixture $DEFAULT_FIXTURE no longer exists after this lane; a consumer moved it. Enqueue a COPY, never the shared Tests/Fixtures path."
    log "$label: shared fixture intact after the lane ✅"
}

# Title-source lane (issue #501): drive the app's window-title lookup with a
# title that is NOT usable — the window title equals the app name, which the
# lookup skips — so PowerAssertionDetector finds no meeting-window title and
# must fall back to the clean "<app> Call" placeholder. Pre-fix the detector
# leaked the raw IOKit assertion name ("Simulator Meeting Call in progress")
# instead, so this assertion fails against the old code (non-vacuous). Proves
# the real deployed detection → title-selection → job-title chain, which the
# unit tests can only exercise through injected seams.
run_title_source() {
    local label="[title-source]"
    log "$label: starting meeting-simulator --title MeetingSimulator (no usable window title) → $SIMULATOR_FIXTURE"
    "$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" --title "MeetingSimulator" >/tmp/e2e-app-sim.log 2>&1 &
    SIM_PID=$!

    _poll_for_new_lastjob_terminal "$label" ignore-recovered
    [ "$POLL_LJ_STATE" = "done" ] || fail "$label: lastJob.state == \"$POLL_LJ_STATE\", expected \"done\""

    local meeting_title
    meeting_title="$(rpc /state | jq -r '.lastJob.meetingTitle // empty')"
    log "$label: lastJob.meetingTitle = \"$meeting_title\""
    [ "$meeting_title" = "MeetingSimulator Call" ] \
        || fail "$label: meetingTitle == \"$meeting_title\", expected \"MeetingSimulator Call\". The window title equalled the app name, so the title lookup should return nil and the detector substitute the placeholder; a leaked assertion name or window title means the title-source fix regressed."
    log "$label: PASS — no usable window title fell back to the clean placeholder ✅"
}

# --- echo-bleed lane ------------------------------------------------------
#
# A dual-source recording made on loudspeakers carries the remote voices on the
# microphone track too, so the same speech is transcribed twice and lands in the
# transcript twice. The pipeline measures that before transcription and reports
# the verdict on GET /v1/jobs/<id>. This lane drives that chain in the deployed
# app: synthesise a pair, enqueue it, read the verdict back.
#
# It cannot record the condition live. The runner is a Mac mini with no
# microphone, only a virtual input device, so there is no acoustic path for a
# loudspeaker to bleed through. The synthesised pair is the better instrument
# anyway: it makes the expected verdict exact instead of a property of the room.
#
# TWO pairs are enqueued, differing by exactly one term. Without the clean
# control the lane would stay green against a detector that answers yes to
# everything, which is the failure mode that actually matters here — a false
# positive tells the user their recording is broken when it is not.
#
# No settings are touched. The verdict does not depend on any of them, so a lane
# that mutates the runner's defaults would add a restore path and a way to leave
# the host dirty for nothing.
# Enqueue one synthesised pair; echoes its job id. Asserts the two files came
# back as ONE job: PairedRecordingResolver has to recognise the _app/_mic stem
# pair, and if it does not the pipeline silently runs two single-source jobs
# that can never be compared against each other, so nothing is ever measured.
_eb_enqueue() {
    local label="$1" dir="$2" stem="$3"
    local enq ids
    enq="$(curl --silent --show-error --max-time 15 -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$(jq -nc --arg a "$dir/${stem}_app.wav" --arg m "$dir/${stem}_mic.wav" '{paths: [$a, $m]}')" \
        "$RPC_BASE/v1/jobs" 2>/dev/null || echo '{}')"
    ids="$(jq -r '.jobIDs | length' <<<"$enq" 2>/dev/null || echo 0)"
    [ "$ids" = "1" ] \
        || fail "$label: POST /v1/jobs returned $ids job(s) for one _app/_mic pair, expected 1 (response: $enq)"
    jq -r '.jobIDs[0]' <<<"$enq"
}

# True once the job carries a verdict, or has settled without one. Settling
# without one is a failure, but it has to be READ as one: polling only for the
# verdict would turn a job that errored in its first second into a timeout, and
# report a two-minute wait instead of the error that caused it.
_eb_settled() {
    assert_app_alive
    # Writes the caller's `_EB_STATUS`: bash locals are dynamically scoped, so
    # the lane declares it and this stashes the last response for the
    # post-loop assertions. Same shape the naming lanes use.
    _EB_STATUS="$(rpc "/v1/jobs/$1")"
    jq -e '.echo != null or .state == "done" or .state == "error"' <<<"$_EB_STATUS" >/dev/null 2>&1
}

# Waits for the verdict on $1 and leaves it in $_EB_STATUS.
_eb_await_verdict() {
    local label="$1" job="$2"
    _EB_STATUS=""
    poll_until "$PIPELINE_TIMEOUT_S" 3 _eb_settled "$job" \
        || fail "$label: job $job produced neither an echo verdict nor a terminal state within ${PIPELINE_TIMEOUT_S}s (last: $_EB_STATUS)"
    jq -e '.echo != null' <<<"$_EB_STATUS" >/dev/null \
        || fail "$label: job $job reached state=$(jq -r '.state // "?"' <<<"$_EB_STATUS") with NO echo verdict. Every dual-source job is measured, so a missing verdict means the tracks never reached the detector. error=$(jq -r '.error // "<none>"' <<<"$_EB_STATUS")"
    log "$label: verdict $(jq -c '.echo' <<<"$_EB_STATUS")"
}

# Let a job finish rather than leaving it parked at speaker naming. Diarization
# is on by default, so an enqueued job parks there and would otherwise outlive
# the lane in the persisted job store, where a later run reads it as its own.
# Best effort: this is teardown, and a job that will not settle is not this
# lane's failure to report.
_eb_settled_or_skipped() {
    local state
    state="$(rpc "/v1/jobs/$1" | jq -r '.state // empty')"
    case "$state" in
        done|error) return 0 ;;
        speakerNamingPending)
            # Same call the naming-escape lane makes; the explicit zero
            # Content-Length matters for a POST with no body.
            curl --silent --show-error --max-time 10 -X POST \
                --header "Authorization: Bearer $RPC_TOKEN" \
                --header "Content-Length: 0" \
                "$RPC_BASE/v1/jobs/$1/naming/skip" >/dev/null 2>&1 || true
            ;;
    esac
    return 1
}
_eb_release() {
    poll_until "$PIPELINE_TIMEOUT_S" 2 _eb_settled_or_skipped "$1" || true
}

# Asserts a verdict was computed over enough windows to mean anything. Shared
# by both pairs: on the affected one it guards against a verdict resting on a
# single lucky window, and on the control it is what stops "not affected" from
# meaning "not enough evidence to say".
_eb_assert_scored() {
    local label="$1" which="$2" status="$3"
    jq -e '.echo.windowsScored >= 3' <<<"$status" >/dev/null \
        || fail "$label: $which scored only $(jq -r '.echo.windowsScored' <<<"$status") window(s); a verdict needs at least 3"
}

run_echo_bleed() {
    local label="[echo-bleed]"
    # Stashed by _eb_settled through bash's dynamic scoping (see there).
    local _EB_STATUS=""
    require_command python3

    local gen="$ROOT/scripts/fixtures/make-echo-pair.py"
    local app_src="$ROOT/app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav"
    local local_src="$ROOT/app/MeetingTranscriber/Tests/Fixtures/three_speakers_de.wav"
    [ -f "$gen" ]       || fail "$label: fixture generator missing: $gen"
    [ -f "$app_src" ]   || fail "$label: fixture missing: $app_src"
    [ -f "$local_src" ] || fail "$label: fixture missing: $local_src"

    # Separate directories per pair. The resolver groups on directory AND stem,
    # so this keeps the two pairs apart no matter what stem names are chosen.
    _EB_FIXTURE_DIR="$(mktemp -d /tmp/e2e-echo-bleed.XXXXXX)"
    local affected_dir="$_EB_FIXTURE_DIR/affected" clean_dir="$_EB_FIXTURE_DIR/clean"
    log "$label: synthesising pairs under $_EB_FIXTURE_DIR"
    python3 "$gen" --app "$app_src" --local "$local_src" --out "$affected_dir" --stem meeting --bleed 1.0 \
        | sed 's/^/    /' || fail "$label: could not synthesise the affected pair"
    python3 "$gen" --app "$app_src" --local "$local_src" --out "$clean_dir" --stem meeting --bleed 0 \
        | sed 's/^/    /' || fail "$label: could not synthesise the clean control"

    # --- affected pair ----------------------------------------------------
    local affected_job
    affected_job="$(_eb_enqueue "$label" "$affected_dir" meeting)"
    log "$label: affected pair enqueued as $affected_job"
    _eb_await_verdict "$label" "$affected_job"
    local affected_status="$_EB_STATUS"

    jq -e '.echo.detected == true' <<<"$affected_status" >/dev/null \
        || fail "$label: affected pair NOT detected. The microphone track is the app track delayed 15 ms at unit gain, which is the condition itself: $(jq -c '.echo' <<<"$affected_status")"
    # Measured 4 of 4 windows on this fixture. Asserting a floor well under that
    # keeps the lane from re-litigating the threshold, while still failing if the
    # verdict decays to a single lucky window.
    _eb_assert_scored "$label" "affected pair" "$affected_status"
    jq -e '.echo.affectedWindowShare >= 0.5' <<<"$affected_status" >/dev/null \
        || fail "$label: affected share $(jq -r '.echo.affectedWindowShare' <<<"$affected_status") below 0.5 (measured 1.0 on this fixture)"
    # The structured verdict and the sentence the user actually sees are separate
    # channels, and only one of them is in front of the person with the problem.
    jq -e '(.warnings | length) >= 1' <<<"$affected_status" >/dev/null \
        || fail "$label: affected job carries the verdict but no warning — the menu-bar channel is silent on a recording the API calls affected"
    log "$label: affected pair detected, share $(jq -r '.echo.affectedWindowShare' <<<"$affected_status") over $(jq -r '.echo.windowsScored' <<<"$affected_status") windows ✅"


    # --- clean control ----------------------------------------------------
    local clean_job
    clean_job="$(_eb_enqueue "$label" "$clean_dir" meeting)"
    log "$label: clean control enqueued as $clean_job"
    _eb_await_verdict "$label" "$clean_job"
    local clean_status="$_EB_STATUS"

    jq -e '.echo.detected == false' <<<"$clean_status" >/dev/null \
        || fail "$label: clean control reported as affected. Its microphone track is the same gated local speech as the affected pair with the bleed term removed, so this is a false positive: $(jq -c '.echo' <<<"$clean_status")"
    _eb_assert_scored "$label" "clean control" "$clean_status"
    jq -e '.echo.windowsAffected == 0' <<<"$clean_status" >/dev/null \
        || fail "$label: clean control has $(jq -r '.echo.windowsAffected' <<<"$clean_status") affected window(s); measured 0, with its hottest window at 0.35 against a 0.7 threshold"
    log "$label: clean control measured over $(jq -r '.echo.windowsScored' <<<"$clean_status") windows and found nothing ✅"

    # --- the verdict has to survive the job finishing ---------------------
    # Finished jobs are reaped from the queue and read back out of the terminal
    # store. A verdict that only exists on the live job is invisible to exactly
    # the caller most likely to look: one polling after the fact.
    _eb_release "$affected_job"
    _eb_release "$clean_job"
    local final
    final="$(rpc "/v1/jobs/$affected_job")"
    local final_state
    final_state="$(jq -r '.state // empty' <<<"$final")"
    [ "$final_state" = "done" ] \
        || fail "$label: affected job settled as '$final_state', expected done. error=$(jq -r '.error // "<none>"' <<<"$final")"
    jq -e '.echo.detected == true' <<<"$final" >/dev/null \
        || fail "$label: the verdict did not survive the job finishing: $(jq -c '.echo' <<<"$final")"
    log "$label: verdict intact on the finished job ✅"

    # The dedup half, asserted here and not next to the verdict above: the
    # verdict is recorded BEFORE transcription, so at the moment it appears the
    # merge that suppresses anything has not run yet and the count is still 0.
    # Reading it there passed against a working build and would have passed
    # against a broken one too.
    #
    # On the count rather than on transcript text: what the engine makes of a
    # bleed copy is not stable enough to grep for, while "how many microphone
    # segments were left out" is exactly the effect, and it is the number a fleet
    # caller reads.
    jq -e '.echo.suppressedSegments >= 1' <<<"$final" >/dev/null \
        || fail "$label: affected pair had nothing suppressed. Its microphone track IS the app track, so every microphone segment is a duplicate: $(jq -c '.echo' <<<"$final")"
    log "$label: $(jq -r '.echo.suppressedSegments' <<<"$final") microphone segment(s) left out of the transcript ✅"

    # The control that stops this from being "drop the microphone track". Without
    # it the lane passes against a build that removes the user's own words from
    # every recording and still leaves a plausible transcript behind.
    local clean_final
    clean_final="$(rpc "/v1/jobs/$clean_job")"
    jq -e '(.echo.suppressedSegments // 0) == 0' <<<"$clean_final" >/dev/null \
        || fail "$label: clean control had $(jq -r '.echo.suppressedSegments' <<<"$clean_final") segment(s) removed. Nothing may be dropped from a recording without bleed: $(jq -c '.echo' <<<"$clean_final")"
    log "$label: clean control kept every microphone segment ✅"

    # The acceptance criterion, stated as plainly as a driver can state it: the
    # transcript still has to say something. Removing duplicates and removing the
    # meeting look identical in every count asserted above, and this pair carries
    # a local speaker the far end never played.
    local transcript
    transcript="$(jq -r '.transcriptPath // empty' <<<"$final")"
    [ -n "$transcript" ] && [ -f "$transcript" ] \
        || fail "$label: finished job has no transcript on disk (transcriptPath=$transcript)"
    local lines
    lines="$(wc -l < "$transcript" | tr -d ' ')"
    [ "${lines:-0}" -ge 2 ] \
        || fail "$label: transcript is down to $lines line(s) after dedup — the local speaker has to survive the far end, not be removed with it"
    log "$label: transcript still carries $lines lines after dedup ✅"
    log "$label: PASS"
}

if [ "$REIMPORT_LATEST" = true ]; then
    # Skip the live-record phase and reuse a WAV produced by an earlier
    # `--record-only --keep-recordings` run on this host. Picks the
    # freshest `*_mix.wav` in $RECORDINGS_DIR — eliminates the audible
    # ~30 s playback + capture round and the meeting-detector cooldown
    # that --reimport-recorded incurs.
    # Pick the freshest *_mix.wav by mtime. A single awk max-pass replaces
    # `sort -rn | head -1`: under `set -o pipefail`, `head` closing the pipe
    # after one line left `sort` writing into a closed pipe → SIGPIPE (exit
    # 141) → `set -e` aborted with "sort: Broken pipe" once two or more
    # recordings had accumulated. awk reads the whole stream, so the upstream
    # find/stat finish cleanly. (`$1` = mtime, `$0` = "mtime path"; cut keeps
    # the path, tolerating spaces.)
    latest_mix="$(find "$RECORDINGS_DIR" -maxdepth 1 -name '*_mix.wav' -type f \
        -exec stat -f '%m %N' {} + 2>/dev/null \
        | awk 'NR == 1 || $1 > newest { newest = $1; line = $0 } END { if (NR) print line }' \
        | cut -d' ' -f2-)"
    [ -n "$latest_mix" ] && [ -f "$latest_mix" ] \
        || fail "--reimport-latest: no *_mix.wav found in $RECORDINGS_DIR — run \`e2e-app.sh --record-only --keep-recordings\` first to produce one"
    log "Reusing latest record-only WAV: $latest_mix"
    # No `sleep $RECORDER_FINALIZE_WAIT_S` here, unlike --reimport-recorded:
    # the WAV was produced by a prior script invocation that already exited,
    # so its AVAudioFile close + tail-byte flush happened on process exit
    # — nothing left to wait for.
    run_one_reimport "[reimport-latest]" "$latest_mix"
elif [ "$REIMPORT_RECORDED" = true ]; then
    # Phase 1: record-only meeting → produces a WAV via the live capture stack.
    run_one_record_only_meeting "[record]"
    [ -n "$LAST_RECORDED_MIX_PATH" ] || fail "record-phase did not surface a mix path; cannot continue"

    # Phase 2: re-import that WAV through the menu's "Open from Recording"
    # entry — same code path NSOpenPanel uses, exposed via RPC. recordOnly
    # is still toggled on but only affects WatchLoop.enqueueRecording, not
    # AppState.enqueueFiles, so the pipeline runs end-to-end.
    log "Sleeping ${RECORDER_FINALIZE_WAIT_S}s before re-import to let recorder finalize tail bytes"
    sleep "$RECORDER_FINALIZE_WAIT_S"
    run_one_reimport "[reimport]" "$LAST_RECORDED_MIX_PATH"
elif [ "$MIC_ONLY" = true ]; then
    # Before the record-only arm: the mic-only lane turns RECORD_ONLY on to
    # reuse its cleanup, so testing RECORD_ONLY first would run the wrong lane.
    run_mic_only
elif [ "$RECORD_ONLY" = true ]; then
    if [ "$TWO_MEETINGS" = true ]; then
        run_one_record_only_meeting "[1/2]"
        log "Sleeping ${INTER_MEETING_COOLDOWN_S}s for WatchLoop cooldown before meeting 2"
        sleep "$INTER_MEETING_COOLDOWN_S"
        run_one_record_only_meeting "[2/2]"
    else
        run_one_record_only_meeting "meeting"
    fi
elif [ "$MIC_DEVICE_CHANGE" = true ]; then
    # Issue #379: the fault-injection build self-triggers a mic device-change
    # restart ~2 s into recording whose tap install uses an invalid format,
    # raising an NSException from installTapOnBus. Pre-fix the app aborts mid
    # recording → the poll loop's assert_app_alive fails before any job lands
    # (RED). Post-fix the app catches + recovers → recording completes → the
    # existing run_one_meeting .done/transcript assertions pass (GREEN).
    log "[mic-device-change] fault-injection build active; app will self-trigger a"
    log "[mic-device-change] mic device-change restart with an invalid tap format mid-recording."
    log "[mic-device-change] PASS = app survives (no SIGABRT) AND recording completes."
    run_one_meeting "[mic-device-change]"
    assert_app_alive
    log "[mic-device-change] app survived the injected device-change restart ✅"
elif [ "$CRASH_RECOVERY" = true ]; then
    run_crash_recovery
elif [ "$NAMING_ESCAPE" = true ]; then
    run_naming_escape
elif [ "$NAMING_CONFIRM" = true ]; then
    run_naming_confirm
elif [ "$TITLE_SOURCE" = true ]; then
    run_title_source
elif [ "$ECHO_BLEED" = true ]; then
    run_echo_bleed
elif [ "$TWO_MEETINGS" = true ]; then
    run_one_meeting "[1/2]"
    log "Sleeping ${INTER_MEETING_COOLDOWN_S}s for WatchLoop cooldown before meeting 2"
    sleep "$INTER_MEETING_COOLDOWN_S"
    run_one_meeting "[2/2]"
else
    run_one_meeting "meeting"
fi

if [ "$APP_AFTER" = quit ]; then
    quit_running_app
fi

log "PASS"
