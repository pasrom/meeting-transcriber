#!/usr/bin/env bash
# Check notarization status for a submission.
#
# Usage:
#   ./scripts/notarize_status.sh <submission-id>
#   ./scripts/notarize_status.sh              # shows history
#
# Reads APPLE_ID, TEAM_ID, APP_PASSWORD from .env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

for var in APPLE_ID TEAM_ID APP_PASSWORD; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var not set. Add it to .env"
        exit 1
    fi
done

AUTH=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")

if [ $# -ge 1 ]; then
    xcrun notarytool info "$1" "${AUTH[@]}"
else
    xcrun notarytool history "${AUTH[@]}"
fi
