#!/usr/bin/env bash
# Shared signing helper: embed a provisioning profile and, only then, add the
# entitlements that profile authorises.
#
# Why this exists (issue #543): the browser-meeting consent prompt asks a
# question that expires. At the default interruption level macOS renders it as a
# banner, which any Focus mode suppresses outright, so the question is never seen
# and browser meetings silently never record. `.timeSensitive` is the only level
# that breaks through Focus, and it requires
# `com.apple.developer.usernotifications.time-sensitive`.
#
# That entitlement is RESTRICTED. Measured, not assumed: signing a bundle with it
# but no provisioning profile makes macOS refuse to launch the app outright
# ("Launchd job spawn failed", POSIX 163) — with a local Apple Development cert
# AND with Developer ID plus hardened runtime, i.e. exactly how a release is
# signed. Adding the key unconditionally would ship a brick.
#
# So the key is added ONLY when a profile that authorises it is present, and the
# no-profile path is byte-identical to the previous behaviour. Contributors and
# CI without profiles keep building working apps; the prompt just stays at the
# old interruption level for them.
#
# Profiles are Developer ID distribution profiles from the Apple Developer
# portal, one per bundle id. They are gitignored: they are account artifacts, and
# the same reasoning that keeps the signing certificate out of the repo applies.
# Point PROFILE_DIR somewhere else if you keep them elsewhere.

# Derived from this file's own location, so it does not depend on which caller
# happens to define TRANSCRIBER_ROOT.
_SIGNING_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="${PROFILE_DIR:-$_SIGNING_LIB_ROOT/signing}"

TIME_SENSITIVE_KEY="com.apple.developer.usernotifications.time-sensitive"

# profile_for <bundle-id> → path, or empty when none is available.
#
# "No profile" is a normal outcome, not a failure, so this must return 0 either
# way: an `&&`-terminated body would hand back the failed test's status, and a
# caller's `profile="$(profile_for "$id")"` under `set -e` would then abort the
# whole build with no output at all. Every machine without the account's
# profiles takes this path.
profile_for() {
    local bundle_id="$1"
    local candidate="$PROFILE_DIR/${bundle_id}.provisionprofile"
    if [ -f "$candidate" ]; then
        printf '%s' "$candidate"
    fi
}

# prepare_signing <app-bundle> <base-entitlements> <bundle-id> [fallback-identity]
#
# Embeds the matching profile when there is one, then sets two globals for the
# caller to sign with:
#   SIGNING_ENTITLEMENTS — the base file, or a derived copy carrying the
#                          time-sensitive key when a profile authorises it
#   SIGNING_IDENTITY     — the identity that profile covers, else the fallback
#
# Globals rather than stdout: this function MUTATES the bundle (it copies the
# profile in, or removes a stale one), and a `$( )` call site would hide that
# side effect inside a subshell — plus returning two values through stdout is
# what previously forced a second function and a second keychain query.
#
# shellcheck disable=SC2034  # SIGNING_ENTITLEMENTS/SIGNING_IDENTITY are read by callers
prepare_signing() {
    local bundle="$1" base_entitlements="$2" bundle_id="$3" fallback="${4:-}"
    local profile
    profile="$(profile_for "$bundle_id")"

    SIGNING_IDENTITY="$fallback"

    if [ -z "$profile" ]; then
        # Drop a profile left behind by an earlier build: the bundle is
        # reassembled in place, so a stale embedded.provisionprofile would make
        # this build look provisioned when it is not, and would make
        # verify_signing warn about a profile nobody asked for.
        rm -f "$bundle/Contents/embedded.provisionprofile"
        echo "  No provisioning profile for $bundle_id — signing without $TIME_SENSITIVE_KEY."
        echo "  (The consent prompt will not break through Focus in this build; see issue #543.)"
        SIGNING_ENTITLEMENTS="$base_entitlements"
        return 0
    fi

    cp "$profile" "$bundle/Contents/embedded.provisionprofile"
    echo "  Embedded provisioning profile for $bundle_id"

    # A profile authorises specific CERTIFICATES. Signing with one it does not
    # list makes macOS reject the launch outright once the entitlement is really
    # present ("Launchd job spawn failed" — measured). Developer ID distribution
    # profiles list the Developer ID Application certificate, so prefer that
    # over whatever `security find-identity` happens to return first.
    local devid
    devid="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 | awk '{print $2}')" || true
    if [ -n "$devid" ]; then
        SIGNING_IDENTITY="$devid"
    else
        echo "  WARNING: a profile applies but no Developer ID Application certificate was found;"
        echo "  the signature will not be covered by it and the app may refuse to launch."
    fi

    # Derive the entitlements rather than keeping a second near-duplicate file,
    # so the base list stays the single source of truth. Written beside the
    # bundle instead of into TMPDIR: it is a build artifact, gets overwritten by
    # the next build, and goes away with the build directory rather than piling
    # up one file per build forever.
    local derived="${bundle%.app}-entitlements.plist"
    cp "$base_entitlements" "$derived"
    # plutil reads dots in a key as KEY PATH separators, so the literal key has
    # to arrive escaped or the insert silently fails and the build reports a key
    # it never added.
    plutil -insert "${TIME_SENSITIVE_KEY//./\\.}" -bool true "$derived" \
        || { echo "  ERROR: could not add $TIME_SENSITIVE_KEY to the entitlements" >&2; return 1; }
    echo "  Requesting $TIME_SENSITIVE_KEY"
    SIGNING_ENTITLEMENTS="$derived"
}

# verify_signing <app-bundle>
#
# Call AFTER codesign. Requesting the entitlement is not the same as getting it:
# when a profile is embedded, codesign validates entitlements against it and
# silently DROPS any the profile does not grant. Measured: with a profile that
# lacks the Time Sensitive Notifications capability, the key vanishes from the
# signature, the build reports success, and the consent prompt stays suppressed
# under Focus with nothing anywhere saying so.
#
# (Without any profile the same key instead makes the app refuse to launch, which
# is why prepare_signing only requests it when a profile is present.)
verify_signing() {
    local bundle="$1"
    [ -f "$bundle/Contents/embedded.provisionprofile" ] || return 0

    if bundle_has_time_sensitive "$bundle"; then
        echo "  Verified $TIME_SENSITIVE_KEY survived signing"
        return 0
    fi

    echo "  WARNING: the profile is embedded but codesign dropped $TIME_SENSITIVE_KEY."
    echo "  The profile does not grant it — enable the Time Sensitive Notifications"
    echo "  capability on this App ID and re-issue the profile. Until then the"
    echo "  consent prompt cannot break through Focus (issue #543)."
    return 0
}

# bundle_has_time_sensitive <app-bundle>
#
# True when the SIGNATURE actually carries the key. Separate from
# verify_signing so a caller that must fail on a missing key (an e2e lane
# asserting the prompt can break through Focus) shares this one definition of
# the check and of the key itself, instead of re-spelling both.
bundle_has_time_sensitive() {
    codesign -d --entitlements :- "$1" 2>/dev/null | grep -q "$TIME_SENSITIVE_KEY"
}
