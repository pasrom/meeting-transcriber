#!/usr/bin/env bash
# GitHub-hosted canary for the in-process /ui/* accessibility harness.
#
# Builds the Homebrew .app (the RPC server + /ui/* are `#if !APPSTORE`), launches
# it with the debug RPC, opens Settings, and asserts the self-pid AXUIElement path
# still works: `GET /ui/tree` surfaces a SwiftUI `.accessibilityIdentifier`, and
# `POST /ui/press` flips the observed `/state`. That path rests on three
# non-contractual macOS behaviors (lazy AX materialization, self-pid TCC exemption,
# self-pid direct dispatch — see DebugRPCServer+AXElement.swift); this canary makes
# an OS update that breaks any of them fail loudly and attributably.
#
# It needs NO Accessibility/mic/screen-recording TCC grant (self-inspection is
# exempt; it only reads/presses Settings, never records), which is exactly what
# lets it run on an ephemeral GitHub-hosted runner instead of the self-hosted Mac.
#
# Usage: ./scripts/e2e-settings-smoke.sh    (exit 0 pass, non-zero on first failure)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# build_release.sh assembles the bundle at the repo-root .build/release (it moves
# the .app back there after staging the DMG), NOT the SPM package's .build.
APP="$REPO_ROOT/.build/release/MeetingTranscriber.app"
TOKEN_FILE="$HOME/Library/Application Support/MeetingTranscriber/.rpc-token"
BASE="http://127.0.0.1:9876"

step() { printf "\n\033[1;34m==> %s\033[0m\n" "$1"; }
ok()   { printf "    \033[0;32m✓\033[0m %s\n" "$1"; }
fail() { printf "    \033[0;31m✗\033[0m %s\n" "$1"; exit 1; }

# `-x` (exact name) so we never touch a developer's MeetingTranscriber-Dev while
# this runs locally; the release bundle's process is exactly "MeetingTranscriber".
step "Build Homebrew .app (ad-hoc signed)"
pkill -x MeetingTranscriber 2>/dev/null || true
sleep 1
"$REPO_ROOT/scripts/build_release.sh" --no-notarize >/dev/null
[ -d "$APP" ] || fail "no app bundle at $APP"
ok "built $APP"

step "Launch with MEETINGTRANSCRIBER_DEBUG_RPC=1"
trap 'pkill -x MeetingTranscriber 2>/dev/null || true' EXIT
MEETINGTRANSCRIBER_DEBUG_RPC=1 open -gj "$APP"
for _ in $(seq 1 60); do
    [ -s "$TOKEN_FILE" ] && lsof -i :9876 >/dev/null 2>&1 && break
    sleep 0.5
done
[ -s "$TOKEN_FILE" ] || fail "RPC token never appeared — the app didn't start the RPC server"
lsof -i :9876 >/dev/null 2>&1 || fail "nothing bound :9876 within 30s"
TOKEN=$(cat "$TOKEN_FILE")
AUTH=(-H "Authorization: Bearer $TOKEN")
curl -sf "${AUTH[@]}" -o /dev/null "$BASE/healthz" || fail "RPC not reachable on :9876"
ok "RPC listening + authenticated"

step "Open Settings"
curl -sf "${AUTH[@]}" -X POST "$BASE/action/openSettings" -o /dev/null || fail "openSettings failed"
sleep 2

step "GET /ui/tree surfaces the SwiftUI identifier (self-pid AX works on this runner)"
code=$(curl -s -o /tmp/ui-tree.json -w '%{http_code}' "${AUTH[@]}" "$BASE/ui/tree?window=settings")
[ "$code" = "200" ] \
    || fail "/ui/tree returned $code (503 => the Settings window did not render on this runner)"
python3 -c "
import json,sys
t=json.load(open('/tmp/ui-tree.json'))
ids=[]
def w(n):
    if n.get('identifier'): ids.append(n['identifier'])
    for c in n.get('children',[]): w(c)
w(t)
assert 'recordOnlyToggle' in ids, \
    f'recordOnlyToggle absent (ids={sorted(set(ids))}) => self-pid AX not surfacing SwiftUI identifiers here'
print('    tree identifiers:', sorted(set(ids)))
" || fail "/ui/tree did not surface recordOnlyToggle"
ok "recordOnlyToggle present in the accessibility tree"

step "POST /ui/press flips the observed state (in-process press fires on this runner)"
read_record_only() {
    curl -sf "${AUTH[@]}" "$BASE/state" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['settings']['recording']['recordOnly'])"
}
press() {
    curl -sf "${AUTH[@]}" -X POST "$BASE/ui/press" \
        -H 'Content-Type: application/json' \
        -d '{"window":"settings","identifier":"recordOnlyToggle"}' -o /dev/null
}
before=$(read_record_only)
[ -n "$before" ] || fail "could not read settings.recording.recordOnly"
press || fail "ui/press recordOnlyToggle failed"
sleep 1
after=$(read_record_only)
[ "$before" != "$after" ] \
    || fail "recordOnly did not flip ($before -> $after) => in-process AX press did not fire on this runner"
ok "recordOnly flipped $before -> $after"
press || true  # restore original state
ok "restored"

echo
echo "UI-SMOKE PASSED — self-pid /ui/* harness works on this runner"
