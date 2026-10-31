#!/usr/bin/env bash
# Checks on a built App Store (sandboxed) bundle that a mere "it launched"
# smoke cannot see. Used by .github/workflows/appstore.yml.
#
# Usage:
#   ./scripts/appstore-bundle-check.sh entitlements <app> <expected.entitlements>
#   ./scripts/appstore-bundle-check.sh launch <app>
#
# entitlements
#   The entitlements embedded in the signed bundle must equal the committed
#   file key for key, plist type included (<integer>1 is not <true/>), and
#   that file must enable the sandbox. A bundle signed with no or the wrong
#   entitlements still launches, so the launch check cannot see this.
#   Applies to bundles signed with exactly that file, i.e. build_release.sh
#   --no-notarize. The Developer ID path may add a provisioning-profile key
#   (see scripts/lib/signing.sh), which this check would report as extra.
#
# launch
#   The bundle must survive 5 s and must have written its liveness marker
#   (AppPaths.livenessMarker: `<bundle-id>.running` in AppPaths.dataDir,
#   holding its PID, written first thing at launch) inside its container,
#   ~/Library/Containers/<bundle-id>/Data/Library/Application Support/MeetingTranscriber,
#   and not into the non-container ~/Library/Application Support/MeetingTranscriber.
#   Writes there are attributed by the PID in the marker, not by comparing
#   the folder before and after: a dev or Homebrew build on the same machine
#   may own that folder and write to it during the run, and only a marker
#   naming the launched PID can have come from this run. Only the process
#   this script launched is stopped, and a marker naming it is removed
#   afterwards, as its clean quit would have done, so the next real launch
#   of that build does not report a crash; nothing else is touched.
#
# The functions are sourced by scripts/tests/test_appstore_bundle_check.sh;
# main runs only when the file is executed.

set -euo pipefail

# The folder name AppPaths.dataDir appends to Application Support.
DATA_DIR_NAME="MeetingTranscriber"

# compare_entitlements <expected.plist> <actual.plist>
# An empty <actual> means the bundle carries no entitlements at all.
compare_entitlements() {
    python3 -I - "$1" "$2" <<'PY'
import plistlib
import sys

expected_path, actual_path = sys.argv[1:3]
SANDBOX_KEY = "com.apple.security.app-sandbox"


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    return plistlib.loads(data) if data.strip() else {}


expected = load(expected_path)
actual = load(actual_path)


def canonical(value):
    # Serialised so the comparison sees the plist type, not just Python
    # equality, under which True == 1.
    return plistlib.dumps({"v": value}, sort_keys=True)


errors = []
for key in sorted(expected.keys() - actual.keys()):
    errors.append(f"missing from signed bundle: {key}")
for key in sorted(actual.keys() - expected.keys()):
    errors.append(f"not in committed file: {key} = {actual[key]!r}")
for key in sorted(expected.keys() & actual.keys()):
    if canonical(expected[key]) != canonical(actual[key]):
        errors.append(f"value differs: {key}: expected {expected[key]!r}, signed {actual[key]!r}")
# The committed file is the reference, so it must not be able to switch the
# sandbox off; the comparison above then holds the bundle to it.
if expected.get(SANDBOX_KEY) is not True:
    errors.append(f"committed file does not set {SANDBOX_KEY} to true")

if errors:
    for line in errors:
        print(f"  {line}")
    sys.exit(1)
print(f"  {len(actual)} entitlements match the committed file")
PY
}

check_entitlements() {
    local app="$1" expected="$2" actual
    actual="$(mktemp)"
    # stdout carries only the XML plist; codesign's "Executable=" banner goes
    # to stderr. A bundle without entitlements prints nothing.
    if ! codesign -d --entitlements - --xml "$app" >"$actual"; then
        rm -f "$actual"
        echo "codesign could not read the signature of $app" >&2
        return 1
    fi
    echo "Entitlements of $app vs $expected:"
    local status=0
    compare_entitlements "$expected" "$actual" || status=$?
    rm -f "$actual"
    return "$status"
}

# check_data_location <container-data-dir> <host-data-dir> <bundle-id> <pid>
check_data_location() {
    local container_dir="$1" host_dir="$2" bundle_id="$3" pid="$4"
    local marker="$container_dir/$bundle_id.running"
    local host_marker="$host_dir/$bundle_id.running" status=0

    if [ ! -f "$marker" ]; then
        echo "  no liveness marker in the container: $marker"
        echo "  (if AppPaths.dataDir or AppPaths.livenessMarker was renamed, update this script)"
        status=1
    elif [ "$(<"$marker")" != "$pid" ]; then
        echo "  container marker names PID $(<"$marker"), launched app is $pid"
        status=1
    else
        echo "  container marker present and names PID $pid"
    fi

    if [ -f "$host_marker" ] && [ "$(<"$host_marker")" = "$pid" ]; then
        echo "  the launched app wrote its marker outside the container: $host_marker"
        status=1
    else
        echo "  no marker of the launched app outside the container"
    fi
    return "$status"
}

# command_regex <path>: an extended regex for `pgrep -f` that matches a
# command line starting with <path>, taken literally, as the whole first
# word. Unanchored, a tool whose arguments mention the path would match too.
command_regex() {
    printf '^%s( |$)' "$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
}

# stop_launched <pid> <marker>...: SIGTERM, SIGKILL after 5 s, and a failure
# if the process outlives that by 5 s more. Then removes each marker that
# still names <pid>: SIGTERM skips AppKit's quit path, which is what would
# have removed it, and a leftover reads as a crash to the next launch.
stop_launched() {
    local pid="$1" i marker; shift
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        if [ "$i" -eq 10 ]; then kill -KILL "$pid" 2>/dev/null || true; fi
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "launched app (PID $pid) is still running after SIGKILL" >&2
        return 1
    fi
    for marker in "$@"; do
        if [ -f "$marker" ] && [ "$(<"$marker")" = "$pid" ]; then
            rm -f "$marker"
        fi
    done
}

launch_and_check() {
    local app
    # LaunchServices runs the binary at its physical path; match that one.
    app="$(cd "$1" && pwd -P)"
    local plist="$app/Contents/Info.plist"
    local bundle_id executable binary pattern
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
    binary="$app/Contents/MacOS/$executable"
    pattern="$(command_regex "$binary")"

    local container_dir="$HOME/Library/Containers/$bundle_id/Data/Library/Application Support/$DATA_DIR_NAME"
    local host_dir="$HOME/Library/Application Support/$DATA_DIR_NAME"

    if pgrep -f -- "$pattern" >/dev/null; then
        echo "$binary is already running; refusing to judge a run this script did not start." >&2
        return 1
    fi

    local stamp pids pid
    stamp="$(mktemp)"
    # `open` needs an absolute path; -n starts a fresh instance.
    open -na "$app"
    sleep 5
    pids="$(pgrep -f -- "$pattern" || true)"
    if [ -z "$pids" ]; then
        echo "$executable died within 5 s of launch."
        echo "--- Crash report from this run (if any): ---"
        find "$HOME/Library/Logs/DiagnosticReports" -name "$executable-*.ips" -newer "$stamp" \
            -exec cat {} + 2>/dev/null | grep . || echo "no crash report found"
        rm -f "$stamp"
        return 1
    fi
    rm -f "$stamp"
    if [ "$(printf '%s\n' "$pids" | wc -l)" -ne 1 ]; then
        echo "More than one process runs $binary: $(printf '%s ' "$pids")" >&2
        return 1
    fi
    pid="$pids"
    echo "Launched $bundle_id (PID $pid), alive after 5 s. Data location:"

    local status=0
    check_data_location "$container_dir" "$host_dir" "$bundle_id" "$pid" || status=$?
    stop_launched "$pid" "$container_dir/$bundle_id.running" "$host_dir/$bundle_id.running" || status=1
    return "$status"
}

main() {
    if [ $# -ge 2 ] && [ ! -d "$2" ]; then
        echo "No app bundle at $2. Contents of $(dirname "$2"):" >&2
        ls -la "$(dirname "$2")" >&2 || true
        exit 1
    fi
    case "${1:-}" in
        entitlements)
            [ $# -eq 3 ] || { echo "usage: $0 entitlements <app> <expected.entitlements>" >&2; exit 2; }
            check_entitlements "$2" "$3"
            ;;
        launch)
            [ $# -eq 2 ] || { echo "usage: $0 launch <app>" >&2; exit 2; }
            launch_and_check "$2"
            ;;
        *)
            echo "usage: $0 entitlements <app> <expected.entitlements> | launch <app>" >&2
            exit 2
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
