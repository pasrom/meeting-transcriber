#!/usr/bin/env bash
# Reports merge commits on the current branch. Advisory: see .github/workflows/ci.yml.
#
# Usage: check-merge-commits.sh <base-ref>      e.g. origin/main, or main locally
#
# Exit codes are distinct on purpose:
#   0  no merge commits between <base-ref> and HEAD
#   1  merge commits found (a contributor-fixable branch state)
#   2  the check could not run (unresolvable base ref, git failure)
#
# What this is NOT for: `main` cannot acquire a merge commit in the first place.
# The repo allows rebase-merge only, and a rebase drops merge commits rather
# than replaying them (verified: a branch with `Merge branch 'main'` rebased
# onto main keeps the real commit and loses the merge). GitHub's rebase-merge is
# that same rebase, server-side. What a merge commit costs is the review of the
# open PR: it pulls commits that are already on the base branch into the
# branch's commit list, so reading the PR commit by commit stops showing what
# the contributor actually changed.

set -uo pipefail

base="${1:-}"
if [ -z "$base" ]; then
    echo "usage: $(basename "$0") <base-ref>" >&2
    exit 2
fi

# Precondition, kept separate from the check itself: an unresolvable base ref is
# a CI problem (shallow clone, missing fetch, renamed branch), not something the
# contributor did. Without this it surfaces as a raw `fatal: bad revision`,
# which reads like a verdict on the branch.
if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
    echo "Merge-commit check could not run: CI could not resolve the base ref '${base}'." >&2
    echo "This is a CI problem, not a problem with this branch. The checkout step" >&2
    echo "needs enough history for '${base}' to exist." >&2
    exit 2
fi

if ! merges=$(git rev-list --merges "${base}..HEAD"); then
    echo "Merge-commit check could not run: git rev-list failed for '${base}..HEAD'." >&2
    exit 2
fi

if [ -z "$merges" ]; then
    echo "No merge commits between ${base} and HEAD."
    exit 0
fi

branch="${base##*/}"
repo_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-pasrom/meeting-transcriber}"

if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error title=Merge commit on branch::This branch merges ${branch} instead of rebasing onto it. Advisory check: it does not block the merge."
fi

echo "Merge commits between ${base} and HEAD:"
# Commit subjects are contributor-controlled text. The runner reads any line
# starting with `::` as a workflow command, so an attacker-chosen subject could
# forge or suppress one. Fence the untrusted block with the documented
# stop-commands mechanism rather than trusting the subjects to be inert.
fence=""
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    fence="merge-commit-list-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    echo "::stop-commands::${fence}"
fi
git log --merges --format='  %h %s' "${base}..HEAD"
if [ -n "$fence" ]; then
    echo "::${fence}::"
fi

cat <<EOF

This does not endanger ${branch}: the repo allows rebase-merge only, and a
rebase drops merge commits, so the merge would never land there. It costs the
review of this PR. Its commit list now carries commits that are already on
${branch}, so reading the branch commit by commit no longer shows your change,
and CONTRIBUTING.md asks for a rebase for exactly that reason.

Rebase onto ${branch}. Spelling the URL out works in a fork clone too, where
'origin' is your fork rather than this repo:

  git fetch ${repo_url} ${branch}
  git rebase FETCH_HEAD
  git push --force-with-lease

The "Update branch" button on the PR page is the likeliest way a branch picks
one up: it creates a merge commit by default. Use "Update with rebase" from its
dropdown instead.

Would rather not rewrite history? Leave "Allow edits by maintainers" checked and
a maintainer folds the commits before merging, as CONTRIBUTING.md offers.

This check is advisory and does not block the merge.
EOF

exit 1
