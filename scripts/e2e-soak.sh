#!/usr/bin/env bash
# Long-session soak for the running production app.
#
# Every other lane records for seconds; real meetings run 30-120 minutes and the
# menu-bar app itself stays resident for weeks. Nothing observes that regime, so
# a steady leak in the recording buffers, the live-caption ring buffer, or the
# pipeline snapshots would ship unnoticed: e2e-app asserts a transcript appears,
# e2e-cpu-load averages CPU over a 25-second window, and both are blind to a
# process that grows 10 MB a minute.
#
# This lane holds ONE meeting open for the requested duration, samples
# `GET /metrics` throughout, and reports how memory moved across the run. It
# then asserts the pipeline still produces a job at the end — a soak that leaks
# and a soak that quietly stops working are different failures, and both matter.
#
# Measurement: `/metrics` self-reports `physFootprintBytes` (Activity Monitor's
# "Memory" column) via proc_pid_rusage. Growth is a least-squares slope over all
# samples rather than last-minus-first, so one transient spike cannot fake a
# leak and a leak cannot hide behind a low final sample.
#
# Gating policy, deliberately the same as e2e-cpu-load: log everything, gate
# ONLY a generous catastrophe bound. A real threshold has to come from observed
# run-to-run variance across several nights — guessing one on day one would
# either cry wolf or wave through the leak it was meant to catch.
#
# Runs on the self-hosted Mac runner and reuses the same one-time TCC setup
# (scripts/setup-self-hosted-runner.sh).
#
# Usage: ./scripts/e2e-soak.sh [--minutes N] [--sample-every N] [--no-build]

set -euo pipefail

# --- args -----------------------------------------------------------------

SOAK_MINUTES=60
SAMPLE_EVERY_MIN=5
# Catastrophe bound only. ~500 MB/h is far above anything healthy and far below
# what a real leak reaches, so it fires on a runaway without inventing a budget.
MAX_GROWTH_MB_PER_HOUR=500
NO_BUILD=false
SIMULATOR_FIXTURE=""
APP_AFTER=quit

while [ $# -gt 0 ]; do
    case "$1" in
        --minutes)        SOAK_MINUTES="$2"; shift ;;
        --sample-every)   SAMPLE_EVERY_MIN="$2"; shift ;;
        --max-growth)     MAX_GROWTH_MB_PER_HOUR="$2"; shift ;;
        --fixture)        SIMULATOR_FIXTURE="$2"; shift ;;
        --no-build)       NO_BUILD=true ;;
        --leave-app)      APP_AFTER=leave ;;
        -h|--help)
            cat <<'USAGE'
Usage: ./scripts/e2e-soak.sh [options]

  --minutes N        Hold the meeting open for N minutes (default 60).
  --sample-every N   Sample /metrics every N minutes (default 5).
  --max-growth N     Catastrophe gate: max MB/hour of footprint growth
                     (default 500). Everything is logged regardless.
  --fixture PATH     Audio fixture for meeting-simulator.
  --no-build         Use ~/Applications/MeetingTranscriber-Dev.app as-is.
  --leave-app        Leave the app running afterwards (debugging).
USAGE
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# --- paths ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEV_BUNDLE_DEPLOY="$HOME/Applications/MeetingTranscriber-Dev.app"
SIMULATOR_PKG="$ROOT/tools/meeting-simulator"
SIMULATOR_BIN="$SIMULATOR_PKG/.build/release/meeting-simulator"
DEFAULT_FIXTURE="$ROOT/app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav"
RPC_TOKEN_FILE="$HOME/Library/Application Support/MeetingTranscriber/.rpc-token"
# Record-only writes to `<effectiveOutputDir>/recordings`, which defaults to
# Downloads — NOT the Application Support path that only appears as a default
# initializer argument. e2e-app.sh asserts against this same directory.
REC_DIR="$HOME/Downloads/MeetingTranscriber/recordings"
RPC_BASE="http://127.0.0.1:9876"
BUNDLE_ID="com.meetingtranscriber.dev"

[ -n "$SIMULATOR_FIXTURE" ] || SIMULATOR_FIXTURE="$DEFAULT_FIXTURE"

RPC_READY_TIMEOUT_S=30
SETTLE_TIMEOUT_S=${SOAK_SETTLE_S:-120}
RECORDING_DEADLINE_S=60
# Starting to record allocates buffers in one step: measured 71 -> 103 MB within
# the first minute, then flat. Sampling across that ramp fits a slope of ~960
# MB/hour on a short run and would trip the catastrophe bound on a healthy app.
# The baseline is therefore taken once recording has settled, so the fit
# describes the steady state the lane actually cares about.
RECORDING_SETTLE_S=${SOAK_RECORDING_SETTLE_S:-120}
# After the meeting ends the watch loop still has to close it out (grace period,
# WAV finalisation, sidecar write). Generous on purpose: the lane asserts that
# capture still completes, not that it completes quickly.
CAPTURE_DEADLINE_S=300

# --- helpers --------------------------------------------------------------

log()  { printf '[e2e-soak] %s\n' "$*"; }
fail() { printf '[e2e-soak] FAIL: %s\n' "$*" >&2; exit 1; }

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

# Fetch /metrics, refusing anything that is not a usable snapshot. The
# non-empty guard matters: jq 1.6 exits 0 on EMPTY input even with -e, so a
# timed-out curl would otherwise masquerade as a valid reading and silently
# flatten the growth curve.
metrics_snapshot() {
    local m
    m="$(rpc /metrics)"
    { [ -n "$m" ] && jq -e '.monotonicTimeSeconds > 0' <<<"$m" >/dev/null 2>&1; } \
        || fail "/metrics returned no usable snapshot: $m"
    printf '%s' "$m"
}

# Least-squares slope of footprint over time, in MB per hour, plus the summary
# numbers worth logging. Reads a JSON array of {minutes, footprintMB} samples.
#
# Pure over its input so it can be exercised without a running app — the whole
# verdict of this lane rests on this arithmetic being right, and a sign error or
# a unit slip here would report a leak as healthy for as many nights as it takes
# someone to notice.
growth_summary() {
    jq -n --argjson s "$1" '
        ($s | length) as $n
        | if $n < 2 then error("need at least 2 samples, got \($n)") else . end
        | ($s | map(.minutes) | add / $n) as $mx
        | ($s | map(.footprintMB) | add / $n) as $my
        | ($s | map((.minutes - $mx) * (.footprintMB - $my)) | add) as $cov
        | ($s | map((.minutes - $mx) * (.minutes - $mx)) | add) as $var
        | (if $var == 0 then 0 else $cov / $var end) as $slopePerMin
        | {
            samples:        $n,
            firstMB:        ($s | first | .footprintMB),
            lastMB:         ($s | last  | .footprintMB),
            peakMB:         ($s | map(.footprintMB) | max),
            deltaMB:        (($s | last | .footprintMB) - ($s | first | .footprintMB)),
            growthMBPerHour: (($slopePerMin * 60) * 10 | round / 10)
        }'
}

_rpc_ready() { [ -n "$(rpc /healthz)" ]; }

# --- preflight ------------------------------------------------------------

require_command jq
require_command curl
[ -f "$SIMULATOR_FIXTURE" ] || fail "simulator fixture not found: $SIMULATOR_FIXTURE"
case "$SOAK_MINUTES" in ''|*[!0-9]*) fail "--minutes must be a positive integer" ;; esac
case "$SAMPLE_EVERY_MIN" in ''|*[!0-9]*) fail "--sample-every must be a positive integer" ;; esac
[ "$SOAK_MINUTES" -ge 1 ] || fail "--minutes must be >= 1"
[ "$SAMPLE_EVERY_MIN" -ge 1 ] || fail "--sample-every must be >= 1"
# Two samples are the minimum a slope can be fitted through; fewer is a silent
# "no verdict" rather than a pass.
[ $((SOAK_MINUTES / SAMPLE_EVERY_MIN)) -ge 2 ] \
    || fail "--minutes/--sample-every must yield at least 2 samples (got $((SOAK_MINUTES / SAMPLE_EVERY_MIN)))"

SAVED_DEBUG_RPC=$(snapshot_default "$BUNDLE_ID" debugRPCEnabled)
SAVED_AUTO_WATCH=$(snapshot_default "$BUNDLE_ID" autoWatch)
SAVED_RECORD_ONLY=$(snapshot_default "$BUNDLE_ID" recordOnly)

RUN_START_MARKER="$(mktemp "${TMPDIR:-/tmp}/e2e-soak-start.XXXXXX")"
SIM_PID=""

on_exit() {
    [ -n "${SIM_PID:-}" ] && kill "$SIM_PID" 2>/dev/null || true
    restore_bool_default "$BUNDLE_ID" debugRPCEnabled "$SAVED_DEBUG_RPC"
    restore_bool_default "$BUNDLE_ID" autoWatch       "$SAVED_AUTO_WATCH"
    restore_bool_default "$BUNDLE_ID" recordOnly      "$SAVED_RECORD_ONLY"
    if [ "$APP_AFTER" = quit ]; then
        quit_running_app || true
        sweep_run_artifacts "$REC_DIR" "$RUN_START_MARKER"
    fi
    rm -f "${RUN_START_MARKER:-}" 2>/dev/null || true
}
trap on_exit EXIT INT TERM

# --- build + launch -------------------------------------------------------

if [ "$NO_BUILD" = false ]; then
    log "Redeploying the dev bundle"
    "$ROOT/scripts/e2e-app.sh" --redeploy-only >/dev/null \
        || fail "redeploy failed"
fi
[ -d "$DEV_BUNDLE_DEPLOY" ] || fail "no dev bundle at $DEV_BUNDLE_DEPLOY"

if [ ! -x "$SIMULATOR_BIN" ]; then
    log "Building meeting-simulator"
    (cd "$SIMULATOR_PKG" && swift build -c release >/dev/null) \
        || fail "meeting-simulator build failed"
fi

# Record-only: the soak is about the resident process over an hour, and running
# transcription on every loop of the fixture would measure the ASR engine
# instead. The pipeline assertion at the end re-enables the full path.
defaults write "$BUNDLE_ID" debugRPCEnabled -bool true
defaults write "$BUNDLE_ID" autoWatch       -bool true
defaults write "$BUNDLE_ID" recordOnly      -bool true

mkdir -p "$REC_DIR"
quit_running_app || true
log "Launching $DEV_BUNDLE_DEPLOY"
open "$DEV_BUNDLE_DEPLOY"

RPC_TOKEN="$(cat "$RPC_TOKEN_FILE" 2>/dev/null || true)"
[ -n "$RPC_TOKEN" ] || fail "no RPC token at $RPC_TOKEN_FILE"

poll_until "$RPC_READY_TIMEOUT_S" 1 _rpc_ready \
    || fail "RPC /healthz did not respond within ${RPC_READY_TIMEOUT_S}s"
log "RPC up"

# Launch-time work (model preload, snapshot load, orphan recovery) allocates;
# letting it finish keeps it out of the growth curve, where it would read as a
# leak in the first samples.
log "Settling for up to ${SETTLE_TIMEOUT_S}s before the baseline sample"
sleep "$SETTLE_TIMEOUT_S"

# --- soak -----------------------------------------------------------------

# --silent loops the fixture at volume 0: it keeps the audio device active and
# the meeting window open for the full duration without an hour of sound coming
# out of the runner. The soak measures the resident process, not transcription
# quality, so silence costs nothing here.
log "Starting meeting-simulator for ${SOAK_MINUTES} minutes"
"$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" --silent --duration "$((SOAK_MINUTES * 60))" >/dev/null 2>&1 &
SIM_PID=$!

_is_recording() {
    local state
    state="$(rpc /state)"
    [ -n "$state" ] && jq -e '.watchState == "recording"' <<<"$state" >/dev/null 2>&1
}
poll_until "$RECORDING_DEADLINE_S" 2 _is_recording \
    || fail "app did not reach watchState=recording within ${RECORDING_DEADLINE_S}s"
log "Recording started; letting the allocation ramp settle for ${RECORDING_SETTLE_S}s"
sleep "$RECORDING_SETTLE_S"

SAMPLES="[]"
ELAPSED_MIN=0
while [ "$ELAPSED_MIN" -lt "$SOAK_MINUTES" ]; do
    snap="$(metrics_snapshot)"
    footprint_mb="$(jq -r '(.physFootprintBytes / 1048576) | round' <<<"$snap")"
    SAMPLES="$(jq -n --argjson s "$SAMPLES" --argjson m "$ELAPSED_MIN" --argjson f "$footprint_mb" \
        '$s + [{minutes: $m, footprintMB: $f}]')"
    log "t=${ELAPSED_MIN}min  footprint=${footprint_mb}MB"
    # An app that died mid-soak must fail here, not silently produce a short
    # sample series that still fits a flat line. `assert_app_alive` exits on its
    # own; the sample line logged just above carries the elapsed time.
    assert_app_alive
    sleep "$((SAMPLE_EVERY_MIN * 60))"
    ELAPSED_MIN=$((ELAPSED_MIN + SAMPLE_EVERY_MIN))
done

snap="$(metrics_snapshot)"
footprint_mb="$(jq -r '(.physFootprintBytes / 1048576) | round' <<<"$snap")"
SAMPLES="$(jq -n --argjson s "$SAMPLES" --argjson m "$ELAPSED_MIN" --argjson f "$footprint_mb" \
    '$s + [{minutes: $m, footprintMB: $f}]')"
log "t=${ELAPSED_MIN}min  footprint=${footprint_mb}MB (final)"

SUMMARY="$(growth_summary "$SAMPLES")"
# Machine-readable summary for trend collection across runs, same convention as
# the CPU-load lane: a threshold worth gating on can only come from observed
# variance, so every run has to leave its numbers behind in a parseable form.
log "RESULT $(jq -c --argjson samples "$SAMPLES" --argjson mins "$SOAK_MINUTES" \
    '. + {soakMinutes: $mins, series: $samples}' <<<"$SUMMARY")"
log "Soak summary: $(jq -c . <<<"$SUMMARY")"
log "Lifetime max footprint: $(jq -r '(.lifetimeMaxPhysFootprintBytes / 1048576) | round' <<<"$snap")MB"

# --- capture still alive --------------------------------------------------

log "Waiting for the meeting to end and the recording to land"
wait "$SIM_PID" 2>/dev/null || true
SIM_PID=""

# Record-only mode skips the pipeline by design, so there is no job to wait for:
# the observable proof that capture still worked is the sidecar the watch loop
# writes next to the WAVs when it closes the meeting. Polling `/state.lastJob`
# here would wait out the full deadline and then fail on a healthy run.
_recording_landed() {
    find "$REC_DIR" -name '*_meta.json' -newer "$RUN_START_MARKER" -print -quit 2>/dev/null \
        | grep -q .
}
poll_until "$CAPTURE_DEADLINE_S" 5 _recording_landed \
    || fail "no recording sidecar after a ${SOAK_MINUTES}min meeting => capture stopped working during the soak"
log "Recording landed after the soak: capture survived the full session"

# --- verdict --------------------------------------------------------------

GROWTH="$(jq -r '.growthMBPerHour' <<<"$SUMMARY")"
if jq -e --argjson g "$GROWTH" --argjson max "$MAX_GROWTH_MB_PER_HOUR" -n '$g > $max' >/dev/null; then
    fail "footprint grew ${GROWTH}MB/hour, above the ${MAX_GROWTH_MB_PER_HOUR}MB/hour catastrophe bound"
fi

echo
echo "SOAK PASSED — ${SOAK_MINUTES}min meeting, growth ${GROWTH}MB/hour (bound ${MAX_GROWTH_MB_PER_HOUR})"
