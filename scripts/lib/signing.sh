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
    plutil -insert "$TIME_SENSITIVE_KEY" -bool true "$derived" >/dev/null
    echo "  Added $TIME_SENSITIVE_KEY" >&2
    printf '%s' "$derived"
}
