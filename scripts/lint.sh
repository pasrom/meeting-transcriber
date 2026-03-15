#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swiftlint &>/dev/null; then
    echo "Error: swiftlint not found. Install with: brew install swiftlint"
    exit 1
fi

if [[ "${1:-}" == "--fix" ]]; then
    swiftlint lint --fix
else
    swiftlint lint "$@"
fi
