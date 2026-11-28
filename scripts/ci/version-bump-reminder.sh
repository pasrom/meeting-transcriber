#!/usr/bin/env bash
# Opens an issue asking for the VERSION bump after a stable release shipped.
# Called by the `version-bump-reminder` job in .github/workflows/release.yml.
#
# Usage: version-bump-reminder.sh <tag>        e.g. version-bump-reminder.sh v0.9.0
#
# A release builds with the version taken from its tag, so it succeeds while
# VERSION on main is stale, and builds from source then report the old version
# and offer the release as an update. VERSION is not bumped at tag time on
# purpose: the bump waits until the release is confirmed shipped, and a
# workflow here may not open pull requests, so this files a reminder instead.
#
# "Shipped" is read back rather than inferred from the build result: the
# GitHub Release carries the DMG and the stable Cask in the tap reads the
# version. That keeps a failed App Store leg, which publishes nothing, from
# suppressing the reminder. A re-run files no second issue while the first one
# is open.
#
# Exit codes:
#   0  issue opened, or nothing to do (pre-release tag, VERSION not older,
#      release not shipped, an open issue with the same title already exists)
#   2  the tag or VERSION is not a version this can compare, or a `gh` call
#      failed
#
# Needs GH_TOKEN with issues: write and GH_REPO (owner/name). GITHUB_SERVER_URL
# and GITHUB_RUN_ID only feed the links in the issue body.

set -uo pipefail

TAP_REPO="pasrom/homebrew-meeting-transcriber"
STABLE_CASK="Casks/meeting-transcriber.rb"
RAW="Accept: application/vnd.github.raw"

tag="${1:-}"
repo="${GH_REPO:-}"
if [ -z "$tag" ] || [ -z "$repo" ]; then
    echo "usage: GH_REPO=<owner/name> $(basename "$0") <tag>" >&2
    exit 2
fi

# Only a plain vX.Y.Z tag is a stable release. A pre-release tag never asks
# for a bump.
case "$tag" in v*-*)
    echo "Pre-release tag $tag; no VERSION bump reminder."
    exit 0 ;;
esac
if ! [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "::error::tag '$tag' is not a vX.Y.Z version" >&2
    exit 2
fi
new_version="${tag#v}"
new=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")

if ! main_version="$(gh api -H "$RAW" "repos/$repo/contents/VERSION?ref=main")"; then
    echo "::error::could not read VERSION on main" >&2
    exit 2
fi
main_version="$(tr -d '[:space:]' <<< "$main_version")"
if ! [[ "$main_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "::error::VERSION on main reads '$main_version', which is not an X.Y.Z version" >&2
    exit 2
fi
old=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
old_pre="${BASH_REMATCH[4]}"

# SemVer precedence, field by field as numbers (so 0.10.0 > 0.9.0). With an
# equal core, the stable tag outranks a pre-release VERSION.
newer=0
decided=0
for i in 0 1 2; do
    if [ "$((10#${new[$i]}))" -gt "$((10#${old[$i]}))" ]; then newer=1; decided=1; break; fi
    if [ "$((10#${new[$i]}))" -lt "$((10#${old[$i]}))" ]; then decided=1; break; fi
done
if [ "$decided" = 0 ] && [ -n "$old_pre" ]; then newer=1; fi

if [ "$newer" = 0 ]; then
    echo "VERSION on main reads $main_version, not older than $new_version; no reminder needed."
    exit 0
fi

# A Homebrew leg that failed before publishing leaves no release behind: that
# is "not shipped", and the failed build already says so. Any other error is
# this job's own failure.
dmg="MeetingTranscriber-${new_version}.dmg"
err="$(mktemp)"
if ! assets="$(gh api "repos/$repo/releases/tags/$tag" --jq '.assets[].name' 2> "$err")"; then
    if grep -qF '(HTTP 404)' "$err"; then
        rm -f "$err"
        echo "No GitHub Release for $tag; not shipped, no reminder."
        exit 0
    fi
    cat "$err" >&2
    rm -f "$err"
    echo "::error::could not read the GitHub Release $tag" >&2
    exit 2
fi
rm -f "$err"
if ! grep -qxF "$dmg" <<< "$assets"; then
    echo "Release $tag has no $dmg attached; not shipped, no reminder."
    exit 0
fi

if ! cask="$(gh api -H "$RAW" "repos/$TAP_REPO/contents/$STABLE_CASK")"; then
    echo "::error::could not read $STABLE_CASK from $TAP_REPO" >&2
    exit 2
fi
cask_version="$(sed -n 's/^ *version "\(.*\)"/\1/p' <<< "$cask")"
cask_version="${cask_version%%$'\n'*}"
if [ "$cask_version" != "$new_version" ]; then
    echo "The stable Cask reads '$cask_version', not $new_version; not shipped, no reminder. Re-run this job once the Cask is updated."
    exit 0
fi

title="Bump VERSION to $new_version"

if ! open_titles="$(gh issue list --state open --limit 1000 --json title --jq '.[].title')"; then
    echo "::error::could not list open issues" >&2
    exit 2
fi
if grep -qxF "$title" <<< "$open_titles"; then
    echo "An open issue titled \"$title\" already exists; not opening another."
    exit 0
fi

repo_url="${GITHUB_SERVER_URL:-https://github.com}/$repo"

body="$(cat <<EOF
$tag shipped from the release workflow, and \`VERSION\` on main still reads $main_version. Until it is bumped, local builds and builds from source report $main_version and offer $tag as an update.

Before bumping, check that the release really shipped:

- the GitHub Release $tag is published with its DMG attached: $repo_url/releases/tag/$tag
- the Homebrew Cask shows $new_version: \`brew info --cask pasrom/meeting-transcriber/meeting-transcriber\`

Then make this one commit straight onto main, the only change allowed there without a pull request:

\`\`\`
chore: bump VERSION to $new_version
\`\`\`
EOF
)"
if [ -n "${GITHUB_RUN_ID:-}" ]; then
    body="$body

Release run: $repo_url/actions/runs/$GITHUB_RUN_ID"
fi

if ! gh issue create --title "$title" --body "$body"; then
    echo "::error::could not open the issue \"$title\"" >&2
    exit 2
fi
