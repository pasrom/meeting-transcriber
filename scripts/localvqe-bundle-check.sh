#!/usr/bin/env bash
# Verify the vendored LocalVQE static library works from inside the signed
# .app bundle that build_release.sh produces — not only from a SwiftPM build
# directory. The library resolves its compute backends relative to the
# executable's own path (visible in its "self-resolved from ..." log line), so
# Contents/MacOS placement is the case that needs proving, and this script is
# that check.
#
# Usage:
#   ./scripts/localvqe-bundle-check.sh [--no-build]
#
#   --no-build   Reuse an existing .build/release/MeetingTranscriber.app
#                  instead of rebuilding.
#
# MEETINGTRANSCRIBER_LOCALVQE_MODEL is unset for the probe, deliberately. It
# takes precedence in the app's resolver, so leaving an exported one in place
# would have the probe load THAT model while this script reported the bundled
# one: a green check that never touched the artifact under test. To compare
# model variants, pass a path to the binary directly; that is not a bundle
# check and should not be reported as one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/.build/release/MeetingTranscriber.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/MeetingTranscriber"

SKIP_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --no-build) SKIP_BUILD=true ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

if [ "$SKIP_BUILD" = false ] || [ ! -x "$APP_BINARY" ]; then
    "$SCRIPT_DIR/build_release.sh" --no-notarize
fi

echo ""
echo "=== localvqe-bundle-check ==="
codesign --verify --deep --strict "$APP_BUNDLE"
echo "Bundle signature verified: $APP_BUNDLE"

# One probe, no model argument and no override, so the resolution path under
# test is the one a user gets. Covers backend registration, clean failure of a
# bogus model load, and a full streaming pass over synthetic audio from
# Contents/MacOS.
echo ""
echo "--- bundle probe ---"
PROBE_OUT="$(env -u MEETINGTRANSCRIBER_LOCALVQE_MODEL "$APP_BINARY" --localvqe-selftest 2>&1)" || {
    echo "$PROBE_OUT"
    echo "FAIL: selftest exited non-zero" >&2
    exit 1
}
echo "$PROBE_OUT"
grep -q "LOCALVQE_SELFTEST_OK model" <<< "$PROBE_OUT" || {
    echo "FAIL: no model ran. The bundle carries no resolvable model." >&2
    exit 1
}

# Assert WHICH model ran, from the binary's own report, rather than listing the
# directory and assuming the two agree. Listing proves a file is present; this
# proves the file was loaded.
LOADED="$(sed -n 's/^localvqe-selftest: model=//p' <<< "$PROBE_OUT" | head -1)"
case "$LOADED" in
    "$APP_BUNDLE/Contents/Resources/"*)
        echo "Loaded from the bundle: $(basename "$LOADED")"
        ;;
    *)
        echo "FAIL: the probe loaded a model from outside the bundle: ${LOADED:-<unreported>}" >&2
        exit 1
        ;;
esac

echo ""
echo "localvqe-bundle-check: OK"
