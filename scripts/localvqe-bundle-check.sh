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
# Environment:
#   MEETINGTRANSCRIBER_LOCALVQE_MODEL
#       Optional path to a LocalVQE AEC .gguf. When set, a full streaming
#       pass over synthetic audio runs through the model from inside the
#       bundle. Without it only the link-level probe runs — the model is
#       deliberately not bundled with the app.

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

# Tier 1 — link-level probe, no model: backend registration + clean failure
# of a bogus model load, executed from Contents/MacOS.
echo ""
echo "--- link-only probe ---"
LINK_OUT="$("$APP_BINARY" --localvqe-selftest 2>&1)" || {
    echo "$LINK_OUT"
    echo "FAIL: link-only selftest exited non-zero" >&2
    exit 1
}
echo "$LINK_OUT"
grep -q "LOCALVQE_SELFTEST_OK link-only" <<< "$LINK_OUT" || {
    echo "FAIL: link-only success marker missing" >&2
    exit 1
}

# Tier 2 — full streaming pass through a real model, when one is available.
if [ -n "${MEETINGTRANSCRIBER_LOCALVQE_MODEL:-}" ]; then
    echo ""
    echo "--- model probe ($MEETINGTRANSCRIBER_LOCALVQE_MODEL) ---"
    MODEL_OUT="$("$APP_BINARY" --localvqe-selftest "$MEETINGTRANSCRIBER_LOCALVQE_MODEL" 2>&1)" || {
        echo "$MODEL_OUT"
        echo "FAIL: model selftest exited non-zero" >&2
        exit 1
    }
    echo "$MODEL_OUT"
    grep -q "LOCALVQE_SELFTEST_OK model" <<< "$MODEL_OUT" || {
        echo "FAIL: model success marker missing" >&2
        exit 1
    }
else
    echo ""
    echo "MEETINGTRANSCRIBER_LOCALVQE_MODEL not set — skipped the model pass."
fi

echo ""
echo "localvqe-bundle-check: OK"
