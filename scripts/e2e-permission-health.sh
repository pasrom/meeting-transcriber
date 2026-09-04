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
    # By bundle id rather than by pid: `open` hands the launch to launchd, so
    # this script is not the parent of the app it started.
    #
    # `|| true` is load-bearing under `set -e`, and its absence was a
    # regression the pid form did not have: this helper returns non-zero when
    # the app outlives SIGKILL, and a non-zero command in an EXIT trap both
    # abandons the rest of the trap — leaving the stale launchctl entries the
    # next line exists to clear — and overrides a successful run's exit status.
    # Same guard the soak and cpu-load lanes already put on this call.
    quit_running_app || true
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

# `open` routes to the WindowServer of the FOREGROUND Aqua session, so with a
# second user signed in via Fast User Switching it fails with the misleading
# `procNotFound (-600)`. Executing the binary was immune to this, so the check
# arrives with the launch that needs it; e2e-app.sh carries the same one for
# the same reason.
fg_user=$(stat -f "%Su" /dev/console)
my_user=$(id -un)
if [ "$fg_user" != "$my_user" ]; then
    # `root` means the login window is up and nobody is signed in, which is a
    # different fix from another user holding the foreground; naming the wrong
    # one sends the reader to log out a user who is not logged in.
    if [ "$fg_user" = "root" ]; then
        die "no user is signed in at the console (loginwindow), so \`open\` has no Aqua session to route to. Sign '$my_user' in and re-run."
    fi
    die "Aqua foreground user is '$fg_user', not '$my_user' — Fast User Switching is active, and \`open\` would fail with a bare -600. Log '$fg_user' out completely, then re-run."
fi

# Through `open`, the way e2e-app.sh launches the app and the way a user does,
# NOT by executing the binary. That distinction decides what this script
# measures, which is the whole point of it. (Same method, different copy: that
# lane opens the deployed bundle, this one the freshly built workspace copy.)
#
# Measured on the granted runner, same bundle, same CDHash, three reads each at
# 8, 20 and 35 seconds so it is not a startup race:
#
#   "$BIN" &     ->  microphone=notDetermined  screenRecording=denied
#   open "$APP"  ->  microphone=healthy        screenRecording=healthy
#
# Executed directly the process is not the app launchd knows, so TCC answers for
# something the grants were never made against. This lane then reported the
# runner as ungranted while every recording lane on the same host was recording
# happily, and its own failure text sent the reader off to re-grant a permission
# that was never missing.
#
# `--env` rather than a leading `env`, which `open` does not carry through, and
# rather than writing the two as UserDefaults, which would need a restore path
# and would leave the host altered if this exits badly.
#
# `--args --auto-watch` asks for the very thing the environment then suppresses,
# and that is deliberate: it is what makes the check after the permission read
# able to fail at all. `autoWatch` defaults to FALSE when the key is unset, so on
# a fresh runner or any developer machine the app would not watch even with the
# suppression dropped, and a check for "not watching" would pass while proving
# nothing. The flag establishes the precondition per launch instead of leaning on
# whatever a previous lane left in this host's defaults, and it leaves nothing
# behind. Suppression wins over it in the app, which is exactly the ordering
# being tested.
open --env MEETINGTRANSCRIBER_DEBUG_RPC=1 \
    --env MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH=1 \
    "$APP" --args --auto-watch

# --- 4. Wait for RPC server to come up (max 30 s) ------------------------

echo "▸ Waiting for RPC on 127.0.0.1:9876…"
wait_for_rpc "$MTCLI" 30 || die "RPC server did not start within 30 s"
# The process ANSWERING has to be the bundle this script named, and existence is
# not enough to show that. `DebugRPCServer.start()` logs a failed bind and leaves
# the app running, so a release build with the automation API on — plausible on a
# developer machine, where it sits in the menu bar — keeps port 9876, the
# workspace copy comes up beside it without a server, and every permission
# verdict read below would describe the release build's TCC identity. That is the
# misattribution this whole lane exists to catch, so it is asked about the port
# rather than about the process table.
rpc_pid="$(/usr/sbin/lsof -ti :9876 -sTCP:LISTEN 2>/dev/null | head -1)"
[ -n "$rpc_pid" ] || die "nothing is listening on 9876 although the RPC poll succeeded"
ps -p "$rpc_pid" -o command= 2>/dev/null | grep -qF "$BIN" \
    || die "port 9876 is held by pid $rpc_pid ($(ps -p "$rpc_pid" -o comm= 2>/dev/null)), not by $BIN — the permission verdicts below would describe that process, not the bundle this lane built. Quit the other MeetingTranscriber and re-run."
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

# The launch environment actually arrived. Without this the lane cannot tell a
# working `open --env` from a silently ignored one: `debugRPCEnabled` is left
# true in this host's defaults by the e2e-app lanes, so the RPC server comes up
# either way and the lane would pass while measuring an app launched with none
# of the environment it asked for. Auto-watch is the observable half —
# suppressed, no watch loop exists and the field stays absent; unsuppressed on a
# host whose `autoWatch` default is true, it reads "watching".
#
# Its own wait, and that is the point of it being here rather than folded into
# the poll above. Written that way first, it could not fail: the permission loop
# returns as soon as the microphone field is populated, about two seconds in,
# and the watch loop needs longer to say anything. Measured on the runner with
# the environment deliberately dropped: absent at 2 s, "watching" by 7 s, steady
# after. Twelve seconds is that with room, and it is spent only on runs that go
# on to pass.
echo "▸ Confirming the launch environment reached the app…"
for _ in $(seq 1 24); do
    if "$MTCLI" state 2>/dev/null | jq -e '.watchState == "watching"' >/dev/null 2>&1; then
        die "the app is watching, so MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH did not reach it — open --env is not delivering the launch environment, and what this lane measured is not what it configured"
    fi
    sleep 0.5
done
# A negative check cannot tell "it never happened" from "nobody was there to make
# it happen". Without this, an app that died at second three of the window would
# be reported as one that stayed politely idle, and the lane would go green on
# the snapshot taken before the crash.
assert_app_alive "$BIN"


# --- 6. Assert the #446-fixed probes report healthy ----------------------

# A "broken" verdict here is a #446 regression (probe false-flagged a granted
# permission). "denied" or "notDetermined" means either the app is being asked
# about an identity the grants were not made against, or a grant really did
# lapse.
#
# The recording lanes are evidence about which, not proof. A microphone stuck at
# notDetermined blocks `ensureMicrophoneAccess()` on the prompt and times the
# first recording lane out; a DENIED one returns immediately and the lane fails
# later, on the mic track carrying no signal. Screen Recording is weaker still:
# the audio tap accepts either that grant or the separate audio-capture one, so
# a host holding both could lose Screen Recording with every recording lane
# staying green. Lanes green therefore says "suspect attribution first", not
# "attribution, certainly".
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
    die "permission probe not healthy: 'broken' = #446 regression; 'denied'/'notDetermined' = either the app was launched in a way TCC attributes elsewhere, or the grant lapsed on the runner (re-grant in the GUI session, see CLAUDE.md). Recording lanes green in the same run points at the first, but does not settle it for Screen Recording, which the audio tap can do without"
fi

echo "OK — Screen Recording + Microphone probes report healthy on the granted runner"
