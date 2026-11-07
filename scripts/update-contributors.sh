#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes hold jq programs and literal backticks on purpose
# Credit new code contributors in the all-contributors table (the file
# named in .all-contributorsrc `files`, CONTRIBUTORS.md here) and keep the
# README's one-row preview of it current.
#
# Finds every account that authored a merged pull request or appears in
# the GitHub contributors API but has no entry in .all-contributorsrc,
# credits it for `code`, re-sorts the list by activity, regenerates the
# table and the preview, and opens a pull request from a fixed branch.
# Merged PR authors are the main source: a commit whose email is not linked
# to a GitHub account never shows up in the contributors API, a PR always
# has an author. Bug reporters and testers are in neither, so other
# contribution types are added by hand, followed by `--render`.
#
# Activity, which decides the order and so who the README preview shows:
# merged PRs into $BASE or commits on the default branch (the only branch
# the contributors API counts), whichever is higher, plus issues opened.
# Commits count as well because some contributions landed without a merged
# PR of their own. Ties keep the existing order. The list is re-sorted only
# in runs that add someone, so shifts among people already listed wait for
# the next newcomer; sorting every week would open a PR for order alone.
#
# Runs in a throwaway clone, so the caller's checkout is never touched.
# Run it from a fresh checkout of $BASE (a launcher can clone main and
# start this file from there), so the script, the renderers it loads from
# its own clone, and the table layout always agree. Meant to run
# unattended, e.g. from a weekly launchd agent, as a maintainer whose `gh`
# login can push branches. A PR opened that way runs CI like any other,
# which a PR opened with a workflow's GITHUB_TOKEN would not. Nothing from
# npm runs: scripts/contributors-table.jq and contributors-preview.jq render.
#
# Lifecycle:
#   - an open PR from the branch is left alone (it may carry hand edits);
#     the run only reminds and exits
#   - accounts listed in a closed PR from the branch, merged or not, count
#     as handled and are not proposed again
#   - every failure ends in a macOS notification, not only in the log
#
# Usage: scripts/update-contributors.sh [--dry-run | --render]
#   --dry-run   print what would change, push nothing
#   --render    re-render the table and the README preview from
#               .all-contributorsrc, offline, in the checkout this script
#               lives in (after editing it by hand)
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
TITLE="docs(docs): add new contributors"

notify() {
  command -v osascript >/dev/null || return 0
  osascript -e "display notification \"$1\" with title \"meeting-transcriber contributors\"" || true
}

# Check the layout in the current directory and set TABLE to the file the
# table lives in (the single entry of `files`). Both renderers run once
# into /dev/null, so a broken marker in either file shows up here, before
# the run spends its API calls.
check_layout() {
  local f
  for f in .all-contributorsrc README.md scripts/contributors-table.jq scripts/contributors-preview.jq; do
    [[ -f "$f" ]] || { echo "no $f here" >&2; return 1; }
  done
  TABLE="$(jq -er 'if (.files | type) == "array" and (.files | length) == 1 and (.files[0] | type) == "string"
    then .files[0] else error("files in .all-contributorsrc must name exactly one file") end' .all-contributorsrc)" \
    || return 1
  [[ -f "$TABLE" ]] || { echo "no $TABLE here" >&2; return 1; }
  [[ "$TABLE" != README.md ]] \
    || { echo "the table must not live in README.md, which holds the preview" >&2; return 1; }
  jq -j --rawfile file "$TABLE" -f scripts/contributors-table.jq .all-contributorsrc >/dev/null || return 1
  jq -j --rawfile file README.md --arg table "$TABLE" -f scripts/contributors-preview.jq \
    .all-contributorsrc >/dev/null || return 1
}

# Re-render the table and the README preview from .all-contributorsrc in
# the current directory and set RENDERED to the files written. Each file is
# rendered into a sibling copy (cp -p keeps its mode), and only once both
# rendered are they renamed into place, so a failed render leaves both
# files as they were and an interrupted write never truncates one; the two
# renames are the only window. Every step returns on failure explicitly:
# callers must not run this inside $(...), where bash switches `set -e` off.
render_all() {
  local t_new r_new
  RENDERED=()
  check_layout || return 1
  t_new="$TABLE.render.$$"
  r_new="README.md.render.$$"
  { cp -p "$TABLE" "$t_new" && cp -p README.md "$r_new"; } || { rm -f "$t_new" "$r_new"; return 1; }
  { jq -j --rawfile file "$TABLE" -f scripts/contributors-table.jq .all-contributorsrc > "$t_new" \
      && jq -j --rawfile file README.md --arg table "$TABLE" -f scripts/contributors-preview.jq \
           .all-contributorsrc > "$r_new"; } \
    || { rm -f "$t_new" "$r_new"; return 1; }
  { mv "$t_new" "$TABLE" && mv "$r_new" README.md; } || { rm -f "$t_new" "$r_new"; return 1; }
  RENDERED=("$TABLE" README.md)
}

mode=run
case "${1:-}" in
  --dry-run) mode=dry ;;
  --render) mode=render ;;
  "") ;;
  *) echo "usage: $0 [--dry-run | --render]" >&2; exit 2 ;;
esac

tools="gh git jq"
[[ $mode == render ]] && tools="jq"
for tool in $tools; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

if [[ $mode == render ]]; then
  # The checkout this script belongs to, not the caller's directory;
  # CDPATH could otherwise resolve a relative path into another tree.
  CDPATH='' cd -- "$(dirname -- "$0")/.."
  # This writes in the user's checkout: an interrupt must not leave the
  # sibling copies behind.
  trap 'rm -f -- "${TABLE:-}.render.$$" "README.md.render.$$"' EXIT
  render_all
  echo "Re-rendered ${RENDERED[*]} from .all-contributorsrc."
  exit 0
fi

if [[ $mode == run && "$CLONE_URL" != "https://github.com/$REPO.git" ]]; then
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

# PRs from the branch, own repository only: a fork can use the same name.
own_prs() {
  gh pr list --repo "$REPO" --head "$BRANCH" --state "$1" --limit 1000 \
    --json url,body,headRepositoryOwner \
    --jq "[.[] | select((.headRepositoryOwner.login | ascii_downcase) == \"$OWNER\")]"
}

open_pr="$(own_prs open | jq -r '.[0].url // empty')"
if [[ -n "$open_pr" ]]; then
  echo "Contributors PR still open, leaving it alone: $open_pr"
  [[ $mode == dry ]] || notify "Contributors PR still waiting for review: $open_pr"
  exit 0
fi

git clone -q --depth 1 --branch "$BASE" "$CLONE_URL" "$work/repo"
cd "$work/repo"
# Fail on a broken layout before the expensive API calls below (only the
# open-PR lookup above has run so far).
check_layout

# Captured into variables first: a failing `gh` inside a process
# substitution would not trip `set -e`, and an empty list would read as
# "nobody new". Lists are lower-cased: GitHub logins are case-insensitive.
lower() { tr '[:upper:]' '[:lower:]'; }
pr_authors="$(gh pr list --repo "$REPO" --base "$BASE" --state merged --limit 10000 --json author \
  --jq '.[] | select(.author.is_bot | not) | .author.login')"
api_json="$(gh api "repos/$REPO/contributors" --paginate \
  --jq '.[] | select(.type == "User") | {login, commits: .contributions}' | jq -s .)"
api_users="$(jq -r '.[].login' <<<"$api_json")"
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

# Re-sort everyone by activity (see the header), so a newcomer who is more
# active than someone already listed moves up instead of staying at the end.
issue_authors="$(gh api "repos/$REPO/issues?state=all&per_page=100" --paginate \
  --jq '.[] | select(.pull_request | not) | .user.login')"
jq --indent 2 --arg prs "$pr_authors" --arg issues "$issue_authors" --argjson api "$api_json" '
  def counts($s): $s | split("\n") | map(select(. != "") | ascii_downcase)
    | group_by(.) | map({key: .[0], value: length}) | from_entries;
  counts($prs) as $p | counts($issues) as $i
  | ($api | map({key: (.login | ascii_downcase), value: .commits}) | from_entries) as $c
  | .contributors |= (to_entries
      | sort_by((.value.login // .value.name // "" | ascii_downcase) as $k
          | -(([$p[$k] // 0, $c[$k] // 0] | max) + ($i[$k] // 0)), .key)
      | map(.value))' .all-contributorsrc > "$work/rc"
mv "$work/rc" .all-contributorsrc

render_all
changed=(.all-contributorsrc "${RENDERED[@]}")

if [[ $mode == dry ]]; then
  git --no-pager diff
  exit 0
fi

# Backticks render the handles as code, so nobody gets pinged; the same
# list format is read back above to recognise declined accounts.
handles="$(printf -- '- `%s`\n' "${missing[@]}")"
git switch -q -c "$BRANCH"
git add "${changed[@]}"
git commit -q -m "$TITLE" -m "$handles"
# No open PR uses the branch (checked above), so overwriting it loses
# nothing; a leftover branch from a closed PR is simply replaced.
git push -q --force origin "HEAD:refs/heads/$BRANCH"

pr="$(gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" --title "$TITLE" \
  --body "Credits these accounts for \`code\` in the all-contributors table. They authored a merged PR or appear in the contributors API but had no entry. Found by \`scripts/update-contributors.sh\`, which also re-sorted the list by activity:

$handles

Add other contribution types (bug, userTesting, ideas, ...) on this branch before merging if they apply: edit \`.all-contributorsrc\`, then run \`scripts/update-contributors.sh --render\` to regenerate the table and the README preview. The weekly run leaves an open PR alone. Closing this PR, merged or not, marks every account listed above as handled, and they are not proposed again; keep the list in this description as it is, since that is what the next run reads.")"
echo "$pr"
notify "${#missing[@]} new contributor(s): $pr"
