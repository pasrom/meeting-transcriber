#!/usr/bin/env bash
# Install a pinned lint tool on a GitHub Actions runner, or verify that the
# pinned one is what PATH resolves to.
#
# Why pin at all: `brew install` takes whatever is current that day, so a tool
# release with a new or stricter default rule turns an unrelated PR red, at a
# moment nobody chose and with a diff that explains nothing.
#
# Why a checksum and not just a version: a release tag can be re-pointed and a
# release asset can be replaced, so the version alone pins the URL rather than
# the bytes. The runner executes what comes back, so the bytes are the thing to
# pin. Versions and checksums live in scripts/tool-versions.sh.
#
# Usage (two steps, because $GITHUB_PATH only affects *later* steps):
#   bash scripts/ci/install-lint-tool.sh swiftlint            # fetch + PATH
#   bash scripts/ci/install-lint-tool.sh swiftlint --verify   # assert PATH
#
# .github/workflows/lint-tool-updates.yml watches for newer releases, so the
# pin gets a nudge instead of quietly ageing.

set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck source=scripts/tool-versions.sh
source scripts/tool-versions.sh

tool="${1:-}"
case "$tool" in
    swiftformat)
        version="$SWIFTFORMAT_VERSION"
        sha256="$SWIFTFORMAT_SHA256"
        repo="$SWIFTFORMAT_REPO"
        asset="$SWIFTFORMAT_ASSET"
        # `swiftformat --version` prints the bare number; `swiftlint version`
        # does too, but the subcommand spelling differs between the two.
        version_argv=(--version)
        ;;
    swiftlint)
        version="$SWIFTLINT_VERSION"
        sha256="$SWIFTLINT_SHA256"
        repo="$SWIFTLINT_REPO"
        asset="$SWIFTLINT_ASSET"
        version_argv=(version)
        ;;
    *)
        echo "usage: $0 <swiftformat|swiftlint> [--verify]" >&2
        exit 2
        ;;
esac

if [[ "${2:-}" == "--verify" ]]; then
    got="$("$tool" "${version_argv[@]}")"
    echo "$tool resolves to: $(command -v "$tool") ($got)"
    if [[ "$got" != "$version" ]]; then
        echo "::error::Expected pinned $tool $version but got $got (shadowed by a pre-installed binary)."
        exit 1
    fi
    exit 0
fi

: "${RUNNER_TEMP:?RUNNER_TEMP is unset - this script is meant for CI runners}"
: "${GITHUB_PATH:?GITHUB_PATH is unset - this script is meant for CI runners}"

bin_dir="$RUNNER_TEMP/$tool-bin"
archive="$RUNNER_TEMP/$tool.zip"
curl -fsSL -o "$archive" "https://github.com/${repo}/releases/download/${version}/${asset}"

echo "$sha256  $archive" | shasum -a 256 -c - || {
    echo "::error::Checksum mismatch for $tool $version. Expected $sha256, got $(shasum -a 256 "$archive" | cut -d' ' -f1)."
    exit 1
}

unzip -o -j "$archive" -d "$bin_dir"
chmod +x "$bin_dir/$tool"
xattr -dr com.apple.quarantine "$bin_dir/$tool" || true

# Prepend: the runner image ships both tools on the Homebrew path, which
# precedes /usr/local/bin, so anything less than a PATH entry gets shadowed.
echo "$bin_dir" >> "$GITHUB_PATH"
echo "installed pinned $tool $version at $bin_dir"
