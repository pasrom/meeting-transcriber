#!/usr/bin/env bash
# E2E test for the permission-health probes (issue #446 follow-up).
#
# Launches the dev .app and asserts, via the DebugRPCServer /state snapshot, that
# the Screen Recording and Microphone permission probes report "healthy" on a
# runner where those permissions are granted. This is a natural reproduction of
# the #446 false-`.broken` bugs:
#   - Screen Recording: granted, but the old window-title probe reported `.broken`
#     when no foreign window title was readable (the default on recent macOS).
#   - Microphone: granted (BlackHole 2ch is the runner's default input), but the
#     old amplitude probe reported `.broken` because an idle input delivers
#     silent buffers.
# After the fix both must be "healthy" (the probes trust the system verdict /
# buffer flow rather than an incidental signal).
#
# What this covers:
#   - PermissionHealthCheck.runLive() against real TCC + real audio hardware
#   - PermissionStatus → RPC /state.permissionHealth wiring
#   - The #446 fixes holding on the real (silent-input, granted) runner
#
# Requires: granted Microphone + Screen Recording for the dev .app (see the
# self-hosted runner setup in CLAUDE.md). Accessibility is logged, not asserted —
# its grant is not part of the standard runner setup.
#
# Usage: bash scripts/e2e-permission-health.sh [--no-build]

set -euo pipefail

NO_BUILD=false
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) NO_BUILD=true ;;
        -h | --help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            exit 2
            ;;
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

# --- 3. Launch (suppress auto-watch so the app stays idle) ---------------

env MEETINGTRANSCRIBER_DEBUG_RPC=1 \
    MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH=1 \
    "$BIN" &
APP_PID=$!

# --- 4. Wait for RPC server to come up (max 30 s) ------------------------

echo "▸ Waiting for RPC on 127.0.0.1:9876…"
wait_for_rpc "$MTCLI" 30 || die "RPC server did not start within 30 s"
echo "  RPC up"

# --- 5. Wait for the async permission check to populate (max 20 s) -------

echo "▸ Waiting for the permission health check to run…"
SR=""
MIC=""
AX=""
STATE_JSON=""
for _ in $(seq 1 40); do
    # Tolerate a transient fetch mid-poll: the loop exists to wait out
    # not-yet-ready state, so a single failure must retry, not abort under
    # `set -e` (`|| true` on the assignment, empty-guard before the read).
    STATE_JSON="$("$MTCLI" state 2>/dev/null || true)"
    [ -n "$STATE_JSON" ] || {
        sleep 0.5
        continue
    }
    read -r SR MIC AX < <(
        echo "$STATE_JSON" | jq -r \
            '"\(.permissionHealth.screenRecording) \(.permissionHealth.microphone) \(.permissionHealth.accessibility)"'
    ) || true
    [ "$MIC" != "unknown" ] && break
    sleep 0.5
done

echo "▸ permissionHealth: screenRecording=$SR microphone=$MIC accessibility=$AX"

# --- 6. Assert the #446-fixed probes report healthy ----------------------

# A "broken" verdict here is a #446 regression (probe false-flagged a granted
# permission). A "denied" verdict means the grant lapsed on the runner (re-grant
# in the GUI session — see CLAUDE.md). Either way the probe is not healthy.
fail=false
[ "$SR" = "healthy" ] || {
    echo "  ✗ screenRecording expected 'healthy', got '$SR'" >&2
    fail=true
}
[ "$MIC" = "healthy" ] || {
    echo "  ✗ microphone expected 'healthy', got '$MIC'" >&2
    fail=true
}
echo "  (accessibility=$AX — informational, not asserted)"

if [ "$fail" = true ]; then
    echo "Full permissionHealth JSON:" >&2
    echo "$STATE_JSON" | jq .permissionHealth >&2 || true
    die "permission probe not healthy: 'broken' = #446 regression, 'denied' = grant lapsed on runner"
fi

echo "OK — Screen Recording + Microphone probes report healthy on the granted runner"
