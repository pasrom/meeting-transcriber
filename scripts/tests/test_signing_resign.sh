#!/usr/bin/env bash
# Regression test for the deployed-bundle re-sign in scripts/lib/signing.sh.
#
# Bug history (issue #609):
#   Every e2e lane deploys the dev bundle to a stable path and re-signs it with a
#   stable identity, so TCC keeps its grants across rebuilds. That re-sign was a
#   bare `codesign --force --sign X "$bundle"`, and a signature written that way
#   carries NO entitlements at all — which is why the build's own "Verified
#   com.apple.developer.usernotifications.time-sensitive survived signing" line
#   was printed one step before the key was thrown away again. The microphone
#   entitlement went with it.
#
#   It also left the bundle INCOHERENT: the embedded provisioning profile
#   survived (rsync copies it in) while the entitlement it authorises did not,
#   which is the exact pairing scripts/e2e-browser.sh asserts — so the lane
#   failed pointing at prepare_signing, which had done its job correctly.
#
# Real codesign wherever the assertion is about a real signature (ad-hoc signing
# needs no certificate, so this runs on a contributor's machine too); a
# PATH-stubbed codesign only for the case that needs a bundle signed by a
# certificate nobody can be assumed to hold.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIC_KEY="com.apple.security.device.audio-input"
# Spelled out rather than sourced from signing.sh on purpose: this pins the key
# macOS actually wants, so a typo in the library's constant fails here.
TS_KEY="com.apple.developer.usernotifications.time-sensitive"

FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$2"; then
        printf 'PASS\n'
    else
        printf 'FAIL\n'
        FAILED=1
    fi
}

# Builds a signable throwaway .app plus a base entitlements file in $1, and
# echoes the bundle path. codesign needs an Info.plist naming a real executable,
# nothing more.
_make_bundle() {
    local workdir="$1" bundle="$1/Some.app"
    mkdir -p "$bundle/Contents/MacOS"
    cp /bin/echo "$bundle/Contents/MacOS/Some"
    cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>Some</string>
    <key>CFBundleIdentifier</key><string>com.example.resign-test</string>
    <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    cat > "$workdir/base.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>$MIC_KEY</key><true/></dict></plist>
PLIST
    printf '%s' "$bundle"
}

# A codesign stand-in for the cases that need a bundle signed by a certificate
# nobody can be assumed to hold. It reports $STUB_LEAF_DER as the bundle's leaf,
# reports $STUB_ENTITLEMENT as its entitlements, fails `--verify` when
# $STUB_VERIFY is `fail`, and records every invocation so "did not rewrite the
# signature" becomes an assertion rather than an inference.
_write_codesign_stub() {
    local workdir="$1"
    mkdir -p "$workdir/bin"
    cat > "$workdir/bin/codesign" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CODESIGN_CALLS"
case "$*" in
    *--verify*)                 [ "${STUB_VERIFY:-ok}" = fail ] && exit 1 ;;
    *--extract-certificates*)   cp "$STUB_LEAF_DER" ./codesign0 ;;
    *"--entitlements :-"*)
        printf '<plist version="1.0"><dict><key>%s</key><true/></dict></plist>' \
            "$STUB_ENTITLEMENT" ;;
esac
exit 0
STUB
    chmod +x "$workdir/bin/codesign"
}

# A real certificate whose SHA-1 the library will compute from the stub's DER.
# It never signs anything; it only has to be extractable and hashable.
# Returns non-zero when the fixture could not be built, because an empty hash
# silently reroutes the cases that use it: they would take the re-sign branch and
# report PASS while the branch they exist to pin never ran, and the sibling case
# would fail accusing working production code.
_make_leaf_cert() {
    local workdir="$1" hash
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$workdir/key.pem" -outform DER -out "$workdir/leaf.der" \
        -days 1 -subj "/CN=Resign Test" 2>/dev/null || return 1
    hash="$(openssl x509 -inform DER -in "$workdir/leaf.der" -noout -fingerprint -sha1 2>/dev/null \
        | sed 's/^.*=//' | tr -d ':')"
    [ -n "$hash" ] || return 1
    printf '%s' "$hash"
}

# Runs the function under test the way a lane does: `set -euo pipefail`, library
# sourced, entitlements pointed at the fixture. Echoes nothing, returns its status.
#
# A separate bash PROCESS, not a subshell: run_test calls each test from an `if`
# condition, and bash suppresses errexit for the whole dynamic extent of a tested
# command — nested subshells included. A subshell here would quietly run without
# `set -e` no matter how it was set, so a test could never observe an abort.
_resign() {
    local workdir="$1"
    shift
    DEV_ENTITLEMENTS="$workdir/base.entitlements" \
    SIGNING_LIB="$REPO_ROOT/scripts/lib/signing.sh" \
        bash -c 'set -euo pipefail
                 # shellcheck source=../lib/signing.sh
                 source "$SIGNING_LIB"
                 resign_deployed_bundle "$@"' bash "$@" >/dev/null 2>&1
}

# Each test has one exit point, so the temp dir is removed exactly once and the
# assertions can still look at the bundle: a RETURN trap would outlive the
# function that set it and fire again inside run_test.
#
# Named for what it can actually falsify: the re-sign branch WRITES the base
# entitlements where the old bare codesign wrote none. It cannot show that
# anything was "kept" — the keys come from $DEV_ENTITLEMENTS, not from the
# bundle's prior signature. Keeping is the skip branch's job, and the case below
# pins that by asserting the signature was not rewritten at all.
test_resign_keeps_the_entitlements() {
    local workdir bundle status entitlements rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"

    # Stand in for what a lane finds on disk: a deployed copy of a build that
    # was signed with the base entitlements.
    codesign --force --sign - --entitlements "$workdir/base.entitlements" "$bundle" 2>/dev/null

    _resign "$workdir" "$bundle" "-"
    status=$?
    entitlements="$(codesign -d --entitlements :- "$bundle" 2>/dev/null)"

    if [ "$status" -ne 0 ]; then
        echo "  resign_deployed_bundle exited $status" >&2
        rc=1
    fi
    case "$entitlements" in
        *"$MIC_KEY"*) ;;
        *)
            echo "  the re-signed bundle lost $MIC_KEY (dump: ${entitlements:-<empty>})" >&2
            rc=1
            ;;
    esac
    rm -rf "$workdir"
    return "$rc"
}

test_resign_keeps_a_signature_by_the_same_certificate() {
    local workdir bundle status hash rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    # A profile is embedded, as it would be after rsync from a provisioned build.
    printf 'stand-in for a provisioning profile' \
        > "$bundle/Contents/embedded.provisionprofile"

    hash="$(_make_leaf_cert "$workdir")" || {
        echo "  fixture failed: could not create a test certificate" >&2
        rm -rf "$workdir"; return 1
    }
    _write_codesign_stub "$workdir"

    (
        export CODESIGN_CALLS="$workdir/calls.log" \
               STUB_LEAF_DER="$workdir/leaf.der" \
               STUB_ENTITLEMENT="$TS_KEY" \
               PATH="$workdir/bin:$PATH"
        _resign "$workdir" "$bundle" "$hash"
    )
    status=$?

    if [ "$status" -ne 0 ]; then
        echo "  resign_deployed_bundle exited $status" >&2
        rc=1
    fi
    if grep -q -- '--force' "$workdir/calls.log" 2>/dev/null; then
        echo "  re-signed a bundle already signed by that certificate — a rewrite" >&2
        echo "  can only drop the entitlements the embedded profile authorises" >&2
        rc=1
    fi
    if [ ! -f "$bundle/Contents/embedded.provisionprofile" ]; then
        echo "  removed the provisioning profile although the signature was kept" >&2
        rc=1
    fi
    rm -rf "$workdir"
    return "$rc"
}

# scripts/test_rpc.sh copies a fresh binary into an already-signed bundle, so the
# certificate still matches while the signature no longer does. Keeping it would
# launch a bundle macOS refuses to run, so validity is part of the skip question.
test_resign_replaces_a_stale_signature_by_the_same_certificate() {
    local workdir bundle status hash rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    hash="$(_make_leaf_cert "$workdir")" || {
        echo "  fixture failed: could not create a test certificate" >&2
        rm -rf "$workdir"; return 1
    }
    _write_codesign_stub "$workdir"

    (
        export CODESIGN_CALLS="$workdir/calls.log" \
               STUB_LEAF_DER="$workdir/leaf.der" \
               STUB_ENTITLEMENT="$TS_KEY" \
               STUB_VERIFY=fail \
               PATH="$workdir/bin:$PATH"
        _resign "$workdir" "$bundle" "$hash"
    )
    status=$?

    if [ "$status" -ne 0 ]; then
        echo "  resign_deployed_bundle exited $status" >&2
        rc=1
    fi
    if ! grep -q -- '--force' "$workdir/calls.log" 2>/dev/null; then
        echo "  kept a signature that no longer verifies, only because the" >&2
        echo "  certificate matched — the bundle would not launch" >&2
        rc=1
    fi
    rm -rf "$workdir"
    return "$rc"
}

# An identity given as a name that the keychain cannot resolve must be a normal
# empty answer. `security` failing under the callers' `pipefail` used to become
# the function's status and abort their assignment with no output at all — the
# trap this library already documents at profile_for.
test_resign_survives_an_unreadable_keychain() {
    local workdir bundle status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"

    # codesign is stubbed as well, so the only thing that could stop the
    # function short of signing is the failing lookup itself. Without
    # STUB_LEAF_DER the stub reports no certificate, which is the honest state
    # for a bundle whose identity could not be resolved.
    _write_codesign_stub "$workdir"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$workdir/bin/security"
    chmod +x "$workdir/bin/security"

    (
        export CODESIGN_CALLS="$workdir/calls.log" \
               STUB_LEAF_DER="$workdir/absent.der" \
               STUB_ENTITLEMENT="$MIC_KEY" \
               PATH="$workdir/bin:$PATH"
        _resign "$workdir" "$bundle" "Developer ID Application: Nobody (T0)" \
            "$workdir/absent.keychain-db"
    )
    status=$?

    if [ "$status" -ne 0 ]; then
        echo "  exited $status instead of re-signing with the identity as given" >&2
        rc=1
    fi
    if ! grep -q -- '--force' "$workdir/calls.log" 2>/dev/null; then
        echo "  never reached codesign: the failing keychain lookup became the" >&2
        echo "  function's status and aborted the caller's assignment silently" >&2
        rc=1
    fi
    rm -rf "$workdir"
    return "$rc"
}

# A failed re-sign must leave the bundle exactly as it arrived. The profile is
# sealed in _CodeSignature/CodeResources, so removing it before signing turns a
# codesign failure — a locked keychain, an identity the runner's search-list churn
# hid — into an unlaunchable bundle at the shared, TCC-granted deploy path.
test_failed_resign_leaves_the_bundle_intact() {
    local workdir bundle status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    printf 'stand-in for a provisioning profile' \
        > "$bundle/Contents/embedded.provisionprofile"
    codesign --force --sign - --entitlements "$workdir/base.entitlements" "$bundle" 2>/dev/null

    # Real codesign, real failure: no certificate carries this name.
    _resign "$workdir" "$bundle" "NoSuchIdentity-$$"
    status=$?

    if [ "$status" -eq 0 ]; then
        echo "  reported success although codesign could not sign" >&2
        rc=1
    fi
    if [ ! -f "$bundle/Contents/embedded.provisionprofile" ]; then
        echo "  the profile is gone after a failed re-sign" >&2
        rc=1
    fi
    if ! codesign --verify "$bundle" 2>/dev/null; then
        echo "  the bundle no longer verifies after a failed re-sign: the signature" >&2
        echo "  it arrived with seals the profile, so removing it breaks the seal" >&2
        rc=1
    fi
    rm -rf "$workdir"
    return "$rc"
}

test_resign_drops_a_profile_it_cannot_honour() {
    local workdir bundle status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    codesign --force --sign - --entitlements "$workdir/base.entitlements" "$bundle" 2>/dev/null
    printf 'stand-in for a provisioning profile' \
        > "$bundle/Contents/embedded.provisionprofile"

    _resign "$workdir" "$bundle" "-"
    status=$?

    if [ "$status" -ne 0 ]; then
        echo "  resign_deployed_bundle exited $status" >&2
        rc=1
    fi
    if [ -f "$bundle/Contents/embedded.provisionprofile" ]; then
        echo "  kept a profile whose entitlement the new signature does not carry —" >&2
        echo "  that pairing is what e2e-browser.sh fails on, blaming prepare_signing" >&2
        rc=1
    fi
    rm -rf "$workdir"
    return "$rc"
}

# The defect was never in the library, it was in copies of a codesign call. Only
# the two scripts that sign a bundle they just built may name a certificate;
# anything re-signing a bundle someone else built goes through the helper, which
# is the part that keeps the entitlements.
test_only_the_build_scripts_name_a_certificate() {
    local offenders
    # Matches a codesign invocation rather than the bare flag, and skips comment
    # lines, so documenting the rule cannot fail the required lint job.
    # scripts/lib is included because the pattern is just as wrong there — with
    # signing.sh excluded, as the one place the call belongs.
    offenders="$(grep -nE '^[^#]*codesign[^|]*--sign' \
        "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh 2>/dev/null \
        | grep -vE '/(build_release|run_app|signing)\.sh:' || true)"
    if [ -n "$offenders" ]; then
        echo "  these scripts sign a bundle directly instead of via" >&2
        echo "  resign_deployed_bundle, which is how the entitlements got" >&2
        echo "  dropped (issue #609):" >&2
        printf '  %s\n' "$offenders" >&2
        return 1
    fi
}

echo "Testing the deployed-bundle re-sign in scripts/lib/signing.sh"
echo
run_test "a re-sign writes the base entitlements instead of none" \
    test_resign_keeps_the_entitlements
run_test "a signature by the requested certificate is left alone" \
    test_resign_keeps_a_signature_by_the_same_certificate
run_test "a stale signature by that certificate is replaced anyway" \
    test_resign_replaces_a_stale_signature_by_the_same_certificate
run_test "an identity the keychain cannot resolve does not abort the caller" \
    test_resign_survives_an_unreadable_keychain
run_test "a failed re-sign leaves the bundle exactly as it arrived" \
    test_failed_resign_leaves_the_bundle_intact
run_test "a profile the new signature cannot honour is removed" \
    test_resign_drops_a_profile_it_cannot_honour
run_test "only the build scripts name a signing certificate" \
    test_only_the_build_scripts_name_a_certificate
echo

if [ "$FAILED" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests FAILED."
fi
exit "$FAILED"
