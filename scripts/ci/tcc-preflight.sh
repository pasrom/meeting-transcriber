#!/bin/bash
# Probe, at the start of a self-hosted e2e job, each TCC-guarded resource its
# lanes touch, each under a short hard bound, and name the missing grant and
# the binary to allow before a lane hangs on it. Why a prompt blocks instead of
# failing, and why a runner update drops every grant: the e2e-architecture
# skill, runner setup step 6.
#
# Usage: bash scripts/ci/tcc-preflight.sh [--downloads] [--automation] [--accessibility]
#
#   --downloads      list ~/Downloads (Files & Folders). REQUIRED: the lanes
#                    read and write the app's output folder there, so a
#                    missing grant fails this step and with it the job. Not a
#                    host skip: nearly every lane would hang or misreport
#                    behind it, and a green job that ran nothing would also
#                    satisfy the stable-tag check.
#   --automation     ask System Events for the frontmost process (Automation),
#                    the call the --naming-escape preflight makes. Not passed
#                    by the workflows: on an ungranted host it raises a prompt
#                    that then stays on screen, over every later lane's
#                    windows, where the lane's own probe raises it last. For
#                    checking a host by hand.
#   --accessibility  ask AXIsProcessTrusted (Device Control and Data Access,
#                    formerly Accessibility).
#                    The last two only warn: the lanes that need them
#                    (--naming-escape, --naming-switch) check again and
#                    host-skip, which the job's host-skip gate already turns
#                    red on scheduled and dispatched runs. Failing here would
#                    end every other lane over two of them.
#
# Each probe gets E2E_TCC_PROMPT_TIMEOUT seconds (default 10). For a one-time
# grant session at the runner's screen, raise it so the prompt stays up long
# enough to click Allow.
#
# Exit: 0 when every required probe was granted (warnings may be printed), 1
# when a required one was not, 2 on a usage error.
#
# For tests: TCC_PREFLIGHT_HOME replaces $HOME, and TCC_PREFLIGHT_LS,
# TCC_PREFLIGHT_OSASCRIPT, TCC_PREFLIGHT_GRANTEE and TCC_PREFLIGHT_BOUND replace `ls`, `osascript`,
# the resolved grantee and the probe bound.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

want_downloads="" want_automation="" want_accessibility=""
[ $# -gt 0 ] || { echo "usage: $0 [--downloads] [--automation] [--accessibility]" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --downloads) want_downloads=1 ;;
        --automation) want_automation=1 ;;
        --accessibility) want_accessibility=1 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# TCC_PREFLIGHT_BOUND (tests only) may carry one decimal, so a test of the
# blocked path takes a fraction of a second; AppleScript's own timeout gets
# its whole seconds, at least one.
bound="${TCC_PREFLIGHT_BOUND:-}"
if [ -n "$bound" ]; then
    [[ "$bound" =~ ^[0-9]+(\.[0-9])?$ ]] && [[ "$bound" =~ [1-9] ]] \
        || { echo "TCC_PREFLIGHT_BOUND must be positive seconds with at most one decimal, got '$bound'" >&2; exit 2; }
else
    bound="$(e2e_tcc_prompt_timeout)" || exit 2
fi
bound_whole="${bound%%.*}"
[ "$((10#$bound_whole))" -gt 0 ] || bound_whole=1
home="${TCC_PREFLIGHT_HOME:-$HOME}"
ls_cmd="${TCC_PREFLIGHT_LS:-ls}"
osa_cmd="${TCC_PREFLIGHT_OSASCRIPT:-osascript}"
grantee="${TCC_PREFLIGHT_GRANTEE:-}"
failed=0

# report <required:0|1> <grant> <verdict> <detail> — one line per probe, and
# for anything but `granted` an annotation and a step-summary entry that name
# the grant, the binary to allow, and, when the probe got no answer, that a
# prompt is probably waiting on the runner's screen.
report() {
    local required="$1" grant="$2" verdict="$3" detail="$4" level=warning why fix
    if [ "$verdict" = granted ]; then
        echo "[tcc-preflight] $grant: granted"
        return 0
    fi
    case "$verdict" in
        blocked) why="no answer within ${bound}s: a consent prompt is probably waiting on the runner's screen" ;;
        denied) why="refused: $detail" ;;
        *) why="the probe failed for a reason that is not a grant answer: $detail" ;;
    esac
    # Resolved only now: every probe granted is the common case.
    [ -n "$grantee" ] || grantee="$(tcc_grantee)"
    fix="$(tcc_fix_hint "$grant" "$grantee") After a runner update the node path changes and every grant has to be given again."
    if [ "$required" = 1 ]; then
        level=error
        failed=1
    fi
    echo "::$level title=TCC $grant not usable::$why. Fix: $fix"
    step_summary "### TCC preflight: $grant not usable ($verdict)"$'\n\n'"$why."$'\n\n'"Fix: $fix"
}

# probe <cmd> [args...] — run a probe under the bound. PROBE_VERDICT and
# PROBE_DETAIL (stdout and stderr, one line) describe it; PROBE_STDOUT is its
# last non-empty stdout line alone, for a probe whose answer is a value.
probe() {
    local out err status=0
    # A failed mktemp is a host problem, not a grant answer: status 2, said so.
    err="$(mktemp "${TMPDIR:-/tmp}/tcc-preflight-err.XXXXXX")" \
        || { echo "::error title=TCC preflight could not run::mktemp failed under ${TMPDIR:-/tmp}"; exit 2; }
    out="$(run_bounded "${PROBE_BOUND:-$bound}" "$@" 2>"$err")" || status=$?
    PROBE_STDOUT="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n 1)"
    out="$out"$'\n'"$(cat "$err")"
    rm -f "$err"
    PROBE_VERDICT="$(tcc_probe_verdict "$status" "$out")"
    PROBE_DETAIL="$(printf '%s' "$out" | sed '/^[[:space:]]*$/d' | tr '\n' ' ' | sed 's/ *$//' | cut -c1-300)"
}

if [ -n "$want_downloads" ]; then
    if [ -d "$home/Downloads" ]; then
        probe "$ls_cmd" -A "$home/Downloads"
        report 1 "Files & Folders → Downloads" "$PROBE_VERDICT" "$PROBE_DETAIL"
    else
        echo "[tcc-preflight] $home/Downloads does not exist; nothing to probe"
    fi
fi

if [ -n "$want_automation" ]; then
    # AppleScript's own timeout inside the outer bound, so a pending prompt
    # answers -1712 when it can and is cut off by the bound when it cannot.
    PROBE_BOUND=$((10#$bound_whole + 5)) probe "$osa_cmd" -e "with timeout of $bound_whole seconds" \
        -e 'tell application "System Events" to get name of first process whose frontmost is true' \
        -e 'end timeout'
    report 0 "Automation → System Events" "$PROBE_VERDICT" "$PROBE_DETAIL"
fi

if [ -n "$want_accessibility" ]; then
    # AXIsProcessTrusted answers at once and never prompts; `false` is its
    # only refusal.
    probe "$osa_cmd" -l JavaScript -e 'ObjC.import("ApplicationServices"); $.AXIsProcessTrusted()'
    # The answer is the last stdout line: a warning osascript prints on stderr
    # must not turn a granted host into a refused one.
    if [ "$PROBE_VERDICT" = granted ] && [ "$PROBE_STDOUT" != true ]; then
        PROBE_VERDICT=denied
        PROBE_DETAIL="AXIsProcessTrusted() is ${PROBE_STDOUT:-<empty>}"
    fi
    report 0 "Device Control and Data Access (Accessibility)" "$PROBE_VERDICT" "$PROBE_DETAIL"
fi

[ "$failed" = 0 ] || echo "[tcc-preflight] a required grant is missing; stopping the job here rather than letting each lane hang into its step timeout" >&2
exit "$failed"
