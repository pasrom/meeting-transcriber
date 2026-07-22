#!/usr/bin/env bash
# Live browser-meeting E2E driver for the Meeting Transcriber dev app (issue #503).
#
# Proves the browser-detection + capture chain end-to-end, WITHOUT a real
# meeting service, account, or second participant:
#
#   Chrome + local WebRTC-tone fixture
#     → PowerAssertionDetector (assertion "WebRTC has active PeerConnections")
#     → consent gate (watchState stays "watching", a prompt parks)
#     → RPC confirmBrowserConsent (stands in for the un-clickable notification)
#     → record-only capture (noMic)
#     → sidecar + _app.wav
#     → ASSERT: _app.wav is NOT silent (the CATap actually tapped Chrome audio)
#
# Runs on the same self-hosted Mac mini as e2e-app.sh. Detection uses the
# power-assertion path (no Screen Recording needed) and consent is answered
# over RPC (no clickable notification needed), so it works headless. Chrome
# must be installed; no mic is needed (noMic) and TCC audio-capture grants are
# the same ones e2e-app.sh relies on.
#
# See CLAUDE.md > E2E architecture, and scripts/setup-self-hosted-runner.sh.

set -euo pipefail

# --- args -----------------------------------------------------------------

NO_BUILD=false     # skip build/deploy/re-sign — use ~/Applications bundle as-is
KEEP_APP=false     # leave the dev app running on exit
KEEP_CHROME=false  # leave the fixture Chrome instance open on exit

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build)    NO_BUILD=true ;;
        --keep-app)    KEEP_APP=true ;;
        --keep-chrome) KEEP_CHROME=true ;;
        -h|--help)
            cat <<'HELP'
Usage: e2e-browser.sh [--no-build] [--keep-app] [--keep-chrome]

  --no-build     Skip build/deploy/re-sign; use ~/Applications/MeetingTranscriber-Dev.app as-is.
  --keep-app     Leave the dev app running on exit (default: quit it).
  --keep-chrome  Leave the fixture Chrome instance open on exit (default: quit it).
HELP
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# --- paths ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEV_BUNDLE_DEPLOY="$HOME/Applications/MeetingTranscriber-Dev.app"
MTCLI_PKG="$ROOT/tools/mt-cli"
MTCLI="$MTCLI_PKG/.build/release/mt-cli"
FIXTURE="$ROOT/scripts/fixtures/webrtc-tone.html"
FIXTURE_URL="file://$FIXTURE"
RPC_TOKEN_FILE="$HOME/Library/Application Support/MeetingTranscriber/.rpc-token"
RPC_BASE="http://127.0.0.1:9876"
RECORDINGS_DIR="$HOME/Downloads/MeetingTranscriber/recordings"
# Resolve Chrome from an explicit override, then the user Applications dir, then
# the system one. A self-hosted runner whose user can't write /Applications
# (no passwordless sudo) installs Chrome under ~/Applications, so check there too.
CHROME_APP="${CHROME_APP:-}"
if [ -z "$CHROME_APP" ]; then
    for candidate in "$HOME/Applications/Google Chrome.app" "/Applications/Google Chrome.app"; do
        [ -d "$candidate" ] && CHROME_APP="$candidate" && break
    done
fi
# `find -newer` marker so cleanup + artifact search only touch THIS run's files.
RUN_MARKER="/tmp/e2e-browser-marker.$$"
# Isolated Chrome profile so the fixture instance is distinct from any user
# Chrome and can be quit by argv match without touching the user's windows.
CHROME_PROFILE="$(mktemp -d /tmp/e2e-browser-chrome.XXXXXX)"

_CONTAINER_PLIST="$HOME/Library/Containers/com.meetingtranscriber.dev/Data/Library/Preferences/com.meetingtranscriber.dev.plist"
BUNDLE_ID="com.meetingtranscriber.dev"

# --- timing budgets -------------------------------------------------------

RPC_READY_TIMEOUT_S=30   # dev-app cold start (model preload etc.)
DETECT_TIMEOUT_S=90      # Chrome launch + assertion + detector poll + prompt park
RECORD_SECONDS=15        # how long to let the tone record
STOP_TIMEOUT_S=120       # Chrome quit → assertion drop → endGrace → recorder finalize
SIDECAR_TIMEOUT_S=30     # sidecar + _app.wav appear on disk after stop

# --- helpers --------------------------------------------------------------

log()  { printf '[e2e-browser] %s\n' "$*"; }
fail() { printf '[e2e-browser] FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/e2e-helpers.sh
source "$SCRIPT_DIR/lib/e2e-helpers.sh"

require_command() { command -v "$1" >/dev/null || fail "missing command: $1"; }

RPC_TOKEN=""
# Transient-tolerant GET so poll loops under `set -e` keep going on a hiccup.
rpc() {
    curl --silent --show-error --max-time 15 \
        --header "Authorization: Bearer $RPC_TOKEN" \
        "$RPC_BASE$1" 2>/dev/null || true
}

# Quit only the fixture Chrome instance (its argv carries our profile dir) —
# never the user's own Chrome windows.
quit_chrome() { pkill -f "$CHROME_PROFILE" 2>/dev/null || true; }

# Write a dev default to BOTH the standard domain and the app's container
# plist (if present) — macOS routes the dev .app's reads to the container when
# it exists, so a standard-domain-only write is silently a no-op there. Mirrors
# e2e-app.sh's `_set_dev_default`.
_set_dev_bool() {
    local key="$1" value="$2"
    defaults write "$BUNDLE_ID" "$key" -bool "$value" 2>/dev/null || true
    [ -f "$_CONTAINER_PLIST" ] && defaults write "$_CONTAINER_PLIST" "$key" -bool "$value" 2>/dev/null || true
}

# Per-domain snapshots of the behaviour toggles this lane flips, so cleanup
# restores EACH domain to exactly its own prior value (empty → delete).
_PRE_BROWSER_STD=""; _PRE_BROWSER_CTR=""
_PRE_RECORDONLY_STD=""; _PRE_RECORDONLY_CTR=""
_PRE_NOMIC_STD=""; _PRE_NOMIC_CTR=""

# --- preflight ------------------------------------------------------------

require_command curl
require_command jq
require_command swift
require_command open

[ -f "$FIXTURE" ] || fail "fixture not found: $FIXTURE"
[ -n "$CHROME_APP" ] && [ -d "$CHROME_APP" ] \
    || fail "Google Chrome not found in ~/Applications or /Applications — install it on the runner (or set CHROME_APP)"

# noMic sidesteps the mic capture path, so a virtual input device isn't
# required (unlike e2e-app.sh). Warn if absent, don't fail.
if ! system_profiler SPAudioDataType 2>/dev/null | grep -A4 "Default Input" | grep -q "Input Channels"; then
    log "WARNING: no default audio input device — fine under noMic, but check output routing exists for Chrome"
fi

# Always quit a stale instance so the UserDefaults below take effect on launch
# and the old RPC server doesn't shadow the new one.
quit_running_app

if [ "$NO_BUILD" = false ]; then
    # Reuse e2e-app.sh's full build/deploy/re-sign machinery (Developer ID or
    # self-signed dev cert, keychain re-assertion) — it rebuilds + deploys the
    # canonical bundle and exits, leaving nothing running.
    log "Building + deploying dev bundle via e2e-app.sh --redeploy-only"
    "$SCRIPT_DIR/e2e-app.sh" --redeploy-only || fail "build/deploy failed"
else
    [ -d "$DEV_BUNDLE_DEPLOY" ] || fail "--no-build given but $DEV_BUNDLE_DEPLOY doesn't exist"
    log "Skipping build/deploy — using existing $DEV_BUNDLE_DEPLOY"
fi

# Build mt-cli (release) for confirm-browser-consent + wav-verdict.
if [ ! -x "$MTCLI" ]; then
    log "Building mt-cli"
    (cd "$MTCLI_PKG" && swift build -c release) || fail "mt-cli build failed"
fi

# --- settings -------------------------------------------------------------

# Snapshot the behaviour toggles per domain before flipping them.
_PRE_BROWSER_STD="$(snapshot_default "$BUNDLE_ID" watchBrowserMeetings)"
_PRE_RECORDONLY_STD="$(snapshot_default "$BUNDLE_ID" recordOnly)"
_PRE_NOMIC_STD="$(snapshot_default "$BUNDLE_ID" noMic)"
if [ -f "$_CONTAINER_PLIST" ]; then
    _PRE_BROWSER_CTR="$(snapshot_default "$_CONTAINER_PLIST" watchBrowserMeetings)"
    _PRE_RECORDONLY_CTR="$(snapshot_default "$_CONTAINER_PLIST" recordOnly)"
    _PRE_NOMIC_CTR="$(snapshot_default "$_CONTAINER_PLIST" noMic)"
fi

# debugRPCEnabled + autoWatch are set-and-leave (like e2e-app.sh — harmless on).
defaults write "$BUNDLE_ID" debugRPCEnabled -bool true
defaults write "$BUNDLE_ID" autoWatch -bool true
_set_dev_bool watchBrowserMeetings true   # append "Google Chrome" to watchApps
_set_dev_bool recordOnly true             # sidecar + WAVs, skip transcription/protocol
_set_dev_bool noMic true                  # app-track only; no mic needed for the proof

mkdir -p "$RECORDINGS_DIR"
touch "$RUN_MARKER"

# --- launch + cleanup trap ------------------------------------------------

log "Launching $DEV_BUNDLE_DEPLOY"
open "$DEV_BUNDLE_DEPLOY"

_ON_EXIT_RAN=""
on_exit() {
    [ -n "$_ON_EXIT_RAN" ] && return 0
    _ON_EXIT_RAN=1
    [ "$KEEP_CHROME" = false ] && quit_chrome
    [ "$KEEP_APP" = false ] && quit_running_app || true
    # Restore the behaviour toggles per domain (empty snapshot → delete).
    restore_bool_default "$BUNDLE_ID" watchBrowserMeetings "$_PRE_BROWSER_STD"
    restore_bool_default "$BUNDLE_ID" recordOnly "$_PRE_RECORDONLY_STD"
    restore_bool_default "$BUNDLE_ID" noMic "$_PRE_NOMIC_STD"
    if [ -f "$_CONTAINER_PLIST" ]; then
        restore_bool_default "$_CONTAINER_PLIST" watchBrowserMeetings "$_PRE_BROWSER_CTR"
        restore_bool_default "$_CONTAINER_PLIST" recordOnly "$_PRE_RECORDONLY_CTR"
        restore_bool_default "$_CONTAINER_PLIST" noMic "$_PRE_NOMIC_CTR"
    fi
    # Marker-bounded artifact cleanup — CI only (dev + prod share the recordings
    # dir locally; see feedback memory no_destructive_fs_on_real_dirs).
    sweep_run_artifacts "$RECORDINGS_DIR" "$RUN_MARKER"
    rm -f "$RUN_MARKER"
    rm -rf "$CHROME_PROFILE"
}
trap on_exit EXIT
trap 'on_exit; exit 130' INT
trap 'on_exit; exit 143' TERM

log "Waiting up to ${RPC_READY_TIMEOUT_S}s for RPC /healthz"
_rpc_ready() { [ -f "$RPC_TOKEN_FILE" ] && RPC_TOKEN="$(cat "$RPC_TOKEN_FILE")" && rpc /healthz >/dev/null 2>&1; }
poll_until "$RPC_READY_TIMEOUT_S" 1 _rpc_ready || fail "RPC /healthz did not respond within ${RPC_READY_TIMEOUT_S}s"
log "RPC up"

# --- drive the browser meeting --------------------------------------------

_watch_state() { rpc /state | jq -r '.watchState // ""'; }

# Best-effort diagnostics when detection doesn't fire — the next CI run then
# shows whether the app was watching, whether Chrome was in the watched set,
# and whether the WebRTC assertion was actually present. Never fails the script.
_dump_detection_diag() {
    log "DIAG: watchState=$(_watch_state)"
    log "DIAG: /state.settings.detection = $(rpc /state | jq -c '.settings.detection // {}' 2>/dev/null)"
    log "DIAG: effective watchBrowserMeetings std=$(snapshot_default "$BUNDLE_ID" watchBrowserMeetings) ctr=$([ -f "$_CONTAINER_PLIST" ] && snapshot_default "$_CONTAINER_PLIST" watchBrowserMeetings)"
    log "DIAG: effective autoWatch std=$(snapshot_default "$BUNDLE_ID" autoWatch)"
    log "DIAG: pmset WebRTC assertions:"
    pmset -g assertions 2>/dev/null | grep -iE "webrtc|peerconnection|Google Chrome" || log "DIAG:   (none)"
}

log "Launching Chrome with the WebRTC-tone fixture"
# --password-store=basic keeps Chrome off the macOS keychain (an in-memory
# store instead), so its first launch never pops a blocking "Chrome wants to
# use the keychain" modal that a headless runner has no one to dismiss.
open -na "$CHROME_APP" --args \
    --user-data-dir="$CHROME_PROFILE" \
    --no-first-run --no-default-browser-check \
    --password-store=basic \
    --autoplay-policy=no-user-gesture-required \
    "$FIXTURE_URL"

# Detection + consent in one poll: confirm-browser-consent returns
# {"resolved":false} until the consent prompt actually parks (i.e. the browser
# meeting was detected and the watch loop is blocked awaiting consent), then
# {"resolved":true} once we grant it. Polling until true is race-free against
# however long Chrome takes to hold the assertion.
log "Waiting up to ${DETECT_TIMEOUT_S}s for detection + granting consent over RPC"
_grant_consent() {
    assert_app_alive
    "$MTCLI" confirm-browser-consent --granted 2>/dev/null | jq -e '.resolved == true' >/dev/null 2>&1
}
poll_until "$DETECT_TIMEOUT_S" 2 _grant_consent || {
    _dump_detection_diag
    fail "no browser consent prompt parked within ${DETECT_TIMEOUT_S}s — detection or the assertion never fired"
}
log "Consent granted over RPC"

log "Waiting for recording to start (watchState == recording)"
_is_recording() { [ "$(_watch_state)" = "recording" ]; }
poll_until "$DETECT_TIMEOUT_S" 2 _is_recording \
    || fail "watchState never reached 'recording' after consent"
log "Recording started; capturing ${RECORD_SECONDS}s of tone"
sleep "$RECORD_SECONDS"

log "Quitting Chrome to end the meeting"
quit_chrome

log "Waiting up to ${STOP_TIMEOUT_S}s for recording to stop"
_not_recording() { [ "$(_watch_state)" != "recording" ]; }
poll_until "$STOP_TIMEOUT_S" 2 _not_recording \
    || fail "watchState stayed 'recording' after Chrome quit — meeting-end not detected"

# --- assert: a non-silent app track was captured --------------------------

log "Waiting up to ${SIDECAR_TIMEOUT_S}s for the record-only sidecar"
SIDECAR=""
_find_sidecar() {
    SIDECAR="$(find "$RECORDINGS_DIR" -name '*_meta.json' -newer "$RUN_MARKER" 2>/dev/null | head -1)"
    [ -n "$SIDECAR" ]
}
poll_until "$SIDECAR_TIMEOUT_S" 1 _find_sidecar || fail "no record-only sidecar written under $RECORDINGS_DIR"
log "Sidecar: $SIDECAR"

APP_WAV="${SIDECAR%_meta.json}_app.wav"
[ -f "$APP_WAV" ] || fail "no _app.wav next to the sidecar ($APP_WAV)"

# Preserve the captured track + sidecar OUTSIDE the recordings dir so the
# on-exit sweep (CI-gated) doesn't delete them before CI uploads them for
# post-mortem — the whole point of this lane is "was there audio?".
cp "$APP_WAV" /tmp/e2e-browser-app.wav 2>/dev/null || true
cp "$SIDECAR" /tmp/e2e-browser-meta.json 2>/dev/null || true

log "Verdict on the captured app track:"
"$MTCLI" wav-verdict "$APP_WAV" --threshold-dbfs -50 --min-active-ratio 0.5 \
    || fail "app track is silent — the CATap did not capture Chrome's browser-meeting audio"

log "PASS: browser detection → RPC consent → non-silent CATap capture of the app track"
