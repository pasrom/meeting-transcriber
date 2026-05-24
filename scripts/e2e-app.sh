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
RECORD_ONLY=false        # validate record-only mode (sidecar+WAV instead of transcript)
REIMPORT_RECORDED=false  # chain a record-only meeting with re-import via POST /action/enqueueFile
REIMPORT_LATEST=false    # skip live-record phase, re-import the freshest *_mix.wav already on disk
KEEP_RECORDINGS=false    # leave record-only output on disk for a follow-up --reimport-latest run

while [ $# -gt 0 ]; do
    case "$1" in
        --quit-app)         APP_AFTER=quit ;;     # explicit alias for the default
        --keep-app)         APP_AFTER=leave ;;
        --no-build)         NO_BUILD=true ;;
        --fixture)          shift; SIMULATOR_FIXTURE="$1" ;;
        --two-meetings)     TWO_MEETINGS=true ;;
        --record-only)      RECORD_ONLY=true ;;
        --reimport-recorded) REIMPORT_RECORDED=true ;;
        --reimport-latest)  REIMPORT_LATEST=true ;;
        --keep-recordings)  KEEP_RECORDINGS=true ;;
        -h|--help)
            cat <<'HELP'
Usage: e2e-app.sh [--no-build] [--keep-app] [--two-meetings] [--record-only]
                  [--reimport-recorded | --reimport-latest] [--keep-recordings]
                  [--fixture path/to.wav]

  --no-build           Skip build/deploy/re-sign; use ~/Applications/MeetingTranscriber-Dev.app as-is.
  --keep-app           Leave the dev app running on exit. Default: quit it.
  --two-meetings       Run two meetings back-to-back (cooldown + state-reset coverage).
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

# --- timing budgets -------------------------------------------------------

# Cold first run downloads ~50 MB Parakeet model — give it room. Hot run
# under 10 s easily.
RPC_READY_TIMEOUT_S=30
PIPELINE_TIMEOUT_S=240

# Record-only skips the whole pipeline, so the budget is just: detector
# notices the simulator stopped (~1 s poll) + endGrace (≥1 s) + recorder
# finalize (~3 s) + sidecar write (instant). 60 s gives ample buffer.
RECORD_ONLY_DEADLINE_S=60

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
    # setup-self-hosted-runner.sh.
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

if [ ! -x "$SIMULATOR_BIN" ]; then
    log "Building meeting-simulator"
    (cd "$SIMULATOR_PKG" && swift build -c release)
fi

# `autoWatch` triggers the same `.autoWatchStart` notification an
# explicit "Start Watching" menu click would — necessary because that
# menu isn't reachable over SSH. `debugRPCEnabled` brings the RPC up at
# launch instead of after a Settings toggle.
defaults write com.meetingtranscriber.dev debugRPCEnabled -bool true
defaults write com.meetingtranscriber.dev autoWatch -bool true

if [ "$RECORD_ONLY" = true ]; then
    log "Enabling record-only mode (no transcript/protocol generation)"
    defaults write com.meetingtranscriber.dev recordOnly -bool true
    mkdir -p "$RECORDINGS_DIR"
    touch "$RECORD_ONLY_MARKER"
else
    # Reset stale toggle from a previous --record-only run on the same host
    # so a plain `--two-meetings` invocation isn't silently still in record-only.
    defaults delete com.meetingtranscriber.dev recordOnly 2>/dev/null || true
fi

# Optional diarizer-mode override. `MTT_DIARIZER_MODE=sortformer` flips the
# dev .app into Sortformer mode for this run — used by the Sortformer-naming
# lane to assert that Phase 1 of issue #165 (post-hoc WeSpeaker embeddings)
# actually lights up the naming dialog in production-chain. Always cleared
# on exit so subsequent runs return to the default `.offline` mode.
#
# `defaults write com.meetingtranscriber.dev` from outside writes to the
# *standard* preferences domain. The dev .app's bundle has a pre-existing
# container at `~/Library/Containers/com.meetingtranscriber.dev/...` —
# from a prior App Store-variant build or interactive use — and macOS
# routes the app's UserDefaults reads to that container regardless of
# whether the current binary is sandboxed. A naïve `defaults write` is
# silently a no-op there. Write to both: container if it exists (covers
# this runner) AND standard domain (covers a clean runner where the
# container hasn't been created yet).
_CONTAINER_PLIST="$HOME/Library/Containers/com.meetingtranscriber.dev/Data/Library/Preferences/com.meetingtranscriber.dev.plist"
_set_dev_default() {
    local key="$1" value="$2" type="${3:-string}"
    if [ "$type" = "bool" ]; then
        defaults write com.meetingtranscriber.dev "$key" -bool "$value" 2>/dev/null || true
        [ -f "$_CONTAINER_PLIST" ] && defaults write "$_CONTAINER_PLIST" "$key" -bool "$value" 2>/dev/null || true
    else
        defaults write com.meetingtranscriber.dev "$key" "$value" 2>/dev/null || true
        [ -f "$_CONTAINER_PLIST" ] && defaults write "$_CONTAINER_PLIST" "$key" "$value" 2>/dev/null || true
    fi
}
_delete_dev_default() {
    local key="$1"
    defaults delete com.meetingtranscriber.dev "$key" 2>/dev/null || true
    [ -f "$_CONTAINER_PLIST" ] && defaults delete "$_CONTAINER_PLIST" "$key" 2>/dev/null || true
}
if [ -n "${MTT_DIARIZER_MODE:-}" ]; then
    log "Overriding diarizerMode=$MTT_DIARIZER_MODE for this run"
    _set_dev_default diarizerMode "$MTT_DIARIZER_MODE"
else
    _delete_dev_default diarizerMode
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
on_exit() {
    [ -n "${SIM_PID:-}" ] && kill "$SIM_PID" 2>/dev/null || true
    if [ "$RECORD_ONLY" = true ]; then
        defaults delete com.meetingtranscriber.dev recordOnly 2>/dev/null || true
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
}
trap on_exit EXIT INT TERM

# Trigger one meeting, poll until a new pipeline job reaches a terminal
# state, assert it landed in `done` with a non-trivial transcript. Reads
# `$1` as a human label for log lines ("meeting 1 of 2", etc.). Mutates
# `PRE_LAST_JOB_ID` so the next call recognises the next job as new.
PRE_LAST_JOB_ID=""
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
    log "$label: polling /state every 5s for new lastJob (timeout ${PIPELINE_TIMEOUT_S}s)"
    local deadline=$(( $(date +%s) + PIPELINE_TIMEOUT_S ))
    local last_state="" last_id=""
    local lj_id="" lj_state="" pipe_active="" pipe_processing="" pending_naming=""

    while true; do
        # Fail fast if the dev .app died — otherwise the loop just sees
        # the `|| true` swallow rpc/state errors and we'd burn the full
        # ${PIPELINE_TIMEOUT_S}s before surfacing as "no new pipeline
        # job reached terminal state", masking the real crash.
        assert_app_alive

        lj_id=""; lj_state=""; pipe_active=""; pipe_processing=""; pending_naming=""
        IFS='|' read -r lj_id lj_state pipe_active pipe_processing pending_naming < <(
            rpc /state | jq -r '[.lastJob.jobID // "", .lastJob.state // "", .pipeline.activeJobCount, .pipeline.isProcessing, .pipeline.pendingNamingJobCount] | join("|")'
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

        if [ -n "$lj_id" ] && [ "$lj_id" != "$PRE_LAST_JOB_ID" ] \
            && { [ "$lj_state" = "done" ] || [ "$lj_state" = "error" ]; }; then
            break
        fi

        [ "$(date +%s)" -lt "$deadline" ] || fail "$label: no new pipeline job reached terminal state within ${PIPELINE_TIMEOUT_S}s (active=$pipe_active processing=$pipe_processing)"
        sleep 5
    done

    POLL_LJ_ID="$lj_id"
    POLL_LJ_STATE="$lj_state"
}

run_one_meeting() {
    local label="$1"
    # Reset between meetings so --two-meetings captures each run's first
    # observed naming-dialog speaker count, not just meeting 1's stale value.
    OBSERVED_NAMING_SPEAKERS=""
    log "$label: starting meeting-simulator → $SIMULATOR_FIXTURE"
    "$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-app-sim.log 2>&1 &
    SIM_PID=$!

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

    log "$label: transcript $transcript_path ($transcript_size bytes)"
    log "$label: preview:"
    head -c 500 "$transcript_path" | sed 's/^/    /'

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
        if .version != 1 then "version != 1 (got: \(.version))"
        elif (.startedAt | type) != "string" then "startedAt not string"
        elif (.stoppedAt | type) != "string" then "stoppedAt not string"
        elif (.startedAt | fromdateiso8601? // -1) < 0 then "startedAt not ISO8601"
        elif (.stoppedAt | fromdateiso8601? // -1) < 0 then "stoppedAt not ISO8601"
        elif (.stoppedAt | fromdateiso8601) <= (.startedAt | fromdateiso8601) then "stoppedAt <= startedAt"
        elif (.files.mix // "") == "" then "files.mix missing"
        elif (.files.mix | endswith("_mix.wav") | not) then "files.mix doesn'\''t end with _mix.wav (got: \(.files.mix))"
        else "ok"
        end
    ' "$sidecar")"
    [ "$schema_check" = "ok" ] || fail "$label: sidecar schema invalid: $schema_check"

    # Mix WAV must live next to the sidecar and be non-trivial.
    local sidecar_dir mix_filename mix_path mix_size
    sidecar_dir="$(dirname "$sidecar")"
    mix_filename="$(jq -r '.files.mix' "$sidecar")"
    mix_path="$sidecar_dir/$mix_filename"
    [ -f "$mix_path" ] || fail "$label: mix WAV not found: $mix_path"
    mix_size="$(wc -c <"$mix_path" | tr -d ' ')"
    # 16 kHz mono Float32 = 64 KB/sec. Fixture two_speakers_de.wav is ~10 s
    # → expect > 64 KB even after worst-case truncation.
    [ "$mix_size" -gt 65536 ] || fail "$label: mix WAV suspiciously small: $mix_size bytes (expected > 64 KB)"
    log "$label: mix WAV $mix_path ($mix_size bytes)"

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

if [ "$REIMPORT_LATEST" = true ]; then
    # Skip the live-record phase and reuse a WAV produced by an earlier
    # `--record-only --keep-recordings` run on this host. Picks the
    # freshest `*_mix.wav` in $RECORDINGS_DIR — eliminates the audible
    # ~30 s playback + capture round and the meeting-detector cooldown
    # that --reimport-recorded incurs.
    latest_mix="$(find "$RECORDINGS_DIR" -maxdepth 1 -name '*_mix.wav' -type f \
        -exec stat -f '%m %N' {} + 2>/dev/null \
        | sort -rn \
        | head -1 \
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
elif [ "$RECORD_ONLY" = true ]; then
    if [ "$TWO_MEETINGS" = true ]; then
        run_one_record_only_meeting "[1/2]"
        log "Sleeping ${INTER_MEETING_COOLDOWN_S}s for WatchLoop cooldown before meeting 2"
        sleep "$INTER_MEETING_COOLDOWN_S"
        run_one_record_only_meeting "[2/2]"
    else
        run_one_record_only_meeting "meeting"
    fi
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
