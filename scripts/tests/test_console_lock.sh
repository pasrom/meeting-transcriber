#!/bin/bash
# Regression test for the screen-lock check of the e2e lanes that drive the
# WindowServer from outside the app (--naming-escape, --naming-switch, the
# channel-health screenshot).
#
# With the runner's console session screen-locked those lanes failed with
# messages that blamed the product or the Screen Recording grant. Here: the
# parser reads the lock from `ioreg -n Root -d1 -a` output for the right
# session, an unreadable answer neither skips nor fails, and in the two
# e2e-app.sh lanes a locked session ends in host_skip before the assertion,
# while an unlocked one still reaches it. The samples follow the structure
# ioreg prints, trimmed, with placeholder names and identifiers.
# shellcheck disable=SC2015  # `check && ok || bad`: `ok` only prints and counts
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"
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
expect() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then ok "$name"; else bad "$name" "expected '$expected', got '$actual'"; fi
}

ME="$(id -u)"
OTHER=$(( ME + 1 ))

# session <uid> <on console: true|false> <lock: true|false|absent> — one
# IOConsoleUsers entry as ioreg prints it.
session() {
    local lock=""
    [ "$3" = absent ] || lock="<key>CGSSessionScreenIsLocked</key><$3/><key>CGSSessionScreenLockedTime</key><integer>1794694166</integer>"
    cat <<EOF
		<dict>
			$lock
			<key>CGSSessionUniqueSessionUUID</key>
			<string>00000000-0000-4000-8000-00000000000$1</string>
			<key>kCGSSessionAuditIDKey</key>
			<integer>100015</integer>
			<key>kCGSSessionGroupIDKey</key>
			<integer>20</integer>
			<key>kCGSSessionIDKey</key>
			<integer>257</integer>
			<key>kCGSSessionLoginwindowSafeLogin</key>
			<false/>
			<key>kCGSSessionOnConsoleKey</key>
			<$2/>
			<key>kCGSSessionSystemSafeBoot</key>
			<false/>
			<key>kCGSSessionUserIDKey</key>
			<integer>$1</integer>
			<key>kCGSSessionUserNameKey</key>
			<string>runner$1</string>
			<key>kCGSessionLoginDoneKey</key>
			<true/>
		</dict>
EOF
}

# root <session...> — the Root entry around those sessions, with a data value
# beside them as the real tree has, which a whole-tree JSON conversion rejects.
root() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>IOConsoleLocked</key>
	<true/>
	<key>IOConsoleUsers</key>
	<array>
$*
	</array>
	<key>IOKitBuildVersion</key>
	<string>Darwin Kernel Version 27.2.0</string>
	<key>IOPlatformUUIDData</key>
	<data>AAECAwQFBgc=</data>
	<key>IORegistryEntryName</key>
	<string>Root</string>
</dict>
</plist>
EOF
}

parse() { _console_lock_from_ioreg "$ME"; }

# --- _console_lock_from_ioreg ------------------------------------------------

expect locked_session_reads_locked locked "$(root "$(session "$ME" true true)" | parse)"
expect absent_key_reads_unlocked unlocked "$(root "$(session "$ME" true absent)" | parse)"
expect false_key_reads_unlocked unlocked "$(root "$(session "$ME" true false)" | parse)"

# Several sessions: only ours, on the console, counts.
expect other_users_lock_does_not_count unlocked \
    "$(root "$(session "$OTHER" false true)" "$(session "$ME" true absent)" | parse)"
expect our_lock_counts_beside_another_session locked \
    "$(root "$(session "$OTHER" false absent)" "$(session "$ME" true true)" | parse)"
# Fast User Switching: another user in front. Not this check's fault to name.
out="$(root "$(session "$ME" false absent)" "$(session "$OTHER" true true)" | parse)"
case "$out" in unknown:*) ok our_session_in_the_background_is_unknown ;; *) bad our_session_in_the_background_is_unknown "'$out'" ;; esac

for c in empty garbage no_console_users not_an_array non_bool_lock; do
    case "$c" in
        empty) in="" ;;
        garbage) in="IOConsoleUsers = locked" ;;
        no_console_users) in="$(root "" | sed '/IOConsoleUsers/,/<\/array>/d')" ;;
        not_an_array) in="$(root "" | sed 's|<array>|<string>|; s|</array>|</string>|')" ;;
        non_bool_lock) in="$(root "$(session "$ME" true true)" | sed 's|<key>CGSSessionScreenIsLocked</key><true/>|<key>CGSSessionScreenIsLocked</key><string>yes</string>|')" ;;
    esac
    out="$(printf '%s' "$in" | parse)"
    case "$out" in unknown:*) ok "${c}_reads_unknown" ;; *) bad "${c}_reads_unknown" "'$out'" ;; esac
done

# --- host_skip_if_screen_locked, over a faked ioreg ---------------------------

# console_lock_state runs ioreg through run_bounded, whose subshell sees this
# function in place of the binary.
ioreg() { cat "$TMP/ioreg"; }

root "$(session "$ME" true true)" >"$TMP/ioreg"
status=0
out="$(GITHUB_ACTIONS=true RUNNER_TEMP="$TMP" GITHUB_STEP_SUMMARY='' host_skip_if_screen_locked lane-l "the L assertion")" || status=$?
[ "$status" -eq 0 ] && grep -q '^\[lane-l\]: SKIP — The runner.s screen is locked' <<<"$out" \
    && grep -q 'the L assertion did not run' <<<"$out" \
    && grep -q 'Lock Screen → "Require password after screen saver begins or display is turned off" to Never' <<<"$out" \
    && [ "$(cat "$TMP/e2e-host-skips")" = lane-l ] \
    && ok locked_skips_through_host_skip || bad locked_skips_through_host_skip "status $status: '$out'"
rm -f "$TMP/e2e-host-skips"

for c in unlocked unknown; do
    if [ "$c" = unlocked ]; then root "$(session "$ME" true absent)" >"$TMP/ioreg"; else : >"$TMP/ioreg"; fi
    status=0
    out="$(GITHUB_ACTIONS=true RUNNER_TEMP="$TMP" GITHUB_STEP_SUMMARY='' host_skip_if_screen_locked lane-u "the U assertion")" || status=$?
    [ "$status" -eq 1 ] && [ ! -e "$TMP/e2e-host-skips" ] && ! grep -q SKIP <<<"$out" \
        && ok "${c}_runs_the_assertion" || bad "${c}_runs_the_assertion" "status $status: '$out'"
done
grep -q "could not tell whether the screen is locked" <<<"$out" \
    && ok unknown_says_so || bad unknown_says_so "'$out'"

# --- the lanes, taken from e2e-app.sh ----------------------------------------

# run_lane <function> <ioreg sample for call 1> [for call 2...] — run that lane
# function from e2e-app.sh in a fresh shell with everything around its lock
# checks stubbed. Each ioreg call answers the next sample (the last repeats).
# Stubs append to $TMP/trace what the lane got to: `assertion` when it went on
# to its assertion, `released <job>` for a naming skip.
run_lane() {
    local fn="$1" i=1 s
    shift
    rm -f "$TMP"/ioreg.* "$TMP/ioreg.n" "$TMP/trace" "$TMP/e2e-host-skips"
    for s in "$@"; do printf '%s' "$s" >"$TMP/ioreg.$i"; i=$(( i + 1 )); done
    /bin/bash -c '
        set -euo pipefail
        source "$2/scripts/lib/e2e-helpers.sh"
        ROOT="$2" T="$3"
        ioreg() {
            local n; n=$(( $(cat "$T/ioreg.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$T/ioreg.n"
            while [ "$n" -gt 1 ] && [ ! -e "$T/ioreg.$n" ]; do n=$(( n - 1 )); done
            cat "$T/ioreg.$n"
        }
        log() { echo "$*"; }
        fail() { echo "FAIL: $*"; exit 1; }
        require_command() { :; }
        tcc_grantee() { echo /runner/node; }
        DEFAULT_FIXTURE="$T/fixture.wav"; : >"$DEFAULT_FIXTURE"
        RPC_TOKEN=t RPC_BASE=http://127.0.0.1:1 PIPELINE_TIMEOUT_S=1 _NAMING_WINDOW_VISIBLE=true
        _NE_FIXTURE_DIR="" _NS_DIR="" _NS_JOBS=()
        # The lanes make their scratch dirs under /tmp; keep them in the test dir.
        mktemp() {
            case "$*" in
                */tmp/e2e-naming-*) command mktemp -d "$T/lane.XXXXXX" ;;
                *) command mktemp "$@" ;;
            esac
        }
        # naming-escape: the System Events probes answer (or, with
        # NO_GRANT=1, the keystroke probe is refused as without Accessibility);
        # fronting the app is the start of the assertion.
        osascript() {
            case "$*" in
                *"set frontmost"*) echo assertion >>"$T/trace" ;;
                *"first process whose frontmost"*) echo Finder ;;
                *"key code 53"*) [ "${NO_GRANT:-0}" != 1 ] || { echo "osascript is not allowed assistive access. (-1719)"; return 1; } ;;
            esac
        }
        curl() { echo "{\"jobIDs\":[\"J1\"]}"; }
        poll_rpc() { return 0; }
        poll_state() { return 0; }
        _naming_skip() { echo "released $1" >>"$T/trace"; }
        # naming-switch: a driver that is trusted (with NO_GRANT=1, one that
        # is not); the settings read is the first step past the lock check.
        swiftc() {
            local out=""
            while [ $# -gt 0 ]; do [ "$1" != -o ] || out="$2"; shift; done
            if [ "${NO_GRANT:-0}" = 1 ]; then
                printf "#!/bin/sh\necho trusted=false\nexit 3\n" >"$out"
            else
                printf "#!/bin/sh\necho trusted=true\n" >"$out"
            fi
            chmod +x "$out"
        }
        state_query() { echo assertion >>"$T/trace"; exit 7; }
        pat="/^$4() {/,/^}/p"
        eval "$(sed -n -e "$pat" "$1")"
        declare -F "$4" >/dev/null || { echo "$4 not found in the lane"; exit 3; }
        GITHUB_ACTIONS=true RUNNER_TEMP="$T" GITHUB_STEP_SUMMARY=""
        "$4"
        echo "returned 0"
    ' _ "$APP_SH" "$ROOT" "$TMP" "$fn" 2>&1
}
trace() { [ ! -e "$TMP/trace" ] || tr '\n' ' ' <"$TMP/trace" | sed 's/ $//'; }

LOCKED="$(root "$(session "$ME" true true)")"
UNLOCKED="$(root "$(session "$ME" true absent)")"

for lane in naming-escape naming-switch; do
    fn="run_${lane//-/_}"
    status=0
    out="$(run_lane "$fn" "$LOCKED")" || status=$?
    [ "$status" -eq 0 ] && grep -q "^\[$lane\]: SKIP — The runner.s screen is locked" <<<"$out" \
        && grep -q 'returned 0' <<<"$out" && [ -z "$(trace)" ] \
        && [ "$(cat "$TMP/e2e-host-skips" 2>/dev/null)" = "$lane" ] \
        && ok "${lane}_locked_skips_before_the_assertion" \
        || bad "${lane}_locked_skips_before_the_assertion" "status $status, trace '$(trace)': $out"

    # Control: unlocked, the same lane goes on, so the case above is not
    # passing on a stub that never lets it.
    status=0
    out="$(run_lane "$fn" "$UNLOCKED")" || status=$?
    grep -q "^assertion" "$TMP/trace" 2>/dev/null && ! grep -q SKIP <<<"$out" \
        && ok "${lane}_unlocked_reaches_the_assertion" \
        || bad "${lane}_unlocked_reaches_the_assertion" "status $status, trace '$(trace)': $out"
done

# naming-escape locks during the pipeline wait: the second check skips, and the
# parked job is released rather than left to reopen the dialog.
status=0
out="$(run_lane run_naming_escape "$UNLOCKED" "$LOCKED")" || status=$?
[ "$status" -eq 0 ] && grep -q '^\[naming-escape\]: SKIP — The runner.s screen is locked' <<<"$out" \
    && [ "$(trace)" = "released J1" ] \
    && ok naming_escape_lock_during_the_wait_skips_and_releases_the_job \
    || bad naming_escape_lock_during_the_wait_skips_and_releases_the_job "status $status, trace '$(trace)': $out"

# A missing grant is still named as one on a locked screen: the grant checks
# come first.
for lane in naming-escape naming-switch; do
    fn="run_${lane//-/_}"
    status=0
    out="$(NO_GRANT=1 run_lane "$fn" "$LOCKED")" || status=$?
    [ "$status" -eq 0 ] && grep -q "^\[$lane\]: SKIP — .*Accessibility" <<<"$out" \
        && ! grep -q 'screen is locked' <<<"$out" && [ -z "$(trace)" ] \
        && ok "${lane}_missing_grant_is_named_before_the_lock" \
        || bad "${lane}_missing_grant_is_named_before_the_lock" "status $status, trace '$(trace)': $out"
done

COMPLETED=1
echo "$PASSED passed"
