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

# The dev bundle every e2e lane deploys is the Homebrew variant, so
# resign_deployed_bundle resolves its base entitlements here rather than having
# four lanes each spell the same path — one more place for them to drift apart.
DEV_ENTITLEMENTS="${DEV_ENTITLEMENTS:-$_SIGNING_LIB_ROOT/app/MeetingTranscriber/Entitlements/Homebrew.entitlements}"

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

# bundle_signing_cert_sha1 <app-bundle>
#
# SHA-1 of the leaf certificate the bundle is signed with, empty when it is
# unsigned or ad-hoc signed. The hash and not the certificate's name, because
# the hash is what TCC keys a grant on and two certificates share a name across
# a renewal — a name comparison would call those two the same certificate.
bundle_signing_cert_sha1() {
    local bundle="$1" dir hash=""
    # Absolute, because the subshell below changes directory: a relative path
    # would resolve against the temp dir, yield no certificate, and read as
    # "unsigned" — which sends the caller down the destructive branch.
    case "$bundle" in /*) ;; *) bundle="$PWD/$bundle" ;; esac
    dir="$(mktemp -d)"
    # --extract-certificates writes codesign0, codesign1, … into the CURRENT
    # directory, hence the subshell cd. codesign0 is the leaf.
    ( cd "$dir" && codesign -d --extract-certificates "$bundle" >/dev/null 2>&1 ) || true
    if [ -f "$dir/codesign0" ]; then
        # `|| true`: an unsigned or odd bundle is a normal answer (empty), not a
        # failure. Under the callers' `pipefail` a non-zero pipeline here would
        # become the function's status and abort their `hash="$(…)"` assignment
        # with no output at all — the same trap documented at profile_for.
        hash="$(openssl x509 -inform DER -in "$dir/codesign0" -noout -fingerprint -sha1 2>/dev/null \
            | sed 's/^.*=//' | tr -d ':' | tr '[:lower:]' '[:upper:]' || true)"
    fi
    rm -rf "$dir"
    printf '%s' "$hash"
}

# identity_sha1 <identity> [keychain]
#
# The same hash for an identity held as either a 40-hex SHA-1 (what the lanes
# compute from the runner's self-signed certificate) or a name (what the
# DEVELOPER_ID secret carries). Empty when a name resolves to nothing, or to more
# than one certificate.
#
# The name is matched as a SUBSTRING, because that is how codesign resolves
# `--sign <name>`: per its man page it takes the certificate whose subject common
# name *contains* the string. Anchoring on the fully quoted name that
# `find-identity` prints would reject identities codesign accepts — and since an
# unresolved identity can never match the bundle, the caller would then always
# take the destructive branch.
identity_sha1() {
    local identity="$1" keychain="${2:-}"
    if [[ $identity =~ ^[0-9A-Fa-f]{40}$ ]]; then
        printf '%s' "$identity" | tr '[:lower:]' '[:upper:]'
        return 0
    fi
    local args=(-v -p codesigning) matches count
    [ -n "$keychain" ] && args+=("$keychain")
    # `|| true` because a keychain that cannot be read is a normal answer (empty),
    # not a failure — without it, `pipefail` would make this the function's status
    # and abort the caller's `want="$(…)"` assignment with no output at all, the
    # trap documented at profile_for.
    matches="$(security find-identity "${args[@]}" 2>/dev/null \
        | awk -v name="$identity" 'index($0, name) { print toupper($2) }' \
        | sort -u || true)"
    count="$(printf '%s' "$matches" | grep -c . || true)"
    # Ambiguous is not a match. Guessing between two certificates that both
    # contain the name could skip a re-sign the bundle needed; re-signing when it
    # was unnecessary only costs a signature.
    [ "$count" = 1 ] && printf '%s' "$matches"
    return 0
}

# resign_deployed_bundle <app-bundle> <identity> [keychain]
#
# Re-sign a bundle that was built and deployed elsewhere, with a stable identity
# so TCC keeps its grants across rebuilds, WITHOUT discarding what the build
# signed into it (issue #609). Two measured facts make that more than a codesign
# call:
#
#   - `codesign --force --sign X "$bundle"` with no `--entitlements` writes a
#     signature carrying NO entitlements at all. That is how the e2e lanes used
#     to drop the microphone entitlement and — where a profile had authorised it
#     — the time-sensitive one, one step after the build verified it survived.
#   - The key cannot simply be re-requested here, because a profile authorises
#     specific CERTIFICATES and macOS refuses to launch a bundle whose restricted
#     entitlement no embedded profile covers (see this file's header).
#
# So a bundle whose VALID signature is already by the requested certificate is
# left alone — re-signing it could only subtract — and otherwise the bundle is
# re-signed with the base entitlements, dropping a profile the new signature
# cannot honour. That last part matters: a profile left embedded next to a missing
# key is what makes e2e-browser.sh's pairing check fail while pointing at
# prepare_signing, which did its job correctly.
#
# Validity is part of the question, not a detail: test_rpc.sh copies a fresh
# binary into an already-signed bundle, so the certificate still matches while the
# signature no longer does. Keeping that signature would launch a bundle macOS
# refuses to run.
#
# The keychain is a parameter rather than pass-through codesign flags, so no
# caller has to expand a possibly-empty array under `set -u`.
resign_deployed_bundle() {
    local bundle="$1" identity="$2" keychain="${3:-}"

    local want have=""
    want="$(identity_sha1 "$identity" "$keychain")"
    # Only worth asking the bundle when the identity resolved: one that did not
    # can never claim a match.
    if [ -n "$want" ]; then
        have="$(bundle_signing_cert_sha1 "$bundle")"
    fi

    if [ "$want" = "$have" ] && [ -n "$have" ] && codesign --verify "$bundle" 2>/dev/null; then
        echo "  Already signed by the requested certificate — keeping that signature;"
        echo "  re-signing would only drop the entitlements it carries."
    else
        # Checked before the bundle is touched, so a bad path cannot leave a
        # half-changed bundle behind. Without it the path surfaces as codesign's
        # "cannot read entitlement data", which reads like a malformed plist.
        [ -f "$DEV_ENTITLEMENTS" ] \
            || { echo "  ERROR: entitlements not found: $DEV_ENTITLEMENTS" >&2; return 1; }

        # The profile is SET ASIDE rather than deleted, and put back if signing
        # fails. It is sealed in _CodeSignature/CodeResources, so a bundle missing
        # it fails `codesign --verify` even though nothing else changed: deleting
        # first would turn a failed re-sign — a locked keychain, an identity the
        # parallel runner's search-list churn hid — into an unlaunchable bundle at
        # the shared, TCC-granted deploy path. The bare re-sign this replaced was
        # at least all-or-nothing.
        local profile="$bundle/Contents/embedded.provisionprofile" stash=""
        if [ -f "$profile" ]; then
            stash="$(mktemp -d)/embedded.provisionprofile"
            mv "$profile" "$stash" \
                || { echo "  ERROR: could not set the embedded profile aside" >&2; return 1; }
            echo "  Setting the embedded provisioning profile aside: '$identity' is not"
            echo "  the certificate it authorises, so $TIME_SENSITIVE_KEY cannot come along."
            echo "  (Point DEVELOPER_ID at the profile's certificate to keep the built signature.)"
            echo "  WARNING: with no profile embedded, e2e-browser.sh can only SKIP its"
            echo "  check that the consent prompt breaks through Focus (issue #543)."
        fi

        local args=(--force --sign "$identity" --entitlements "$DEV_ENTITLEMENTS")
        [ -n "$keychain" ] && args+=(--keychain "$keychain")
        if ! codesign "${args[@]}" "$bundle" >/dev/null; then
            [ -n "$stash" ] && mv "$stash" "$profile"
            return 1
        fi

        # verify_signing speaks only about the profile pairing, and on this path
        # there is no profile left to pair with — so check the thing this function
        # exists for. A signature with no entitlements at all is issue #609 itself.
        codesign -d --entitlements :- "$bundle" 2>/dev/null | grep -q '<key>' \
            || { echo "  ERROR: the new signature carries no entitlements (issue #609)" >&2; return 1; }
    fi
    verify_signing "$bundle"
}
