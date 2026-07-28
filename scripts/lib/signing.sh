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

# signing_identity_for <bundle-id> <fallback-identity>
#
# A profile authorises specific CERTIFICATES. Signing with one it does not list
# makes macOS reject the launch outright once the entitlement is really present
# ("Launchd job spawn failed" — measured). Developer ID distribution profiles
# list the Developer ID Application certificate, so when a profile applies, that
# is the identity to use rather than whatever `security find-identity` returns
# first.
#
# A separate function rather than a variable set inside prepare_signing: that one
# runs in a command substitution, so anything it assigns dies with the subshell.
signing_identity_for() {
    local bundle_id="$1" fallback="$2"
    if [ -z "$(profile_for "$bundle_id")" ]; then
        printf '%s' "$fallback"
        return 0
    fi
    local devid
    devid="$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 | awk '{print $2}')"
    if [ -n "$devid" ]; then
        printf '%s' "$devid"
    else
        echo "  WARNING: a profile applies but no Developer ID Application certificate was found;" >&2
        echo "  the signature will not be covered by it and the app may refuse to launch." >&2
        printf '%s' "$fallback"
    fi
}

TIME_SENSITIVE_KEY="com.apple.developer.usernotifications.time-sensitive"

# profile_for <bundle-id> → path, or empty when none is available.
profile_for() {
    local bundle_id="$1"
    local candidate="$PROFILE_DIR/${bundle_id}.provisionprofile"
    [ -f "$candidate" ] && printf '%s' "$candidate"
}

# prepare_signing <app-bundle> <base-entitlements> <bundle-id>
#
# Embeds the matching profile when there is one and prints the entitlements path
# to sign with: either a temporary copy carrying the time-sensitive key, or the
# base file unchanged. Always prints exactly one path on stdout; progress goes to
# stderr so the caller can capture the path.
prepare_signing() {
    local bundle="$1" base_entitlements="$2" bundle_id="$3"
    local profile
    profile="$(profile_for "$bundle_id")"

    if [ -z "$profile" ]; then
        # Drop a profile left behind by an earlier build: the bundle is
        # reassembled in place, so a stale embedded.provisionprofile would make
        # this build look provisioned when it is not, and would make
        # verify_signing warn about a profile nobody asked for.
        rm -f "$bundle/Contents/embedded.provisionprofile"
        echo "  No provisioning profile for $bundle_id — signing without $TIME_SENSITIVE_KEY." >&2
        echo "  (The consent prompt will not break through Focus in this build; see issue #543.)" >&2
        printf '%s' "$base_entitlements"
        return 0
    fi

    cp "$profile" "$bundle/Contents/embedded.provisionprofile"
    echo "  Embedded provisioning profile for $bundle_id" >&2


    # Derive the entitlements rather than keeping a second near-duplicate file,
    # so the base list stays the single source of truth.
    local derived
    derived="$(mktemp -t entitlements).plist"
    cp "$base_entitlements" "$derived"
    # plutil reads dots in a key as KEY PATH separators, so the literal key has
    # to arrive escaped or the insert silently fails and the build reports a key
    # it never added.
    plutil -insert "${TIME_SENSITIVE_KEY//./\\.}" -bool true "$derived" \
        || { echo "  ERROR: could not add $TIME_SENSITIVE_KEY to the entitlements" >&2; return 1; }
    echo "  Requesting $TIME_SENSITIVE_KEY" >&2
    printf '%s' "$derived"
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

    if codesign -d --entitlements :- "$bundle" 2>/dev/null | grep -q "$TIME_SENSITIVE_KEY"; then
        echo "  Verified $TIME_SENSITIVE_KEY survived signing" >&2
        return 0
    fi

    echo "  WARNING: the profile is embedded but codesign dropped $TIME_SENSITIVE_KEY." >&2
    echo "  The profile does not grant it — enable the Time Sensitive Notifications" >&2
    echo "  capability on this App ID and re-issue the profile. Until then the" >&2
    echo "  consent prompt cannot break through Focus (issue #543)." >&2
    return 0
}
