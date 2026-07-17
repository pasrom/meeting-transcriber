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
TREE_JSON="$(mktemp)"

step() { printf "\n\033[1;34m==> %s\033[0m\n" "$1"; }
ok()   { printf "    \033[0;32m✓\033[0m %s\n" "$1"; }
fail() { printf "    \033[0;31m✗\033[0m %s\n" "$1"; exit 1; }

# Kill only THIS release bundle's process, matched by its unique bundle path.
# Both the release and a developer's MeetingTranscriber-Dev bundle share the
# executable name "MeetingTranscriber" (only the .app dir differs), so `pkill -x`
# would hit both; `-f "$APP"` disambiguates so running this locally never touches
# a running Dev app.
kill_app() { pkill -f "$APP" 2>/dev/null || true; }
trap 'kill_app; rm -f "$TREE_JSON"' EXIT

step "Build Homebrew .app (ad-hoc signed)"
kill_app
sleep 1
"$REPO_ROOT/scripts/build_release.sh" --no-notarize >/dev/null
[ -d "$APP" ] || fail "no app bundle at $APP"
ok "built $APP"

step "Launch with MEETINGTRANSCRIBER_DEBUG_RPC=1"
MEETINGTRANSCRIBER_DEBUG_RPC=1 open -gj "$APP"
for _ in $(seq 1 60); do
    [ -s "$TOKEN_FILE" ] && lsof -i :9876 >/dev/null 2>&1 && break
    sleep 0.5
done
[ -s "$TOKEN_FILE" ] || fail "RPC token never appeared — the app didn't start the RPC server"
lsof -i :9876 >/dev/null 2>&1 || fail "nothing bound :9876 within 30s"
TOKEN=$(cat "$TOKEN_FILE")
AUTH=(-H "Authorization: Bearer $TOKEN")
curl -sf --max-time 15 "${AUTH[@]}" -o /dev/null "$BASE/healthz" || fail "RPC not reachable on :9876"
ok "RPC listening + authenticated"

step "Open Settings"
curl -sf --max-time 15 "${AUTH[@]}" -X POST "$BASE/action/openSettings" -o /dev/null || fail "openSettings failed"

# The Settings window renders and its AX subtree materializes lazily, and launch
# fires a CoreML model warm-up that can saturate a cold runner — so poll for the
# identifier rather than guessing a fixed sleep (would flake on the nightly cron).
step "GET /ui/tree surfaces recordOnlyToggle (poll: window + AX tree materialize lazily)"
last_code=""
ui_tree_has_toggle() {
    last_code=$(curl -s --max-time 15 -o "$TREE_JSON" -w '%{http_code}' \
        "${AUTH[@]}" "$BASE/ui/tree?window=settings" || true)
    [ "$last_code" = "200" ] || return 1
    python3 - "$TREE_JSON" <<'PY'
import json, sys
try:
    tree = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
ids = []
def walk(n):
    if n.get('identifier'):
        ids.append(n['identifier'])
    for c in n.get('children', []):
        walk(c)
walk(tree)
sys.exit(0 if 'recordOnlyToggle' in ids else 1)
PY
}
found=false
for _ in $(seq 1 30); do
    if ui_tree_has_toggle; then found=true; break; fi
    sleep 1
done
[ "$found" = true ] || fail "/ui/tree never surfaced recordOnlyToggle within 30s (last HTTP ${last_code:-none}): \
503 => Settings window didn't render; 200 => AX subtree not materialized / self-pid AX not surfacing identifiers here"
python3 - "$TREE_JSON" <<'PY'
import json, sys
tree = json.load(open(sys.argv[1]))
ids = []
def walk(n):
    if n.get('identifier'):
        ids.append(n['identifier'])
    for c in n.get('children', []):
        walk(c)
walk(tree)
print('    tree identifiers:', sorted(set(ids)))
PY
ok "recordOnlyToggle present in the accessibility tree"

step "POST /ui/press flips the observed state (in-process press fires on this runner)"
read_record_only() {
    curl -sf --max-time 15 "${AUTH[@]}" "$BASE/state" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['settings']['recording']['recordOnly'])"
}
press() {
    curl -sf --max-time 15 "${AUTH[@]}" -X POST "$BASE/ui/press" \
        -H 'Content-Type: application/json' \
        -d '{"window":"settings","identifier":"recordOnlyToggle"}' -o /dev/null
}
before=$(read_record_only) || fail "could not read /state (app not responding — crashed after openSettings?)"
press || fail "ui/press recordOnlyToggle failed"
after="$before"
for _ in $(seq 1 5); do
    after=$(read_record_only) || fail "could not read /state after press"
    [ "$after" != "$before" ] && break
    sleep 1
done
[ "$before" != "$after" ] \
    || fail "recordOnly did not flip ($before -> $after) => in-process AX press did not fire on this runner"
ok "recordOnly flipped $before -> $after"
if press; then ok "restored"; else echo "    (restore press failed — harmless on the ephemeral runner)"; fi

echo
echo "UI-SMOKE PASSED — self-pid /ui/* harness works on this runner"
