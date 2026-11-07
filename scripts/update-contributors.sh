#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes hold jq programs and literal backticks on purpose
# Credit new code contributors in the README's all-contributors table.
#
# Finds every account that authored a merged pull request or appears in
# the GitHub contributors API but has no entry in .all-contributorsrc,
# credits it for `code`, regenerates the table and opens a pull request
# from a fixed branch. Merged PR authors are the main source: a commit whose
# email is not linked to a GitHub account never shows up in the
# contributors API, a PR always has an author. Bug reporters and testers
# are in neither, so other contribution types are still added by hand.
#
# Runs in a throwaway clone, so the caller's checkout is never touched.
# Meant to run unattended, e.g. from a weekly launchd agent, as a
# maintainer whose `gh` login can push branches. A PR opened that way runs
# CI like any other, which a PR opened with a workflow's GITHUB_TOKEN would
# not. Nothing from npm runs: the table is rendered by
# scripts/contributors-table.jq from the same clone.
#
# Lifecycle:
#   - an open PR from the branch is left alone (it may carry hand edits);
#     the run only reminds and exits
#   - accounts listed in a PR from the branch that was closed unmerged
#     count as declined and are not proposed again
#   - every failure ends in a macOS notification, not only in the log
#
# Usage: scripts/update-contributors.sh [--dry-run]
#   --dry-run   print what would change, push nothing
# Env:
#   REPO       owner/name on GitHub        (default pasrom/meeting-transcriber)
#   BASE       branch to start from        (default main)
#   EXCLUDE    logins never to add, space-separated, any case (default:
#              claude, and ghost, GitHub's stand-in author for deleted
#              accounts; bot accounts are skipped by type)
#   CLONE_URL  clone from somewhere else, --dry-run only (default the
#              GitHub repo); a real run pushes to the clone's origin
set -euo pipefail

REPO="${REPO:-pasrom/meeting-transcriber}"
OWNER="$(tr '[:upper:]' '[:lower:]' <<<"${REPO%%/*}")"
BASE="${BASE:-main}"
EXCLUDE="${EXCLUDE:-claude ghost}"
CLONE_URL="${CLONE_URL:-https://github.com/$REPO.git}"
BRANCH="docs/contributors-update"
TITLE="docs(docs): add new contributors to the README"

notify() {
  command -v osascript >/dev/null || return 0
  osascript -e "display notification \"$1\" with title \"meeting-transcriber contributors\"" || true
}

dry_run=false
case "${1:-}" in
  --dry-run) dry_run=true ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
if ! $dry_run && [[ "$CLONE_URL" != "https://github.com/$REPO.git" ]]; then
  echo "CLONE_URL is for --dry-run only: the branch must land where the PR is opened" >&2
  exit 2
fi

work="$(mktemp -d)"
finish() {
  local rc=$?
  rm -rf "$work"
  if (( rc != 0 )); then
    notify "Update failed (exit $rc), see the job's log"
  fi
}
trap finish EXIT

for tool in gh git jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

# PRs from the branch, own repository only: a fork can use the same name.
own_prs() {
  gh pr list --repo "$REPO" --head "$BRANCH" --state "$1" --limit 1000 \
    --json url,body,headRepositoryOwner \
    --jq "[.[] | select((.headRepositoryOwner.login | ascii_downcase) == \"$OWNER\")]"
}

open_pr="$(own_prs open | jq -r '.[0].url // empty')"
if [[ -n "$open_pr" ]]; then
  echo "Contributors PR still open, leaving it alone: $open_pr"
  $dry_run || notify "Contributors PR still waiting for review: $open_pr"
  exit 0
fi

git clone -q --depth 1 --branch "$BASE" "$CLONE_URL" "$work/repo"
cd "$work/repo"
[[ -f .all-contributorsrc ]] || { echo "no .all-contributorsrc on $BASE" >&2; exit 1; }
# The renderer comes from the same clone, so it always matches $BASE, also
# when this script runs from an installed copy.
render=scripts/contributors-table.jq
[[ -f "$render" ]] || { echo "no $render on $BASE" >&2; exit 1; }

# Captured into variables first: a failing `gh` inside a process
# substitution would not trip `set -e`, and an empty list would read as
# "nobody new". Lists are lower-cased: GitHub logins are case-insensitive.
lower() { tr '[:upper:]' '[:lower:]'; }
pr_authors="$(gh pr list --repo "$REPO" --base "$BASE" --state merged --limit 10000 --json author \
  --jq '.[] | select(.author.is_bot | not) | .author.login')"
api_users="$(gh api "repos/$REPO/contributors" --paginate \
  --jq '.[] | select(.type == "User") | .login')"
# Every account a closed PR from the branch proposed counts as handled:
# merged ones are in the table, unless the maintainer removed them on the
# branch before merging, and unmerged ones were declined. Either way they
# are not proposed again; to credit one later, add it by hand. Bodies
# edited in the web UI end lines with CRLF.
declined="$(own_prs closed | jq -r '.[].body' | tr -d '\r' \
  | sed -n 's/^- `\([A-Za-z0-9-]*\)`$/\1/p' | lower)"
skip="$( { jq -r '.contributors[].login' .all-contributorsrc; tr ' ' '\n' <<<"$EXCLUDE"; } | lower)"
skip="$skip"$'\n'"$declined"

# One pass over the deduplicated candidates (the raw list has one line per
# merged PR, mostly the maintainer).
missing=()
while IFS= read -r login; do
  [[ -z "$login" ]] && continue
  grep -qxF -- "$(lower <<<"$login")" <<<"$skip" && continue
  missing+=("$login")
done < <(printf '%s\n%s\n' "$pr_authors" "$api_users" | awk 'NF && !seen[tolower($0)]++')

if (( ${#missing[@]} == 0 )); then
  echo "No new contributors."
  exit 0
fi
echo "New contributors: ${missing[*]}"

# Fields as `all-contributors-cli add` writes them: an empty name falls
# back to the login; profile is the blog when it is an http(s) URL, else
# the GitHub profile, normalised like the `new URL().toString()` it uses
# for the forms GitHub profiles carry (trimmed, lower-case scheme and
# host, default port dropped, a "/" when the path is empty).
# Percent-encoding and other URL rewrites are not reproduced; they only
# affect this entry, the table is rendered from whatever the entry says.
for login in "${missing[@]}"; do
  entry="$(gh api "users/$login" --jq '{
    login,
    name: (if (.name // "") == "" then .login else .name end),
    avatar_url,
    profile: (((.blog // "") | gsub("^\\s+|\\s+$"; "")) as $blog
      | (if ($blog | test("^https?://[^/?#\\s]"; "i")) then $blog else .html_url end)
      | capture("^(?<scheme>[A-Za-z]+)://(?<host>[^/?#]*)(?<rest>.*)$")
      | (.scheme | ascii_downcase) as $s
      | "\($s)://\(.host | ascii_downcase | sub(if $s == "https" then ":443$" else ":80$" end; ""))"
        + (if (.rest | startswith("/")) then .rest else "/" + .rest end)),
    contributions: ["code"]
  }')"
  jq --indent 2 --argjson e "$entry" \
    '.contributors += [$e | {login, name, avatar_url, profile, contributions}]' \
    .all-contributorsrc > "$work/rc"
  mv "$work/rc" .all-contributorsrc
done
jq -j --rawfile readme README.md -f "$render" .all-contributorsrc > "$work/readme"
mv "$work/readme" README.md

if $dry_run; then
  git --no-pager diff
  exit 0
fi

# Backticks render the handles as code, so nobody gets pinged; the same
# list format is read back above to recognise declined accounts.
handles="$(printf -- '- `%s`\n' "${missing[@]}")"
git switch -q -c "$BRANCH"
git add .all-contributorsrc README.md
git commit -q -m "$TITLE" -m "$handles"
# No open PR uses the branch (checked above), so overwriting it loses
# nothing; a leftover branch from a closed PR is simply replaced.
git push -q --force origin "HEAD:refs/heads/$BRANCH"

pr="$(gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" --title "$TITLE" \
  --body "Credits these accounts for \`code\` in the all-contributors table. They authored a merged PR or appear in the contributors API but had no entry. Found by \`scripts/update-contributors.sh\`:

$handles

Add other contribution types (bug, userTesting, ideas, ...) on this branch before merging if they apply: edit \`.all-contributorsrc\`, then re-render the table with \`jq -j --rawfile readme README.md -f scripts/contributors-table.jq .all-contributorsrc > README.tmp && mv README.tmp README.md\`. The weekly run leaves an open PR alone. Closing this PR, merged or not, marks every account listed above as handled, and they are not proposed again; keep the list in this description as it is, since that is what the next run reads.")"
echo "$pr"
notify "${#missing[@]} new contributor(s): $pr"
