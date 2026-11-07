#!/usr/bin/env bash
# Reports commits on the current branch that carry a trailer written by an AI
# tool, so the rebase merge does not copy it onto `main`. Advisory: see
# .github/workflows/ci.yml. Same structure and exit-code contract as
# check-merge-commits.sh; a fix to the shared parts (base-ref check, output
# fence) belongs in both.
#
# Usage: check-tool-trailers.sh <base-ref>      e.g. origin/main, or main locally
#
# Exit codes:
#   0  no tool trailers between <base-ref> and HEAD
#   1  tool trailers found (a contributor-fixable branch state)
#   2  the check could not run (unresolvable base ref, git failure)
#
# What counts, matched per trailer line:
#   - a line starting with a key ending in `Session` whose value is a link
#     (`Claude-Session: https://...`), the shape tools use;
#   - a `Co-Authored-By:` whose ADDRESS belongs to an AI tool. Matching the address
#     rather than the name keeps a human co-author called Claude out of it. Only
#     the addresses listed below are known (Claude, Copilot, Cursor); add one
#     when another tool shows up on a PR.

set -uo pipefail

base="${1:-}"
if [ -z "$base" ]; then
    echo "usage: $(basename "$0") <base-ref>" >&2
    exit 2
fi

if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
    echo "Tool-trailer check could not run: CI could not resolve the base ref '${base}'." >&2
    echo "This is a CI problem, not a problem with this branch. The checkout step" >&2
    echo "needs enough history for '${base}' to exist." >&2
    exit 2
fi

# A link value, so prose such as "URLSession: the delegate ..." is left alone.
session_key='^[A-Za-z0-9-]*session:[[:space:]]*https?://'
# Not every `[bot]@users.noreply.github.com`: an autofix action or dependabot is
# a bot, not an AI author, and must not be reported as one.
ai_address='^co-authored-by:.*<[^>]*(noreply@anthropic\.com|\+copilot@users\.noreply\.github\.com|cursoragent@cursor\.com)>'

if ! commits=$(git log --format=%h "${base}..HEAD"); then
    echo "Tool-trailer check could not run: git log failed for '${base}..HEAD'." >&2
    exit 2
fi

# One line per offending trailer: "<short sha> <Key>: <value>".
hits=""
for commit in $commits; do
    # The whole message, not `%(trailers)`: git's trailer parser skips a last
    # paragraph that mixes trailers with other lines ("Generated with ..." right
    # above a Co-Authored-By), which is exactly what tools write.
    if ! message=$(git log -1 --format=%B "$commit"); then
        echo "Tool-trailer check could not run: git log failed for ${commit}." >&2
        exit 2
    fi
    found=$(printf '%s\n' "$message" | grep -iE "${session_key}|${ai_address}" || true)
    if [ -n "$found" ]; then
        hits+="$(printf '%s\n' "$found" | sed "s/^/${commit} /")"$'\n'
    fi
done

if [ -z "$hits" ]; then
    echo "No tool trailers between ${base} and HEAD."
    exit 0
fi

if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error title=AI tool trailer on branch::See the job log. Advisory check: it does not block the merge."
fi

echo "Commits with a trailer written by an AI tool between ${base} and HEAD:"
# Trailer values are contributor-controlled text; fence them so a line starting
# with `::` cannot act as a workflow command (same reason as check-merge-commits.sh).
fence=""
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    fence="tool-trailer-list-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    echo "::stop-commands::${fence}"
fi
printf '%s' "$hits" | sed 's/^/  /'
if [ -n "$fence" ]; then
    echo "::${fence}::"
fi

cat <<'EOF'

Please remove these trailers. A session link points at a private session that
nobody reading the public history can open, and an AI co-author line credits a
tool as an author; the rebase merge would copy both onto main unchanged. Say
in the PR description instead which model wrote the change and which ones
reviewed it (CONTRIBUTING.md, Hygiene). A human co-author is fine.

To remove them, reword those commits in an interactive rebase and push with
--force-with-lease; to stop new ones, switch the trailer off in your tool's
commit settings. Would rather not rewrite history? Leave "Allow edits by
maintainers" checked and a maintainer removes them before merging.

This check is advisory and does not block the merge.
EOF

exit 1
