#!/bin/bash
# Regression test for e2e-app.sh's one-lane-per-run check. The dispatch chain
# runs only the first lane it tests, so two lane flags that pass the argument
# checks run one lane and report PASS for both. Every combination a workflow or
# a doc uses must still pass, or the check would turn a green lane red.
#
# Runs only the argument parsing and the lane checks, cut from the script just
# before the first statement that acts on them, so nothing past them can run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_SH="$ROOT/scripts/e2e-app.sh"

TMP="$(mktemp -d)"
# Set at the very end; see test_kill_and_verify_gone.sh for why a `set -u`
# abort would otherwise read as a pass.
COMPLETED=0
cleanup() {
    local rc=$?
    rm -rf "$TMP"
    if [ "$COMPLETED" -ne 1 ]; then
        echo "FAIL: the test aborted before reaching its end" >&2
        exit 1
    fi
    exit "$rc"
}
trap cleanup EXIT
PASSED=0

ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }

CUT="$(grep -n '^# Export before the build step below so run_app.sh adds -DE2E_FAULT_INJECTION' "$APP_SH" | cut -d: -f1)"
[ -n "$CUT" ] || bad the_cut_point_exists "the fault-injection export was not found in $APP_SH"
sed -n "1,$(( CUT - 1 ))p" "$APP_SH" >"$TMP/parse.sh"
parse_status() { local st=0; bash "$TMP/parse.sh" "$@" >/dev/null 2>&1 || st=$?; echo "$st"; }

# Each pair would run only the lane the dispatch chain tests first.
for args in \
    "--title-source --record-only" \
    "--crash-recovery --record-only" \
    "--mic-device-change --record-only" \
    "--naming-escape --title-source" \
    "--mic-device-change --crash-recovery" \
    "--two-meetings --crash-recovery" \
    "--reimport-latest --record-only" \
    "--title-source --crash-recovery"; do
    # shellcheck disable=SC2086 # word splitting is the point
    st="$(parse_status $args)"
    [ "$st" = 2 ] && ok "refuses: $args" || bad "refuses: $args" "exit $st"
done

# Every invocation in .github/workflows and the docs, and the documented pairs:
# --two-meetings runs a second meeting of --record-only, --reimport-recorded
# implies --record-only, and --keep-recordings is a modifier, not a lane.
for args in \
    "" \
    "--no-build" \
    "--two-meetings" \
    "--no-build --record-only --keep-recordings" \
    "--record-only --two-meetings" \
    "--no-build --reimport-latest" \
    "--reimport-recorded" \
    "--record-only --reimport-recorded" \
    "--no-build --mic-only" \
    "--no-build --naming-confirm" \
    "--no-build --naming-escape" \
    "--no-build --naming-switch" \
    "--no-build --title-source" \
    "--no-build --echo-bleed" \
    "--no-build --echo-cancel" \
    "--no-build --protocol" \
    "--protocol-repair" \
    "--no-build --upgrade" \
    "--no-build --crash-recovery" \
    "--crash-recovery" \
    "--mic-device-change" \
    "--redeploy-only" \
    "--quit-flush --keep-recordings" \
    "--mic-stall" \
    "--mic-stall-late"; do
    # shellcheck disable=SC2086 # word splitting is the point
    st="$(parse_status $args)"
    [ "$st" = 0 ] && ok "accepts: ${args:-<no flags>}" || bad "accepts: ${args:-<no flags>}" "exit $st"
done

COMPLETED=1
echo "all $PASSED passed"
