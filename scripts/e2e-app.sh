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

while [ $# -gt 0 ]; do
    case "$1" in
        --quit-app)     APP_AFTER=quit ;;     # explicit alias for the default
        --keep-app)     APP_AFTER=leave ;;
        --no-build)     NO_BUILD=true ;;
        --fixture)      shift; SIMULATOR_FIXTURE="$1" ;;
        --two-meetings) TWO_MEETINGS=true ;;
        --record-only)  RECORD_ONLY=true ;;
        -h|--help)
            cat <<'HELP'
Usage: e2e-app.sh [--no-build] [--keep-app] [--two-meetings] [--record-only] [--fixture path/to.wav]

  --no-build       Skip build/deploy/re-sign; use ~/Applications/MeetingTranscriber-Dev.app as-is.
  --keep-app       Leave the dev app running on exit. Default: quit it.
  --two-meetings   Run two meetings back-to-back (cooldown + state-reset coverage).
  --record-only    Enable record-only mode: assert on sidecar JSON + mix WAV instead
                   of transcript/protocol. Exercises the WatchLoop branch that
                   skips VAD/transcription/diarization/protocol generation.
  --fixture        Audio fixture for meeting-simulator. Default: two_speakers_de.wav.
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

# WatchLoop's per-app cooldown (`MeetingDetector.swift` cooldownDuration
# = 5 s) plus a 3 s buffer so the second meeting isn't suppressed as a
# re-detection. Bump if MeetingDetector.cooldownDuration grows.
INTER_MEETING_COOLDOWN_S=8

# --- helpers --------------------------------------------------------------

log()  { printf '[e2e-app] %s\n' "$*"; }
fail() { printf '[e2e-app] FAIL: %s\n' "$*" >&2; exit 1; }

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

# Stop any previous dev-app instance before we touch the bundle on disk
# or open a new one. rsync would otherwise overwrite mmap'd mach-o pages,
# and a still-running process holds the RPC port so the next `open` is a
# no-op. Graceful AppleScript quit first, SIGTERM after 3 s, SIGKILL last.
quit_running_app() {
    local bundle_id="com.meetingtranscriber.dev"
    if ! pgrep -f "MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber" >/dev/null; then
        return 0
    fi
    log "Stopping previous MeetingTranscriber-Dev instance"
    osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
    for _ in 1 2 3; do
        pgrep -f "MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber" >/dev/null || return 0
        sleep 1
    done
    pkill -f "MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber" 2>/dev/null || true
    for _ in 1 2 3; do
        pgrep -f "MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber" >/dev/null || return 0
        sleep 1
    done
    pkill -KILL -f "MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber" 2>/dev/null || true
    sleep 1
    if pgrep -f "MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber" >/dev/null; then
        fail "could not stop running MeetingTranscriber-Dev — kill it manually and retry"
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

log "Launching $DEV_BUNDLE_DEPLOY"
open "$DEV_BUNDLE_DEPLOY"

log "Waiting up to ${RPC_READY_TIMEOUT_S}s for RPC /healthz"
deadline=$(( $(date +%s) + RPC_READY_TIMEOUT_S ))
while [ ! -f "$RPC_TOKEN_FILE" ] || ! { RPC_TOKEN="$(cat "$RPC_TOKEN_FILE")" && rpc /healthz >/dev/null; }; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "RPC /healthz did not respond within ${RPC_READY_TIMEOUT_S}s"
    sleep 1
done
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
        # memory `no_destructive_fs_on_real_dirs`.
        if [ -f "$RECORD_ONLY_MARKER" ]; then
            find "$RECORDINGS_DIR" -type f -newer "$RECORD_ONLY_MARKER" -delete 2>/dev/null || true
            rm -f "$RECORD_ONLY_MARKER"
        fi
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

run_one_meeting() {
    local label="$1"
    log "$label: starting meeting-simulator → $SIMULATOR_FIXTURE"
    "$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-app-sim.log 2>&1 &
    SIM_PID=$!

    log "$label: polling /state every 5s for new lastJob (timeout ${PIPELINE_TIMEOUT_S}s)"
    local deadline=$(( $(date +%s) + PIPELINE_TIMEOUT_S ))
    local last_state="" last_id=""
    local lj_id="" lj_state="" pipe_active="" pipe_processing="" pending_naming=""

    while true; do
        # One jq invocation, four fields out via `|`-joined output — saves
        # 3 forks per poll vs separate jq calls.
        #
        # Why `|` and not `@tsv`: bash `IFS=$'\t' read` treats consecutive
        # whitespace separators as ONE (and skips leading empties), so an
        # all-null lastJob (`\t\t0\tfalse`) gets misparsed as `0\tfalse\t\t`.
        # `|` is non-whitespace, so each separator stays a field boundary.
        # Trailing `|| true` keeps the loop alive when rpc() returns empty
        # (transient curl --max-time hit during model load / GC pause):
        # jq emits no output → read hits EOF → returns 1 → `set -e` would
        # otherwise kill the script silently. We just retry next tick.
        lj_id=""; lj_state=""; pipe_active=""; pipe_processing=""; pending_naming=""
        IFS='|' read -r lj_id lj_state pipe_active pipe_processing pending_naming < <(
            rpc /state | jq -r '[.lastJob.jobID // "", .lastJob.state // "", .pipeline.activeJobCount, .pipeline.isProcessing, .pipeline.pendingNamingJobCount] | join("|")'
        ) || true

        # Auto-skip the speaker-naming dialog so headless runs don't deadlock
        # waiting for a UI click. The endpoint drains all pending in one shot
        # and is a no-op when nothing is pending. Fire-and-forget; next tick
        # picks up the resulting state change.
        if [ "${pending_naming:-0}" != "0" ] && [ -n "$pending_naming" ]; then
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

        [ "$(date +%s)" -lt "$deadline" ] || fail "no new pipeline job reached terminal state within ${PIPELINE_TIMEOUT_S}s (active=$pipe_active processing=$pipe_processing)"
        sleep 5
    done

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

    rm -f "$meeting_marker"
}

if [ "$RECORD_ONLY" = true ]; then
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
