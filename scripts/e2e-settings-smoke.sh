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

# This drives the RELEASE bundle, which shares the `com.meetingtranscriber.app`
# defaults domain with an installed copy — so the run mutates the REAL settings of
# whoever executes it. Each step restores what it changed, but a run that dies in
# between leaves them changed, and `recordOnly` stuck ON means the next real meeting
# is recorded and never transcribed. Ephemeral CI has nothing to lose; a developer
# machine does, so local runs must opt in knowingly.
if [ -z "${CI:-}" ] && [ "${MT_SMOKE_ALLOW_LOCAL:-}" != "1" ]; then
    printf "\033[0;31m✗\033[0m %s\n" \
        "refusing to run outside CI: this toggles recordOnly and rewrites micName in your REAL settings (com.meetingtranscriber.app)." >&2
    printf "  %s\n" "Re-run with MT_SMOKE_ALLOW_LOCAL=1 if you accept that a crashed run can leave them changed." >&2
    exit 1
fi

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

step "POST /ui/press via=click selects a sidebar row (the AX press cannot)"
field_in_tree() {
    curl -sf --max-time 15 "${AUTH[@]}" "$BASE/ui/tree?window=settings" | grep -c micNameField || true
}
# SwiftUI renders only the selected tab, so the Speakers field is absent until the
# row is selected. That absence is the assertion: it proves the click did something
# an AX press provably cannot, rather than trusting the returned flag.
[ "$(field_in_tree)" = "0" ] \
    || fail "micNameField already in the tree before switching tabs — cannot prove the click did it"
curl -sf --max-time 15 "${AUTH[@]}" -X POST "$BASE/ui/press" \
    -H 'Content-Type: application/json' \
    -d '{"window":"settings","identifier":"settings-tab-speakers","via":"click"}' -o /dev/null \
    || fail "ui/press via=click failed"
present=0
for _ in $(seq 1 8); do
    present=$(field_in_tree)
    [ "$present" != "0" ] && break
    sleep 1
done
[ "$present" != "0" ] \
    || fail "Speakers tab did not become selected => synthetic click did not hit-test on this runner"
ok "click switched tabs (micNameField now in the tree)"

step "POST /ui/type writes through to AppSettings"
read_mic_name() {
    curl -sf --max-time 15 "${AUTH[@]}" "$BASE/state" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['settings']['recording']['micName'])"
}
original_mic=$(read_mic_name) || fail "could not read micName"
probe="UiTypeSmoke"
curl -sf --max-time 15 "${AUTH[@]}" -X POST "$BASE/ui/type" \
    -H 'Content-Type: application/json' \
    -d "{\"identifier\":\"micNameField\",\"text\":\"$probe\",\"clear\":true}" -o /dev/null \
    || fail "ui/type failed"
typed=""
for _ in $(seq 1 8); do
    typed=$(read_mic_name) || fail "could not read micName after typing"
    [ "$typed" = "$probe" ] && break
    sleep 1
done
# Exact match, not "contains": clear must replace, and a partial match would hide
# the append-vs-replace ambiguity this endpoint exists to remove.
[ "$typed" = "$probe" ] \
    || fail "micName is '$typed', expected '$probe' => posted key events did not drive the SwiftUI binding"
ok "micName written via posted key events: '$typed'"

# Restore so a re-run starts from the same state as a fresh runner.
curl -sf --max-time 15 "${AUTH[@]}" -X POST "$BASE/ui/type" \
    -H 'Content-Type: application/json' \
    -d "{\"identifier\":\"micNameField\",\"text\":\"$original_mic\",\"clear\":true}" -o /dev/null \
    && ok "restored micName to '$original_mic'" \
    || echo "    (restore failed — harmless on the ephemeral runner)"

echo
echo "UI-SMOKE PASSED — self-pid /ui/* harness works on this runner"
