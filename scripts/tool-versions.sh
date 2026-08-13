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

SWIFTFORMAT_VERSION="0.62.1"
SWIFTFORMAT_SHA256="7cb1cb1fae04932047c7015441c543848e8e60e1572d808d080e0a1f1661114a"
SWIFTFORMAT_REPO="nicklockwood/SwiftFormat"
SWIFTFORMAT_ASSET="swiftformat.zip"

SWIFTLINT_VERSION="0.65.0"
SWIFTLINT_SHA256="d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6"
SWIFTLINT_REPO="realm/SwiftLint"
SWIFTLINT_ASSET="portable_swiftlint.zip"
