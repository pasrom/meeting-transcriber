#!/usr/bin/env bash
# CPU/RAM load measurement for the running production app.
#
# Complements e2e-app.sh (functional pipeline assertion) with a RESOURCE
# assertion: how much CPU/RAM does the deployed dev .app consume in three
# states, measured across two app sessions:
#   (1) idle in watch mode (default profile, no model preloaded),
#   (2) recording a meeting WITHOUT live captions (the default user),
#   (3) recording a meeting WITH live captions (the heaviest realistic
#       steady state, separate session so the preload is part of launch).
# This is the lane that catches "app burns CPU in the menu bar and users
# complain" regressions before a release does.
#
# Measurement principle: `GET /metrics` (DebugRPCServer) self-reports the
# process's CUMULATIVE counters via proc_pid_rusage — CPU seconds, phys
# footprint, retired instructions, billed energy. Two snapshots around a
# window give exact averages (kernel bookkeeping, no %CPU sampling noise):
#
#   avg CPU % = delta(cpuUser + cpuSystem) / delta(monotonicTime) * 100
#
# Gating policy: log everything, gate ONLY a deliberately generous
# catastrophe bound on idle CPU (busy-loop catcher). Real thresholds come
# later, derived from observed run-to-run variance — never guessed.
#
# Runs on the same self-hosted Mac runner as e2e-app.sh and reuses the
# same one-time TCC setup (scripts/setup-self-hosted-runner.sh).

set -euo pipefail

# --- args -----------------------------------------------------------------

APP_AFTER=quit           # quit | leave
NO_BUILD=false
SIMULATOR_FIXTURE=""
IDLE_WINDOW_S=60
ACTIVE_WINDOW_S=25
IDLE_MAX_CPU_PCT=50

while [ $# -gt 0 ]; do
    case "$1" in
        --quit-app)         APP_AFTER=quit ;;
        --keep-app)         APP_AFTER=leave ;;
        --no-build)         NO_BUILD=true ;;
        --fixture)          shift; SIMULATOR_FIXTURE="$1" ;;
        --idle-window)      shift; IDLE_WINDOW_S="$1" ;;
        --active-window)    shift; ACTIVE_WINDOW_S="$1" ;;
        --idle-max-cpu)     shift; IDLE_MAX_CPU_PCT="$1" ;;
        -h|--help)
            cat <<'HELP'
Usage: e2e-cpu-load.sh [--no-build] [--keep-app] [--fixture path/to.wav]
                       [--idle-window SECONDS] [--active-window SECONDS]
                       [--idle-max-cpu PERCENT]

  --no-build           Skip build/deploy/re-sign; use ~/Applications/MeetingTranscriber-Dev.app as-is.
  --keep-app           Leave the dev app running on exit. Default: quit it.
  --fixture            Audio fixture for meeting-simulator. Default: two_speakers_de.wav.
  --idle-window        Idle measurement window in seconds (default 60).
  --active-window      Length of EACH in-meeting window in seconds (default 25
                       — must fit inside the fixture's remaining play time).
  --idle-max-cpu       Catastrophe gate: max average idle CPU %% (default 50).
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
REC_DIR="$HOME/Library/Application Support/MeetingTranscriber/recordings"
RPC_BASE="http://127.0.0.1:9876"
BUNDLE_ID="com.meetingtranscriber.dev"

[ -n "$SIMULATOR_FIXTURE" ] || SIMULATOR_FIXTURE="$DEFAULT_FIXTURE"

# --- timing budgets -------------------------------------------------------

RPC_READY_TIMEOUT_S=30
# Launch-time work (model preload, snapshot load, orphan-recovery scan) must
# finish before the idle window or it pollutes the idle numbers.
SETTLE_TIMEOUT_S=120
# Time from simulator start to first finalised live caption — proves the
# heavy live path (tap -> resampler -> VAD -> engine) is actually running
# before the live-captions window starts.
CAPTION_DEADLINE_S=90
# Time from simulator start to watchState == "recording" — gates the
# captions-off window, where no caption signal exists.
RECORDING_DEADLINE_S=60

# --- helpers --------------------------------------------------------------

log()  { printf '[e2e-cpu-load] %s\n' "$*"; }
fail() { printf '[e2e-cpu-load] FAIL: %s\n' "$*" >&2; exit 1; }

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

# Fetch /metrics and verify it looks like a metrics snapshot. The explicit
# non-empty guard matters: jq 1.6 exits 0 on EMPTY input even with -e
# (fixed in 1.7 to exit 4) — without it a timed-out curl would masquerade
# as a valid snapshot.
metrics_snapshot() {
    local m
    m="$(rpc /metrics)"
    { [ -n "$m" ] && jq -e '.monotonicTimeSeconds > 0' <<<"$m" >/dev/null 2>&1; } \
        || fail "/metrics returned no usable snapshot: $m"
    printf '%s' "$m"
}

# Compute window averages from two cumulative snapshots.
# $1 = start JSON, $2 = end JSON; prints a one-object JSON summary.
window_delta() {
    jq -n --argjson a "$1" --argjson b "$2" '
        (($b.monotonicTimeSeconds - $a.monotonicTimeSeconds)) as $dt
        | if $dt <= 0 then error("non-positive window: \($dt)") else . end
        | {
            windowSeconds:        ($dt * 100 | round / 100),
            avgCpuPercent:        (((($b.cpuUserSeconds + $b.cpuSystemSeconds)
                                     - ($a.cpuUserSeconds + $a.cpuSystemSeconds))
                                    / $dt * 100) * 100 | round / 100),
            instructionsPerSec:   (($b.instructions - $a.instructions) / $dt | round),
            avgPowerMilliwatts:   ((($b.billedEnergyNanojoules - $a.billedEnergyNanojoules)
                                    / $dt / 1e6) * 10 | round / 10),
            physFootprintMB:      ($b.physFootprintBytes / 1048576 | round),
            physFootprintDeltaMB: (($b.physFootprintBytes - $a.physFootprintBytes) / 1048576 | round),
            lifetimeMaxFootprintMB: ($b.lifetimeMaxPhysFootprintBytes / 1048576 | round)
        }'
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

SAVED_LIVE_TRANS=$(snapshot_default "$BUNDLE_ID" liveTranscriptionEnabled)
SAVED_TRANS_ENGINE=$(snapshot_default "$BUNDLE_ID" transcriptionEngine)
SAVED_DEBUG_RPC=$(snapshot_default "$BUNDLE_ID" debugRPCEnabled)
SAVED_AUTO_WATCH=$(snapshot_default "$BUNDLE_ID" autoWatch)
SAVED_RECORD_ONLY=$(snapshot_default "$BUNDLE_ID" recordOnly)

quit_running_app

# A stale persisted pipeline job (e.g. session B's post-processing from the
# previous run) would keep the settle gate busy for minutes. GUARDED to CI
# via $GITHUB_ACTIONS — never set in a developer's shell; removes ONLY the
# regenerable queue snapshot (same pattern as e2e-app.sh).
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    _ipc_dir="$HOME/Library/Application Support/MeetingTranscriber/ipc"
    rm -f "$_ipc_dir/pipeline_queue.json" "$_ipc_dir/pipeline_queue.tmp"
    log "CI: reset stale pipeline-queue snapshot"
fi

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

# --- session plumbing -------------------------------------------------------

fg_user=$(stat -f "%Su" /dev/console)
my_user=$(id -un)
if [ "$fg_user" != "$my_user" ]; then
    fail "Aqua foreground user is '$fg_user', not '$my_user' — Fast User Switching is active."
fi

_rpc_ready() { [ -f "$RPC_TOKEN_FILE" ] && RPC_TOKEN="$(cat "$RPC_TOKEN_FILE")" && rpc /healthz >/dev/null 2>&1; }

launch_app_and_wait() {
    log "Launching $DEV_BUNDLE_DEPLOY"
    open "$DEV_BUNDLE_DEPLOY"
    log "Waiting up to ${RPC_READY_TIMEOUT_S}s for RPC /healthz"
    poll_until "$RPC_READY_TIMEOUT_S" 1 _rpc_ready \
        || fail "RPC /healthz did not respond within ${RPC_READY_TIMEOUT_S}s"
    log "RPC up"
}

# Timestamp anchor for on_exit cleanup: every recording artifact this run
# creates is newer than this marker file.
RUN_START_MARKER="$(mktemp "${TMPDIR:-/tmp}/e2e-cpu-load-start.XXXXXX")"

SIM_PID=""
on_exit() {
    [ -n "${SIM_PID:-}" ] && kill "$SIM_PID" 2>/dev/null || true
    restore_bool_default "$BUNDLE_ID" liveTranscriptionEnabled "$SAVED_LIVE_TRANS"
    if [ -n "$SAVED_TRANS_ENGINE" ]; then
        defaults write "$BUNDLE_ID" transcriptionEngine -string "$SAVED_TRANS_ENGINE"
    else
        defaults delete "$BUNDLE_ID" transcriptionEngine 2>/dev/null || true
    fi
    restore_bool_default "$BUNDLE_ID" debugRPCEnabled "$SAVED_DEBUG_RPC"
    restore_bool_default "$BUNDLE_ID" autoWatch       "$SAVED_AUTO_WATCH"
    restore_bool_default "$BUNDLE_ID" recordOnly      "$SAVED_RECORD_ONLY"
    if [ "$APP_AFTER" = quit ]; then
        # `|| true`: under set -e a wedged app (quit ladder exhausted) must not
        # abort the trap before the artifact sweep below runs.
        quit_running_app || true
        # The lane's recordings are measurement garbage, and quitting the app
        # mid-grace orphans raw temps. Sweep this run's artifacts so the next
        # run's app doesn't crash-recover a stale temp into a garbage job (the
        # rationale + the CI guard live in sweep_run_artifacts).
        sweep_run_artifacts "$REC_DIR" "$RUN_START_MARKER"
    fi
    rm -f "${RUN_START_MARKER:-}" 2>/dev/null || true
}
trap on_exit EXIT INT TERM

# All RPC predicates carry the non-empty guard: jq 1.6 exits 0 on EMPTY
# input even with -e, so a timed-out `rpc /state` would otherwise count
# as a satisfied predicate.

_pipeline_drained() {
    local state
    state="$(rpc /state)"
    [ -n "$state" ] && jq -e \
        '.pipeline.isProcessing == false and .pipeline.activeJobCount == 0' \
        <<<"$state" >/dev/null 2>&1
}

# Pipeline state tracks JOBS, not model loads — the Parakeet preload that
# liveTranscriptionEnabled triggers at launch is only visible here.
_model_loaded() {
    local state
    state="$(rpc /state)"
    [ -n "$state" ] && jq -e '.engines.parakeet.modelState == "loaded"' \
        <<<"$state" >/dev/null 2>&1
}

_recording_active() {
    local state
    state="$(rpc /state)"
    [ -n "$state" ] && jq -e '.watchState == "recording"' <<<"$state" >/dev/null 2>&1
}

_live_path_hot() {
    [ "$(rpc /state | jq -r '.liveCaptions.recentFinals | length' 2>/dev/null)" -gt 0 ] 2>/dev/null
}

# Snapshot → sleep → snapshot → print the window summary JSON.
measure_window() {
    local secs="$1" start end
    assert_app_alive
    start="$(metrics_snapshot)"
    sleep "$secs"
    assert_app_alive
    end="$(metrics_snapshot)"
    window_delta "$start" "$end"
}

# "true" when the meeting state degraded inside the window: recording
# stopped (meeting ended early) or post-processing started. Either mixes
# non-steady-state load into the numbers — flagged, not failed, per the
# log-first policy.
contamination_flag() {
    local flag
    flag="$(rpc /state | jq -r \
        '(.watchState != "recording") or .pipeline.isProcessing or (.pipeline.activeJobCount > 0)' \
        2>/dev/null)"
    if [ "$flag" = "true" ]; then printf 'true'; else printf 'false'; fi
}

# === session A: default profile (live captions OFF, record-only) ============
# What a stock-configuration user runs: watching + recording, no live
# transcription, no model preloaded. recordOnly keeps the meeting end cheap
# (file move instead of batch transcription) so session B starts quiet; the
# recording path itself is byte-identical to a normal meeting while it runs.

defaults write "$BUNDLE_ID" liveTranscriptionEnabled -bool false
defaults write "$BUNDLE_ID" recordOnly -bool true
defaults write "$BUNDLE_ID" transcriptionEngine -string parakeet
defaults write "$BUNDLE_ID" debugRPCEnabled -bool true
defaults write "$BUNDLE_ID" autoWatch -bool true

launch_app_and_wait

log "Session A settle: waiting up to ${SETTLE_TIMEOUT_S}s for pipeline to drain"
poll_until "$SETTLE_TIMEOUT_S" 5 _pipeline_drained \
    || fail "pipeline still busy after ${SETTLE_TIMEOUT_S}s — stale recovered jobs?"
# Extra settle for what no RPC field can see: page-ins, launch tails.
sleep 10

log "Window 1/3 — idle: ${IDLE_WINDOW_S}s (watching, no meeting, default profile)"
IDLE_SUMMARY="$(measure_window "$IDLE_WINDOW_S")"
log "Idle summary:"
jq . <<<"$IDLE_SUMMARY" | sed 's/^/    /'

log "Starting meeting-simulator → $SIMULATOR_FIXTURE"
"$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-cpu-load-sim.log 2>&1 &
SIM_PID=$!

log "Waiting for recording to start (watchState == recording, timeout ${RECORDING_DEADLINE_S}s)"
poll_until "$RECORDING_DEADLINE_S" 2 _recording_active \
    || fail "recording never started within ${RECORDING_DEADLINE_S}s — detector or TCC problem?"

log "Window 2/3 — recording WITHOUT live captions: ${ACTIVE_WINDOW_S}s"
REC_SUMMARY="$(measure_window "$ACTIVE_WINDOW_S")"
REC_CONTAMINATED="$(contamination_flag)"
log "Recording (captions off) summary:"
jq . <<<"$REC_SUMMARY" | sed 's/^/    /'
[ "$REC_CONTAMINATED" = "false" ] \
    || log "WARNING: meeting ended or pipeline woke inside the captions-off window"

kill "$SIM_PID" 2>/dev/null || true
SIM_PID=""
quit_running_app

# === session B: live-captions profile (heaviest realistic steady state) =====
# Fresh session so the Parakeet preload happens at launch like it would for
# a user with the feature enabled — and so session A's idle window stayed
# free of preload memory/CPU.

defaults write "$BUNDLE_ID" liveTranscriptionEnabled -bool true
defaults write "$BUNDLE_ID" recordOnly -bool false

launch_app_and_wait

log "Session B settle: waiting up to ${SETTLE_TIMEOUT_S}s for pipeline drain + Parakeet preload"
poll_until "$SETTLE_TIMEOUT_S" 5 _pipeline_drained \
    || fail "pipeline still busy after ${SETTLE_TIMEOUT_S}s"
poll_until "$SETTLE_TIMEOUT_S" 5 _model_loaded \
    || fail "Parakeet preload didn't finish within ${SETTLE_TIMEOUT_S}s"
# Extra settle for what no RPC field can see: CoreML compile tail, page-ins.
sleep 10

log "Starting meeting-simulator → $SIMULATOR_FIXTURE (session B)"
{ echo "=== session B ==="; } >>/tmp/e2e-cpu-load-sim.log
"$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >>/tmp/e2e-cpu-load-sim.log 2>&1 &
SIM_PID=$!

log "Waiting for first finalised caption (proves live path is hot, timeout ${CAPTION_DEADLINE_S}s)"
poll_until "$CAPTION_DEADLINE_S" 3 _live_path_hot \
    || fail "no finalised caption within ${CAPTION_DEADLINE_S}s — live path never became active"

log "Window 3/3 — recording WITH live captions: ${ACTIVE_WINDOW_S}s"
LIVE_SUMMARY="$(measure_window "$ACTIVE_WINDOW_S")"
LIVE_CONTAMINATED="$(contamination_flag)"
log "Recording (captions on) summary:"
jq . <<<"$LIVE_SUMMARY" | sed 's/^/    /'
[ "$LIVE_CONTAMINATED" = "false" ] \
    || log "WARNING: meeting ended or post-processing started inside the captions-on window"

kill "$SIM_PID" 2>/dev/null || true
SIM_PID=""

# Machine-readable single line for trend collection. Consumers MUST parse
# with jq by key (e.g. `.liveCaptions.avgCpuPercent`) — key order is not a
# stable contract, positional/regex extraction will silently break.
jq -cn --argjson idle "$IDLE_SUMMARY" \
    --argjson rec "$REC_SUMMARY" --argjson live "$LIVE_SUMMARY" \
    --argjson recContaminated "$REC_CONTAMINATED" \
    --argjson liveContaminated "$LIVE_CONTAMINATED" \
    '{kind: "cpu-load-summary", idle: $idle,
      recording: $rec, recordingContaminated: $recContaminated,
      liveCaptions: $live, liveCaptionsContaminated: $liveContaminated}' \
    | sed 's/^/[e2e-cpu-load] RESULT /'

# --- gate: catastrophe bound only -------------------------------------------

# Deliberately generous: this catches a busy-loop/animation-runaway class of
# regression (the "users complain" case), not a 10% drift. Tightening comes
# after trend data establishes real variance — never from guesses.
# Single jq pass extracts the value and evaluates the bound together —
# same collapsed-adjacent-passes pattern e2e-live-captions.sh uses.
IFS=$'\t' read -r IDLE_CPU idle_ok < <(
    jq -r --arg max "$IDLE_MAX_CPU_PCT" \
        '[.avgCpuPercent, (.avgCpuPercent <= ($max | tonumber))] | @tsv' <<<"$IDLE_SUMMARY"
)
[ "$idle_ok" = "true" ] \
    || fail "idle CPU ${IDLE_CPU}% exceeds catastrophe bound ${IDLE_MAX_CPU_PCT}% — busy loop?"

log "PASS — idle ${IDLE_CPU}% CPU (bound ${IDLE_MAX_CPU_PCT}%); recording + live-captions windows logged for trend"

# App quit + recording-artifact cleanup happen in on_exit (EXIT trap), so
# failure paths get the same hygiene as the happy path.
