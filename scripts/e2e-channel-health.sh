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
# What this does NOT cover:
#   - The polling task lifecycle (start/cancel on `.recording` transitions)
#   - `.recovered` event path (flag clears back to false on channel unmute)
#   - Real-world false-positive resistance during legitimate recordings
#
# The first two are covered by scripts/e2e-channel-fault.sh, which drives the
# real CATapDescription tap → LevelPublisher → polling task chain and asserts
# on what is notified. Note that as of issue #614 a latched episode does NOT
# notify by itself: the notification follows the capture fault, not the
# silence episode.
#
# Runs on:
#   - Any macOS host with Xcode + zsh + jq
#   - Local dev (no permissions needed beyond what a fresh build needs;
#     --screenshot additionally needs every permission the app checks to
#     report healthy, since the red permission badge would satisfy the
#     pixel check on its own, and fails otherwise)
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
# Ends what a timed-out earlier step left running, then records this
# driver for the next (see e2e_register_driver).
e2e_register_driver
APP="$ROOT/app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app"
BIN="$APP/Contents/MacOS/MeetingTranscriber"
MTCLI="$ROOT/tools/mt-cli/.build/debug/mt-cli"

cleanup() {
    # Started through `open`, so it is no child of this shell and has no PID
    # here; found by the pattern assert_app_alive uses and ended by PID. Only
    # once this lane launched it, so an early exit leaves alone an instance it
    # never started. Quiet: an app that already exited is no failure here.
    [ -z "${APP_LAUNCHED:-}" ] || kill_and_verify_gone "MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber" 5 2>/dev/null || true
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
#
# `open --env`, not the binary directly: TCC answers for the process launchd
# knows, and an executable started from this shell is asked about an identity
# the grants were never made against. The app then reports a permission
# problem and draws its red badge, which the pixel check below would count as
# the channel tint.
assert_console_user
# Set before the launch: an `open` that fails after the app already started
# must still be cleaned up.
APP_LAUNCHED=1
open --env MEETINGTRANSCRIBER_DEBUG_RPC=1 \
    --env MEETINGTRANSCRIBER_DEBUG_FORCE_MIC_SILENT=1 \
    --env MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH=1 \
    "$APP"

# --- 4. Wait for RPC server to come up (max 30 s) ------------------------

echo "▸ Waiting for RPC on 127.0.0.1:9876…"
wait_for_rpc "$MTCLI" 30 || die "RPC server did not start within 30 s"
echo "  RPC up"

# --- 5. Assert channelHealth state ---------------------------------------

STATE_JSON="$(state_query .)" || die "$(state_why $? "the channelHealth assertions")"
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
    # The permission badge is red too, and on its own it clears the pixel
    # threshold, so red pixels prove the channel tint only while no permission
    # problem is shown. Wait for the app's check to report, then require it
    # healthy. Not ruled out here: the other red marks the icon can carry (the
    # record-only dot, the error badge) and red elsewhere in the captured strip.
    echo "▸ Waiting for the app's permission health check…"
    status=0
    poll_state --each assert_app_alive 20 0.5 permission_health_reported || status=$?
    case "$status" in
        0) ;;
        1) die "the app answered /state but its permission health check reported nothing within 20 s, so whether the red permission badge is drawn is unknown and the pixel check cannot be read" ;;
        *) die "$(state_why "$status" "whether the app reports a permission problem")" ;;
    esac
    if [ "$(jq -r '.permissionHealth.isHealthy' <<<"$STATE_BODY")" != "true" ]; then
        echo "permissionHealth:" >&2
        jq .permissionHealth <<<"$STATE_BODY" >&2 || true
        die "the app reports a permission problem, so its menu bar icon carries the red permission badge and the red-pixel check would pass on the badge alone. Fix: $(tcc_fix_hint 'the pane named above' "$APP")"
    fi

    OUT="/tmp/e2e-channel-health-menubar.png"
    # `screencapture` can fail on headless GUI sessions (rare; Mac mini CI
    # runner has an Aqua session via auto-login so it works there). When it
    # does succeed, run the pixel-level assertion so a SwiftUI/MenuBarIcon
    # render regression that keeps the AppState flag true but doesn't show
    # the red tint is caught here.
    #
    # SwiftUI's MenuBarExtra → NSStatusItem composite can trail RPC readiness
    # by 1-2 frames, so the assertion is polled rather than run once. Cold
    # `swift` invocation per attempt provides the natural pacing.
    if ! screencapture -R 0,0,3000,30 "$OUT" 2>/dev/null || [ ! -s "$OUT" ]; then
        # Through host_skip, so a scheduled run that asked for the pixel
        # assertion does not read a skipped one as a pass.
        host_skip channel-health "screencapture produced no image of the menu bar (no display, or this process may not record the screen), so the red-pixel assertion did not run. Fix: $(tcc_fix_hint 'Screen & System Audio Recording')"
        rm -f "$OUT"
    else
        attempt=1
        max_attempts=25
        while [ "$attempt" -le "$max_attempts" ]; do
            if [ "$attempt" -eq "$max_attempts" ]; then
                # Final attempt: unsuppressed so the pixel count and FAIL
                # message surface on exhaustion (set -e propagates).
                echo "▸ Menubar screenshot saved to $OUT (attempt $attempt/$max_attempts)"
                "$ROOT/scripts/assert-red-pixels.swift" "$OUT"
                break
            fi
            if "$ROOT/scripts/assert-red-pixels.swift" "$OUT" >/dev/null 2>&1; then
                echo "▸ Menubar screenshot saved to $OUT (attempt $attempt/$max_attempts)"
                break
            fi
            attempt=$((attempt + 1))
            screencapture -R 0,0,3000,30 "$OUT" 2>/dev/null || true
        done
    fi
fi

echo "OK — env-hook + RPC observability verified"
echo "Notes: real audio path, polling-task lifecycle, and notification delivery are"
echo "       covered by unit tests; live-audio e2e is a separate follow-up."
