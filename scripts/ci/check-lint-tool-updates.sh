#!/usr/bin/env bash
# Compare the pinned lint tools against their latest upstream release and open
# an issue when one falls behind.
#
# Why this exists: pinning removes the surprise-red, but it also removes the
# only thing that ever moved the version. The formatter pin proved that by
# sitting at a release nobody ran any more until it caused the exact breakage
# it was meant to prevent. Dependabot cannot help here - it understands package
# manifests, and these versions live in a shell file - so the nudge is this.
#
# Deliberately opens an issue rather than a PR: bumping is not mechanical. A new
# release can turn on default rules, which is a judgement call about the
# codebase, not a version string swap.
#
# Usage:
#   bash scripts/ci/check-lint-tool-updates.sh
#   bash scripts/ci/check-lint-tool-updates.sh --dry-run   # print, touch nothing

set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck source=scripts/tool-versions.sh
source scripts/tool-versions.sh

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Explicit target repo: `gh` otherwise infers it from the git remote, which
# fails the moment this runs anywhere but inside a checkout. CI always sets it.
#
# Expanded as `${repo_args[@]+...}` at both use sites, not plain `${repo_args[@]}`:
# under `set -u` bash 3.2 treats an empty array as unset and aborts, and 3.2 is
# what macOS still ships as /bin/bash. CI runs bash 5, so the naive form would
# have worked there and broken only the documented local --dry-run.
repo_args=()
[[ -n "${GITHUB_REPOSITORY:-}" ]] && repo_args=(--repo "$GITHUB_REPOSITORY")

check_tool() {
    local name="$1" repo="$2" pinned="$3"

    local latest
    latest="$(gh api "repos/${repo}/releases/latest" --jq '.tag_name')"
    latest="${latest#v}"

    if [[ "$latest" == "$pinned" ]]; then
        echo "$name: pinned $pinned is current"
        return 0
    fi

    echo "$name: pinned $pinned, latest $latest"

    # Fixed title so the dedup key survives further releases: the issue is
    # "this pin is behind", not "this pin is behind that specific version".
    local title="Lint tool pin behind upstream: $name"
    local existing
    existing="$(gh issue list ${repo_args[@]+"${repo_args[@]}"} --state open --limit 100 --json number,title \
        --jq ".[] | select(.title == \"$title\") | .number" | head -1)"
    if [[ -n "$existing" ]]; then
        echo "$name: issue #$existing is already open, leaving it alone"
        return 0
    fi

    local body
    body="$(cat <<EOF
\`$name\` is pinned to **$pinned**; the latest release is **$latest**.

To bump, in one commit:

1. Edit \`scripts/tool-versions.sh\`: set the version and the new checksum.
   \`\`\`
   curl -fsSL -o /tmp/t.zip https://github.com/${repo}/releases/download/${latest}/<asset> && shasum -a 256 /tmp/t.zip
   \`\`\`
   The asset name for this tool is in the same file.
2. Run \`./scripts/lint.sh\` with the new version installed locally and fix, or
   deliberately disable, whatever the release changed. A new default rule is a
   judgement call about this codebase, which is why this is an issue and not an
   automatic pull request.
3. Land the version, the checksum and any resulting changes together.

Opened automatically by \`.github/workflows/lint-tool-updates.yml\`. Closing it
without bumping is a fine answer; it will reopen when the next release lands.
EOF
)"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "--- would open issue: $title"
        echo "$body"
        return 0
    fi

    gh issue create ${repo_args[@]+"${repo_args[@]}"} --title "$title" --body "$body"
}

check_tool SwiftFormat "$SWIFTFORMAT_REPO" "$SWIFTFORMAT_VERSION"
check_tool SwiftLint "$SWIFTLINT_REPO" "$SWIFTLINT_VERSION"
