#!/usr/bin/env bash
# Prepend a keychain to the macOS user-domain search list, idempotently
# and atomically with respect to other concurrent invocations.
#
# `security list-keychains -d user -s X Y` REPLACES the list, so multiple
# processes mutating it concurrently can lose each other's writes. This
# helper:
#   - read + dedup + write under a `shlock`-guarded lockfile so two
#     concurrent invocations are serialized,
#   - leaves whatever else was already in the list intact and pushes the
#     target keychain to the front,
#   - is idempotent on re-run (running twice = single entry at the front).
#
# Lockfile lives in $TMPDIR (or /tmp). `shlock(1)` ships with macOS and
# uses PID-based stale-lock detection: a crashed prior holder is cleared
# automatically on the next acquire attempt.
#
# Usage: scripts/keychain-prepend.sh /absolute/path/to/keychain.keychain-db

set -euo pipefail

keychain=${1:?keychain path required}

lockfile="${TMPDIR:-/tmp}/keychain-search-list.lock"
# Spin-wait up to ~5 s. `security` mutations themselves are sub-100 ms,
# so a contended Mini run resolves in a handful of retries.
for _ in $(seq 1 100); do
    if shlock -f "$lockfile" -p $$ >/dev/null 2>&1; then
        # shellcheck disable=SC2064  # expand $lockfile at trap-set time
        trap "rm -f '$lockfile'" EXIT
        break
    fi
    sleep 0.05
done
if [[ ! -f "$lockfile" ]]; then
    echo "keychain-prepend: failed to acquire $lockfile within 5 s" >&2
    exit 1
fi

# `security list-keychains -d user` prints one quoted path per line.
# Read into an array so the write below is whitespace-safe — bash 3.2
# compatible (no `mapfile`, since macOS still ships bash 3.2 system-wide).
# Trim via `awk`: strip surrounding whitespace + quotes, skip blanks,
# skip our own keychain (dedup so it ends up exactly once at the front).
existing=()
while IFS= read -r entry; do
    existing+=("$entry")
done < <(
    security list-keychains -d user \
        | awk -v skip="$keychain" '
            {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                gsub(/^"|"$/, "")
                if ($0 != "" && $0 != skip) print
            }
        '
)

security list-keychains -d user -s "$keychain" "${existing[@]+"${existing[@]}"}"
