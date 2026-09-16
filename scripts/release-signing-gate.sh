#!/usr/bin/env bash
# The release lane's signing gate: refuse to publish an artifact nobody can
# install, and say which build mode the workflow should use.
#
# Background. On a `v*` tag the homebrew DMG becomes the GitHub Release asset
# and its SHA-256 is written into the Homebrew cask. The workflow used to pick
# between the signed and the unsigned build path with an inline
# `[ -n "$DEVELOPER_ID" ]`, so a tag built with that secret missing fell
# through to `build_release.sh --no-notarize`, which ad-hoc signs and still
# produces a DMG. Nothing downstream looked at the signature, so the release
# published cleanly and only a user trying to open it would find out.
#
# Two subcommands, because a precondition and a postcondition fail differently:
#
#   preflight <git-ref> <variant>   before the build, reads DEVELOPER_ID from
#                                   the environment. Prints the build mode
#                                   (`developer-id` or `adhoc`) on stdout, or
#                                   refuses. Printing the mode is the point:
#                                   with the answer coming from here the
#                                   workflow has no second place to decide it
#                                   from, which is what let the old branch
#                                   route around every check.
#
#   verify <app-bundle>             after the build, on the artifact that is
#                                   about to be published. This is the half
#                                   that cannot be routed around, because it
#                                   asks the built thing rather than the inputs.
#
# Deliberately NOT `codesign --verify`: measured, it exits 0 on an ad-hoc
# signed bundle. See signing_authority_verdict in scripts/lib/signing.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/signing.sh
source "$SCRIPT_DIR/lib/signing.sh"

usage() {
    echo "usage: $(basename "$0") preflight <git-ref> <variant>" >&2
    echo "       $(basename "$0") verify <app-bundle>" >&2
    exit 2
}

cmd_preflight() {
    local ref="${1:-}" variant="${2:-}"
    [ -n "$ref" ] && [ -n "$variant" ] || usage

    if [ "$(release_is_published_build "$ref" "$variant")" = yes ]; then
        # Every missing input is reported in one run. A fresh or restored setup
        # should learn everything it has to fix from a single failure, rather
        # than discovering the second secret only after fixing the first.
        local missing=0
        if [ -z "${DEVELOPER_ID:-}" ]; then
            missing=1
            echo "::error::DEVELOPER_ID is not set, and $ref is a release tag." >&2
            echo "  Without it this build would ad-hoc sign the app and still produce a DMG," >&2
            echo "  which would be attached to the release and hashed into the Homebrew cask." >&2
            echo "  Gatekeeper refuses an ad-hoc signed download, so the release would be" >&2
            echo "  uninstallable for everyone while every job in this run reported success." >&2
        fi
        if [ -z "${RELEASE_PROVISIONING_PROFILE:-}" ]; then
            missing=1
            echo "::error::RELEASE_PROVISIONING_PROFILE is not set, and $ref is a release tag." >&2
            echo "  The profile is what authorises the time-sensitive notification entitlement," >&2
            echo "  and codesign silently drops any entitlement no embedded profile grants." >&2
            echo "  The release would install and run, and then, for every user with Focus on," >&2
            echo "  the browser-meeting consent prompt would never break through: it times out," >&2
            echo "  that counts as a decline, and no browser meeting is ever recorded while the" >&2
            echo "  setting still reads as enabled. The capture-channel-lost alert goes the same way." >&2
        fi
        if [ "$missing" -ne 0 ]; then
            echo "  Fix: make the named secrets available to this workflow, then re-run." >&2
            return 1
        fi
        printf 'developer-id\n'
        return 0
    fi

    # Not a published build: a branch push, a pull request or a manual run.
    # These have no access to the secrets and are attached to nothing, so a
    # build is the useful outcome rather than a failure. A certificate is still
    # used when one happens to be available.
    if [ -n "${DEVELOPER_ID:-}" ]; then
        printf 'developer-id\n'
    else
        printf 'adhoc\n'
    fi
}

cmd_verify() {
    local bundle="${1:-}"
    [ -n "$bundle" ] || usage

    local output verdict
    # `|| true` because codesign exits non-zero on an unsigned bundle, and that
    # is an answer this function reports rather than a failure to obtain one.
    output="$(codesign -dvvv "$bundle" 2>&1 || true)"
    verdict="$(signing_authority_verdict "$output")"

    case "$verdict" in
        developer-id)
            # Said out loud. A check that passes silently is indistinguishable
            # in a log from a check that never ran.
            local authority
            authority="$(printf '%s\n' "$output" | grep -m1 '^Authority=' || true)"
            echo "Release signature accepted: ${authority#Authority=}"
            return 0 ;;
        adhoc)
            echo "::error::$bundle is ad-hoc signed and must not be published." >&2
            echo "  Gatekeeper refuses an ad-hoc signed download, so this artifact would be" >&2
            echo "  uninstallable. It means the build took the unsigned path: check that" >&2
            echo "  DEVELOPER_ID reached the build step." >&2
            return 1 ;;
        other)
            local authority
            authority="$(printf '%s\n' "$output" | grep -m1 '^Authority=' || true)"
            echo "::error::$bundle is signed by ${authority#Authority=}, which is not a Developer ID." >&2
            echo "  Only a 'Developer ID Application' certificate is accepted by Gatekeeper" >&2
            echo "  for a download. A development certificate works on the machine that" >&2
            echo "  holds it and nowhere else." >&2
            return 1 ;;
        *)
            echo "::error::$bundle carries no signature at all." >&2
            echo "  codesign reported:" >&2
            printf '%s\n' "$output" | sed 's|^|    |' >&2
            return 1 ;;
    esac
}

case "${1:-}" in
    preflight) shift; cmd_preflight "$@" ;;
    verify)    shift; cmd_verify "$@" ;;
    *) usage ;;
esac
