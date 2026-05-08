#!/usr/bin/env bash
# Live smoketest for the debug RPC server. Builds the dev app, launches it
# with MEETINGTRANSCRIBER_DEBUG_RPC=1, drives every endpoint via mt-cli, and
# asserts UI side-effects via window-size heuristics on the captured PNG.
#
# Useful before pushing RPC-related changes — catches things the in-process
# integration tests can't (real SwiftUI rendering, window routing, codesign).
#
# Usage: ./scripts/test_rpc.sh
#
# Exit 0 on success, non-zero on first failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPM_DIR="$REPO_ROOT/app/MeetingTranscriber"
APP_BUNDLE="$SPM_DIR/.build/MeetingTranscriber-Dev.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/MeetingTranscriber"
MT_CLI_DIR="$REPO_ROOT/tools/mt-cli"
MT_CLI_BIN="$MT_CLI_DIR/.build/debug/mt-cli"
TOKEN_FILE="$HOME/Library/Application Support/MeetingTranscriber/.rpc-token"

step() { printf "\n\033[1;34m==> %s\033[0m\n" "$1"; }
ok()   { printf "    \033[0;32m✓\033[0m %s\n" "$1"; }
fail() { printf "    \033[0;31m✗\033[0m %s\n" "$1"; exit 1; }

# --- Cleanup any prior dev instance so the rebuild picks up our binary. ---
step "Stopping any running dev app"
if pgrep -f MeetingTranscriber-Dev >/dev/null; then
    pkill -f MeetingTranscriber-Dev || true
    sleep 2
fi

# --- Build app + mt-cli. ---
step "Building app (release) + mt-cli (debug)"
(cd "$SPM_DIR" && swift build -c release >/dev/null)
ok "app built"
(cd "$MT_CLI_DIR" && swift build >/dev/null)
ok "mt-cli built"

# --- Assemble + sign bundle. ---
cp "$SPM_DIR/.build/release/MeetingTranscriber" "$APP_BINARY"
SIGN_HASH=$(security find-identity -v -p codesigning | head -1 | awk '{print $2}')
codesign --force --sign "$SIGN_HASH" "$APP_BUNDLE" 2>/dev/null
ok "signed"

# --- Launch with env var. ---
step "Launching with MEETINGTRANSCRIBER_DEBUG_RPC=1"
MEETINGTRANSCRIBER_DEBUG_RPC=1 open -gj "$APP_BUNDLE"
# Poll for the listener instead of a fixed sleep.
for _ in $(seq 1 30); do
    if lsof -i :9876 >/dev/null 2>&1; then break; fi
    sleep 0.2
done
lsof -i :9876 >/dev/null 2>&1 || fail "server did not bind to :9876 within 6s"
ok "listening on :9876"

# Cleanup on exit.
trap 'pkill -f MeetingTranscriber-Dev 2>/dev/null || true' EXIT

[ -s "$TOKEN_FILE" ] || fail "token file not created"
TOKEN=$(cat "$TOKEN_FILE")
ok "token file present (chmod $(stat -f '%Lp' "$TOKEN_FILE"))"

# --- Endpoint roundtrips. ---
step "Auth gate"
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:9876/healthz")
[ "$code" = "401" ] || fail "no-auth: expected 401 got $code"
ok "no-auth → 401"

code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer wrong" "http://127.0.0.1:9876/healthz")
[ "$code" = "401" ] || fail "wrong-token: expected 401 got $code"
ok "wrong-token → 401"

code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" -H "Origin: http://evil.example" "http://127.0.0.1:9876/healthz")
[ "$code" = "403" ] || fail "browser-origin: expected 403 got $code"
ok "browser-origin → 403"

step "mt-cli roundtrips"
"$MT_CLI_BIN" healthz | grep -q "^ok$" || fail "healthz output unexpected"
ok "healthz"

"$MT_CLI_BIN" state | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'pipeline' in d and 'speakerDB' in d
e = d['engines']
assert e['active'] in ('whisperKit', 'parakeet', 'qwen3'), f'bad active: {e[\"active\"]!r}'
assert 'modelVariant' in e['whisperKit']
assert 'customVocabularyPath' in e['parakeet']
" || fail "state JSON malformed"
ok "state JSON parses (incl. engines block)"

step "Action + screenshot loop"
"$MT_CLI_BIN" close-settings >/dev/null  # ensure clean idle
sleep 1

# Idle should be 503 (no large window).
out=$("$MT_CLI_BIN" screenshot /tmp/rpc-smoke-idle.png 2>&1 || true)
echo "$out" | grep -q "503" || fail "idle screenshot: expected 503, got: $out"
ok "idle → 503"

# Open Settings → screenshot should be a real PNG.
"$MT_CLI_BIN" open-settings >/dev/null
sleep 2
"$MT_CLI_BIN" screenshot /tmp/rpc-smoke-settings.png >/dev/null
size=$(stat -f '%z' /tmp/rpc-smoke-settings.png)
[ "$size" -gt 5000 ] || fail "settings screenshot too small ($size bytes)"
dim=$(file /tmp/rpc-smoke-settings.png | grep -oE '[0-9]+ x [0-9]+' | head -1)
ok "settings → PNG $dim, $size bytes"

# Close Settings → back to 503.
"$MT_CLI_BIN" close-settings >/dev/null
sleep 1
out=$("$MT_CLI_BIN" screenshot /tmp/rpc-smoke-after-close.png 2>&1 || true)
echo "$out" | grep -q "503" || fail "after-close: expected 503, got: $out"
ok "close → 503 again"

step "Speaker DB mutation routes"

probe_name="rpc-smoketest-$$"
followup_name="rpc-smoketest-$$-renamed"

# rename of a non-existent speaker → 404 (mt-cli exits non-zero).
out=$("$MT_CLI_BIN" rename-speaker "$probe_name" "$followup_name" 2>&1 || true)
echo "$out" | grep -q "404" || fail "rename of missing speaker: expected 404, got: $out"
ok "rename missing → 404"

# delete of a non-existent speaker → 404.
out=$("$MT_CLI_BIN" delete-speaker "$probe_name" 2>&1 || true)
echo "$out" | grep -q "404" || fail "delete of missing speaker: expected 404, got: $out"
ok "delete missing → 404"

# merge with non-existent source → 404.
out=$("$MT_CLI_BIN" merge-speakers "$probe_name" "$followup_name" 2>&1 || true)
echo "$out" | grep -q "404" || fail "merge missing → expected 404, got: $out"
ok "merge missing → 404"

# Malformed payload → 400.
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d 'not-json' "http://127.0.0.1:9876/action/renameSpeaker")
[ "$code" = "400" ] || fail "bad JSON: expected 400 got $code"
ok "bad JSON → 400"

step "Cache invalidation roundtrip (seed → rename → delete via knownSpeakerNames)"

seed_name="rpc-smoketest-$$-seed"
rename_target="rpc-smoketest-$$-renamed"

"$MT_CLI_BIN" seed-speaker "$seed_name" >/dev/null
"$MT_CLI_BIN" state | python3 -c "
import json, sys
d = json.load(sys.stdin)
names = d['speakerDB']['knownSpeakerNames']
assert '$seed_name' in names, f'seed missing from cache: {names}'
" || fail "seed not reflected in knownSpeakerNames"
ok "seed → cache updated"

"$MT_CLI_BIN" rename-speaker "$seed_name" "$rename_target" >/dev/null
"$MT_CLI_BIN" state | python3 -c "
import json, sys
d = json.load(sys.stdin)
names = d['speakerDB']['knownSpeakerNames']
assert '$rename_target' in names and '$seed_name' not in names, f'rename not in cache: {names}'
" || fail "rename not reflected in knownSpeakerNames"
ok "rename → cache updated"

"$MT_CLI_BIN" delete-speaker "$rename_target" >/dev/null
"$MT_CLI_BIN" state | python3 -c "
import json, sys
d = json.load(sys.stdin)
names = d['speakerDB']['knownSpeakerNames']
assert '$rename_target' not in names, f'delete not reflected: {names}'
" || fail "delete not reflected in knownSpeakerNames"
ok "delete → cache updated"

step "All checks passed"
