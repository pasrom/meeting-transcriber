#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes hold jq programs and literal backticks on purpose
# Credit new code contributors in the README's all-contributors table.
#
# Compares the GitHub contributors API with .all-contributorsrc, credits
# every missing human account for `code`, regenerates the table and opens
# (or refreshes) a pull request from a fixed branch. Bug reporters and
# testers never appear in that API, so they are still added by hand with
# `npx all-contributors-cli add <user> bug`.
#
# Runs in a throwaway clone, so the caller's checkout is never touched.
# Meant to run unattended, e.g. from a weekly launchd agent, as a
# maintainer whose `gh` login can push branches. A PR opened that way
# triggers CI like any other, which a PR opened with a workflow's
# GITHUB_TOKEN would not.
#
# Usage: scripts/update-contributors.sh [--dry-run]
#   --dry-run   print what would change, push nothing
# Env:
#   REPO       owner/name on GitHub        (default pasrom/meeting-transcriber)
#   BASE       branch to start from        (default main)
#   EXCLUDE    logins never to add, space-separated (default claude; bots
#              are skipped by account type)
#   CLONE_URL  where to clone from         (default the GitHub repo)
set -euo pipefail

REPO="${REPO:-pasrom/meeting-transcriber}"
BASE="${BASE:-main}"
EXCLUDE="${EXCLUDE:-claude}"
CLONE_URL="${CLONE_URL:-https://github.com/$REPO.git}"
BRANCH="docs/contributors-update"
CLI="all-contributors-cli@6.26.1"

dry_run=false
case "${1:-}" in
  --dry-run) dry_run=true ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

for tool in gh git jq npx; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone -q --depth 1 --branch "$BASE" "$CLONE_URL" "$work/repo"
cd "$work/repo"
[[ -f .all-contributorsrc ]] || { echo "no .all-contributorsrc on $BASE" >&2; exit 1; }

# Captured first: a failing `gh` inside a process substitution would not
# trip `set -e`, and an empty list would read as "nobody new".
contributors="$(gh api "repos/$REPO/contributors" --paginate \
  --jq '.[] | select(.type == "User") | .login')"
listed="$(jq -r '.contributors[].login' .all-contributorsrc)"

missing=()
while IFS= read -r login; do
  [[ -z "$login" ]] && continue
  grep -qixF -- "$login" <<<"$listed" && continue
  [[ " $EXCLUDE " == *" $login "* ]] && continue
  missing+=("$login")
done <<<"$contributors"

if (( ${#missing[@]} == 0 )); then
  echo "No new contributors."
  exit 0
fi
echo "New contributors: ${missing[*]}"

# Entries are built here from an authenticated `gh api` call instead of
# `all-contributors-cli add`, which queries GitHub anonymously (60 requests
# an hour, shared per IP) unless handed a token, and a token in its
# environment would be readable by every npm package it pulls in. The
# fields match what `add` writes: profile is the blog when it is an http(s)
# URL, else the GitHub profile, normalised the way `new URL()` does.
for login in "${missing[@]}"; do
  entry="$(gh api "users/$login" --jq '{
    login,
    name: (.name // .login),
    avatar_url,
    profile: ((.blog // "") as $b
      | (if ($b | test("^https?://")) then $b else .html_url end)
      | if test("^https?://[^/]+$") then . + "/" else . end),
    contributions: ["code"]
  }')"
  jq --indent 2 --argjson e "$entry" '.contributors += [$e | {login, name, avatar_url, profile, contributions}]' .all-contributorsrc > "$work/rc"
  mv "$work/rc" .all-contributorsrc
done
npx --yes "$CLI" generate

if $dry_run; then
  git --no-pager diff
  exit 0
fi

# Backticks render the handles as code, so nobody gets pinged.
handles="$(printf -- '- `%s`\n' "${missing[@]}")"
git switch -q -c "$BRANCH"
git add .all-contributorsrc README.md
git commit -q -m "docs: add new contributors to the README" -m "$handles"
# The branch belongs to this script: each run rebuilds it from $BASE.
git push -q --force origin "HEAD:refs/heads/$BRANCH"

pr="$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json url --jq '.[0].url // empty')"
if [[ -z "$pr" ]]; then
  pr="$(gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" \
    --title "docs: add new contributors to the README" \
    --body "Credits these accounts for \`code\` in the all-contributors table, found by \`scripts/update-contributors.sh\` in the GitHub contributors API:

$handles

Add bug reports, testing or other contribution types by hand before merging if they apply.")"
fi
echo "$pr"

if command -v osascript >/dev/null; then
  osascript -e "display notification \"${#missing[@]} new contributor(s): $pr\" with title \"meeting-transcriber\"" || true
fi
