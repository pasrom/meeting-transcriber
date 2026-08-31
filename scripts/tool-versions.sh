#!/usr/bin/env bash
# Single source of truth for the pinned lint toolchain.
#
# Sourced by scripts/lint.sh (to warn when the local binary disagrees), by
# scripts/ci/install-lint-tool.sh (to install exactly this), and read by
# .github/workflows/lint-tool-updates.yml (to notice when a newer release
# exists). Nothing else should carry a version number for these two tools.
#
# The checksum is the point of the pin, not the version. A release tag can be
# re-pointed and a release asset can be replaced, so a version string alone
# says which URL to fetch, not what came back. Regenerate both together:
#
#   curl -fsSL -o /tmp/t.zip <asset-url> && shasum -a 256 /tmp/t.zip
#
# Bumping is a deliberate act: land the new version, its checksum, and whatever
# the new release wants changed in the same commit.

SWIFTFORMAT_VERSION="0.63.0"
SWIFTFORMAT_SHA256="28c7802e11fa5ae113d903066439c6bb1be20a8ac1ad9709c42616a7e273fb0f"
SWIFTFORMAT_REPO="nicklockwood/SwiftFormat"
SWIFTFORMAT_ASSET="swiftformat.zip"

SWIFTLINT_VERSION="0.65.1"
SWIFTLINT_SHA256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"
SWIFTLINT_REPO="realm/SwiftLint"
SWIFTLINT_ASSET="portable_swiftlint.zip"
