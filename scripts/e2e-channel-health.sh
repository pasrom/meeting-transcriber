#!/usr/bin/env bash
# E2E test for the per-channel signal indicator (issue #258).
#
# Launches the dev .app with `MEETINGTRANSCRIBER_DEBUG_FORCE_MIC_SILENT=1` so
# `AppState.micSilentActive` is set at init, then asserts via the DebugRPCServer
# that `channelHealth.micSilent == true` in `/state`. Optionally screencaptures
# the menubar region for visual proof.
#
# What this covers:
#   - Env-hook propagation into AppState init
#   - @Observable property → SwiftUI scene body wiring
#   - DebugRPCServer state snapshot exposes the channel-health flags
#   - Pixel-level visual regression: with --screenshot, asserts the
#     menubar actually renders red-tinted pixels via assert-red-pixels.swift
#
# What this does NOT cover (see docs/plans/.local/open/2026-05-17-channel-health-live-e2e.md):
#   - Real CATapDescription tap → LevelPublisher → polling task → flag flip
#   - The polling task lifecycle (start/cancel on `.recording` transitions)
#   - `.recovered` event path (flag clears back to false on channel unmute)
#   - macOS Notification delivery on `.started` events
#   - Real-world false-positive resistance during legitimate recordings
#
# Runs on:
#   - Any macOS host with Xcode + zsh + jq
#   - Local dev (no permissions needed beyond what a fresh build needs)
#   - CI: GitHub-hosted macos-26 runner or the self-hosted Mac mini
#
# Usage: bash scripts/e2e-channel-health.sh [--no-build] [--screenshot]

set -euo pipefail

NO_BUILD=false
TAKE_SCREENSHOT=false

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build)   NO_BUILD=true ;;
        --screenshot) TAKE_SCREENSHOT=true ;;
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
APP="$ROOT/app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app"
BIN="$APP/Contents/MacOS/MeetingTranscriber"
MTCLI="$ROOT/tools/mt-cli/.build/debug/mt-cli"

cleanup() {
    if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -9 "$APP_PID" 2>/dev/null || true
    fi
    bootout_stale_launchctl
}
trap cleanup EXIT

# --- 1. Build (unless --no-build) ----------------------------------------

if [ "$NO_BUILD" = false ]; then
    echo "▸ Building dev bundle…"
    "$ROOT/scripts/run_app.sh" --build-only >/dev/null
fi

[ -x "$BIN" ] || die "dev binary not found at $BIN — run without --no-build first"

if [ ! -x "$MTCLI" ]; then
    echo "▸ Building mt-cli…"
    (cd "$ROOT/tools/mt-cli" && swift build >/dev/null)
fi

# --- 2. Kill any running instance + clear launchctl ----------------------

quit_running_app
bootout_stale_launchctl

# --- 3. Launch with debug env hooks --------------------------------------

# `_SUPPRESS_AUTOWATCH=1` prevents the +3 s auto-watch trigger from running
# `stopChannelHealthMonitoring()` which would clear the forced flag before
# we can observe it.
env MEETINGTRANSCRIBER_DEBUG_RPC=1 \
    MEETINGTRANSCRIBER_DEBUG_FORCE_MIC_SILENT=1 \
    MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH=1 \
    "$BIN" &
APP_PID=$!

# --- 4. Wait for RPC server to come up (max 30 s) ------------------------

echo "▸ Waiting for RPC on 127.0.0.1:9876…"
wait_for_rpc "$MTCLI" 30 || die "RPC server did not start within 30 s"
echo "  RPC up"

# --- 5. Assert channelHealth state ---------------------------------------

STATE_JSON="$("$MTCLI" state)"
read -r MIC_SILENT APP_SILENT < <(
    echo "$STATE_JSON" | jq -r '"\(.channelHealth.micSilent) \(.channelHealth.appSilent)"'
)

echo "▸ channelHealth: micSilent=$MIC_SILENT appSilent=$APP_SILENT"

if [ "$MIC_SILENT" != "true" ]; then
    echo "Full state JSON:" >&2
    echo "$STATE_JSON" | jq . >&2
    die "channelHealth.micSilent expected 'true', got '$MIC_SILENT'"
fi

[ "$APP_SILENT" = "false" ] || die "channelHealth.appSilent expected 'false', got '$APP_SILENT'"

# --- 6. Optional visual proof --------------------------------------------

if [ "$TAKE_SCREENSHOT" = true ]; then
    OUT="/tmp/e2e-channel-health-menubar.png"
    # `screencapture` can fail on headless GUI sessions (rare; Mac mini CI
    # runner has an Aqua session via auto-login so it works there). When it
    # does succeed, run the pixel-level assertion so a SwiftUI/MenuBarIcon
    # render regression that keeps the AppState flag true but doesn't show
    # the red tint is caught here.
    if screencapture -R 0,0,3000,30 "$OUT" 2>/dev/null && [ -s "$OUT" ]; then
        echo "▸ Menubar screenshot saved to $OUT"
        "$ROOT/scripts/assert-red-pixels.swift" "$OUT"
    else
        echo "▸ Menubar screenshot skipped (no display rect available — pixel assertion skipped)"
        rm -f "$OUT"
    fi
fi

echo "OK — env-hook + RPC observability verified"
echo "Notes: real audio path, polling-task lifecycle, and notification delivery are"
echo "       covered by unit tests; live-audio e2e is a separate follow-up."
