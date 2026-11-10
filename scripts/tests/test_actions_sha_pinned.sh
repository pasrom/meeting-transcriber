#!/bin/bash
# Regression test: every remote action is pinned to a commit SHA.
#
# A tag such as `actions/checkout@v7` can be moved by whoever controls it, and
# every job picks the new commit up on its next run, including jobs that hold
# signing material and repository tokens. A pin is a 40-character SHA followed
# by a `# vX.Y.Z` comment: Dependabot rewrites the SHA and that comment
# together only when the comment is there. Local actions (`./...`) and
# `docker://` images are out of scope.
# The file list below is word-split on purpose.
# shellcheck disable=SC2086
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

files=$(find .github/workflows .github/actions -name '*.yml' -o -name '*.yaml' | sort)
[ -n "$files" ] || { echo "no workflow files found ... FAIL"; exit 1; }

remote=$(grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:' $files \
    | grep -vE 'uses:[[:space:]]*["'\'']?(\./|docker://)' || true)
offenders=$(printf '%s\n' "$remote" \
    | grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]+(\.[0-9]+)*[[:space:]]*$' || true)

if [ -z "$remote" ] || [ -n "$offenders" ]; then
    echo "remote actions pinned to a SHA with a version comment ... FAIL:"
    printf '%s\n' "${offenders:-no remote uses: line found, so this check reads nothing}"
    exit 1
fi
echo "remote actions pinned to a SHA with a version comment ($(printf '%s\n' "$remote" | wc -l | tr -d ' ') lines) ... PASS"
