#!/bin/bash
# Regression test for the lock in keychain-prepend.sh.
#
# The search-list rewrite must only run while this process holds the lock.
# A held lock leaves its file in place, so checking for the file instead of
# the acquisition let a contended run rewrite the list without the lock and
# drop the holder's write. `security` is stubbed, so the real search list is
# never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/keychain-prepend.sh"

TMP="$(mktemp -d)"
holder=""
cleanup() {
    [ -n "$holder" ] && kill "$holder" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT
PASSED=0
ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }

mkdir -p "$TMP/bin" "$TMP/tmpdir"
cat >"$TMP/bin/security" <<EOF
#!/bin/bash
echo "\$*" >>"$TMP/security.calls"
if [ "\$1" = list-keychains ] && [ "\$#" -eq 3 ]; then
    echo '    "/existing.keychain-db"'
fi
EOF
chmod +x "$TMP/bin/security"
lockfile="$TMP/tmpdir/keychain-search-list.lock"

# Uncontended: the lock is taken and released, the target lands in front.
PATH="$TMP/bin:$PATH" TMPDIR="$TMP/tmpdir" bash "$SCRIPT" /target.keychain-db
grep -qx 'list-keychains -d user -s /target.keychain-db /existing.keychain-db' "$TMP/security.calls" \
    && [ ! -e "$lockfile" ] \
    && ok uncontended_prepends_and_releases || bad uncontended_prepends_and_releases "$(cat "$TMP/security.calls")"

# Contended: a live process holds the lock for the whole wait, so the run
# must give up without calling `security` at all.
rm -f "$TMP/security.calls"
sleep 30 &
holder=$!
disown "$holder"
shlock -f "$lockfile" -p "$holder" || bad contended_run_gives_up "could not take the lock for the holder"
status=0
PATH="$TMP/bin:$PATH" TMPDIR="$TMP/tmpdir" bash "$SCRIPT" /target.keychain-db 2>/dev/null || status=$?
[ "$status" -eq 1 ] && [ ! -e "$TMP/security.calls" ] && [ -e "$lockfile" ] \
    && ok contended_run_gives_up || bad contended_run_gives_up "status $status, calls: $(cat "$TMP/security.calls" 2>/dev/null)"

echo "$PASSED passed"
