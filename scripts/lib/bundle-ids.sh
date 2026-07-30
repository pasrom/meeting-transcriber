#!/usr/bin/env bash
# Single source of truth for the app's bundle identifiers.
#
# Read out of Info.plist rather than restated, because a second copy of an
# identifier has no way to notice when the first one changes — and every way it
# then fails is silent:
#   * `defaults write <old-id>` still succeeds, into a domain nothing reads, so
#     an e2e lane's toggles never take and the run fails as an opaque timeout;
#   * the signing helper finds no `signing/<new-id>.provisionprofile`, takes its
#     no-profile path, and ships a build without its restricted entitlement
#     while reporting success.
# PlistBuddy exits non-zero on a missing key, so with `set -e` a drifted or
# renamed key is loud instead.
#
# Source this, don't execute it.

_BUNDLE_IDS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RELEASE_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$_BUNDLE_IDS_ROOT/app/MeetingTranscriber/Sources/Info.plist")"

# The dev build carries its own identity so it never shares TCC grants,
# settings or a notification registration with an installed release. Derived
# from the release identifier so the two can only ever move together.
DEV_BUNDLE_ID="$RELEASE_BUNDLE_ID.dev"

# `defaults write <id>` from outside a running app can be redirected into the
# app's container, so callers that read a dev default back have to check both
# locations. One definition of where that container plist lives.
dev_container_plist() {
    local bundle_id="${1:-$DEV_BUNDLE_ID}"
    printf '%s' "$HOME/Library/Containers/$bundle_id/Data/Library/Preferences/$bundle_id.plist"
}
