#!/usr/bin/env bash
# Regression test for scripts/release-signing-gate.sh.
#
# Why it exists: on a `v*` tag the homebrew DMG is uploaded as the GitHub
# Release asset and its SHA-256 goes into the Homebrew cask. The release
# workflow used to choose between the signed and the unsigned build path with
# an inline `[ -n "$DEVELOPER_ID" ]`, so a tag built with that secret missing
# fell through to `build_release.sh --no-notarize`, which ad-hoc signs and
# still produces a DMG. A release nobody can install would have been published
# with no step reporting anything.
#
# Two halves, because a precondition and a postcondition fail differently. The
# preflight refuses before a 20 minute build is spent. The verify looks at the
# artifact that is about to be published, which is the only thing that cannot
# be routed around.
#
# MEASURED, and the reason the verify does not use `codesign --verify`: that
# command exits 0 on an ad-hoc signed bundle ("valid on disk", "satisfies its
# Designated Requirement"). It answers whether a signature is intact, not whose
# it is, so against this particular failure it is no check at all. The
# certificate authority chain is the discriminator: absent for ad-hoc, and
# naming "Developer ID Application" for a real one.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$REPO_ROOT/scripts/release-signing-gate.sh"
FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$2"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

_expect() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then return 0; fi
    echo "  $name: expected '$want', got '$got'" >&2
    return 1
}

# Recorded from a real run of `codesign -dvvv` on this project's own signing
# identity and on an ad-hoc signed copy of the same bundle. Recorded rather
# than produced live because the CI runner that runs this test has no
# Developer ID certificate, while the ad-hoc case below is produced for real.
DEVID_OUTPUT='Executable=/x/Probe.app/Contents/MacOS/Probe
Identifier=probe.local.test
Signature size=8976
Authority=Developer ID Application: A Developer (TEAMID1234)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=TEAMID1234'

ADHOC_OUTPUT='Executable=/x/Probe.app/Contents/MacOS/Probe
Identifier=probe.local.test
Signature=adhoc
TeamIdentifier=not set'

# Prints `<mode>|<status>`. The mode is captured rather than let through, or
# the trailing newline the gate writes for `$(...)` would land between the two.
_preflight() {
    local ref="$1" variant="$2" devid="$3" mode status
    mode="$(DEVELOPER_ID="$devid" bash "$GATE" preflight "$ref" "$variant" 2>"$TMP/err")"
    status=$?
    printf '%s|%s' "$mode" "$status"
}

# --- the preflight ----------------------------------------------------------

# The decision Roman took: a tag build with no certificate must not fall back.
test_a_tag_build_without_a_certificate_is_refused() {
    local rc=0 out
    out="$(_preflight refs/tags/v1.2.3 homebrew "")"
    case "$out" in
        *"|0") echo "  a tag build with no certificate was allowed" >&2; rc=1 ;;
    esac
    local err; err="$(cat "$TMP/err" 2>/dev/null)"
    case "$err" in *DEVELOPER_ID*) ;; *) echo "  the refusal does not name the missing secret" >&2; rc=1 ;; esac
    case "$err" in *"ad-hoc"*) ;; *) echo "  the refusal does not say what would otherwise ship" >&2; rc=1 ;; esac
    return "$rc"
}

# With the certificate present the same build proceeds, and says which mode.
test_a_tag_build_with_a_certificate_selects_the_signed_mode() {
    local rc=0 out
    out="$(_preflight refs/tags/v1.2.3 homebrew "Developer ID Application: A (T)")"
    _expect tag_signed "developer-id|0" "$out" || rc=1
    return "$rc"
}

# The control that keeps the project usable. A contributor's PR and a push to
# main have no access to the secret, and those builds are not published, so
# they must keep producing an ad-hoc DMG rather than failing.
test_a_branch_build_without_a_certificate_still_builds_adhoc() {
    local rc=0 out
    out="$(_preflight refs/heads/main homebrew "")"
    _expect branch_adhoc "adhoc|0" "$out" || rc=1
    out="$(_preflight refs/pull/42/merge homebrew "")"
    _expect pr_adhoc "adhoc|0" "$out" || rc=1
    return "$rc"
}

# The App Store variant is built with --appstore --no-notarize by design and is
# never attached to the release, so the same missing secret must not stop it.
test_the_appstore_variant_on_a_tag_is_not_required_to_be_signed() {
    local rc=0 out
    out="$(_preflight refs/tags/v1.2.3 appstore "")"
    _expect appstore_adhoc "adhoc|0" "$out" || rc=1
    return "$rc"
}

# A tag that is not a version tag is not a release.
test_a_non_version_tag_is_not_treated_as_a_release() {
    local rc=0 out
    out="$(_preflight refs/tags/nightly homebrew "")"
    _expect other_tag "adhoc|0" "$out" || rc=1
    return "$rc"
}

# --- the verdict over codesign output ---------------------------------------

_verdict() {
    GATE_LIB="$REPO_ROOT/scripts/lib/signing.sh" OUT="$1" bash -c '
        set -uo pipefail
        source "$GATE_LIB"
        signing_authority_verdict "$OUT"'
}

test_the_verdict_tells_a_developer_id_from_an_adhoc_signature() {
    local rc=0
    _expect devid   developer-id "$(_verdict "$DEVID_OUTPUT")" || rc=1
    _expect adhoc   adhoc        "$(_verdict "$ADHOC_OUTPUT")" || rc=1
    # Neither: an unsigned bundle, or output codesign could not produce.
    _expect nothing unsigned     "$(_verdict "")" || rc=1
    return "$rc"
}

# An Apple Development certificate is a real certificate and still not one
# Gatekeeper accepts from a download, so it must not read as a release
# signature just because an Authority line exists.
test_a_development_certificate_is_not_a_developer_id() {
    local rc=0 out
    out="$(_verdict 'Authority=Apple Development: A Developer (TEAMID1234)
Authority=Apple Worldwide Developer Relations Certification Authority')"
    _expect development other "$out" || rc=1
    return "$rc"
}

# --- the verify, against a real bundle --------------------------------------

# Produced for real, not stubbed: `codesign --sign -` needs no certificate and
# works on any macOS runner, and this is the exact artifact the old fallback
# would have published.
test_a_really_adhoc_signed_bundle_is_refused() {
    local dir rc=0 status; dir="$TMP/adhoc"
    mkdir -p "$dir/Probe.app/Contents/MacOS"
    cp /bin/echo "$dir/Probe.app/Contents/MacOS/Probe"
    printf '%s' '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundleIdentifier</key><string>probe.local.test</string></dict></plist>' \
        > "$dir/Probe.app/Contents/Info.plist"
    codesign --force --sign - "$dir/Probe.app" 2>/dev/null
    bash "$GATE" verify "$dir/Probe.app" >"$TMP/vout" 2>&1
    status=$?
    if [ "$status" -eq 0 ]; then
        echo "  an ad-hoc signed bundle passed the release check" >&2; rc=1
    fi
    case "$(cat "$TMP/vout")" in
        *"ad-hoc"*) ;;
        *) echo "  the refusal does not say the bundle is ad-hoc signed:" >&2
           sed 's|^|    |' "$TMP/vout" >&2; rc=1 ;;
    esac
    return "$rc"
}

# The positive direction end to end. `codesign` is stubbed because the runner
# has no Developer ID certificate; the negative case above runs unstubbed, so
# between them both directions of the wrapper are exercised.
_verify_with_stub() {
    local out="$1" dir="$TMP/stub"
    mkdir -p "$dir/bin" "$dir/Probe.app"
    { printf '#!/usr/bin/env bash\ncat <<'\''EOF'\''\n%s\nEOF\n' "$out"; } > "$dir/bin/codesign"
    chmod +x "$dir/bin/codesign"
    PATH="$dir/bin:$PATH" bash "$GATE" verify "$dir/Probe.app" >"$TMP/sout" 2>&1
    printf '%s' "$?"
}

test_a_developer_id_signed_bundle_passes_and_says_so() {
    local rc=0 status
    status="$(_verify_with_stub "$DEVID_OUTPUT")"
    _expect verify_devid 0 "$status" || rc=1
    # A silent pass reads the same as a check that never ran.
    case "$(cat "$TMP/sout" 2>/dev/null)" in
        *"Developer ID Application"*) ;;
        *) echo "  the check passed without naming what it accepted" >&2; rc=1 ;;
    esac
    return "$rc"
}

# The message is asserted, not just the status. A non-zero exit is also what a
# missing or unparsable gate script produces, and this test was green for
# exactly that reason before the gate existed.
test_the_stubbed_adhoc_output_is_refused_too() {
    local rc=0 status
    status="$(_verify_with_stub "$ADHOC_OUTPUT")"
    if [ "$status" -eq 0 ]; then echo "  stubbed ad-hoc output passed" >&2; rc=1; fi
    case "$(cat "$TMP/sout" 2>/dev/null)" in
        *"ad-hoc signed and must not be published"*) ;;
        *) echo "  refused, but not for being ad-hoc signed:" >&2
           sed 's|^|    |' "$TMP/sout" >&2; rc=1 ;;
    esac
    return "$rc"
}

# --- the workflow has no way around the gate --------------------------------

# Structural, and stated as such: a workflow cannot be executed from here. What
# it pins is the one thing that made the hole possible, namely a second place
# that decides the build mode. The gate script prints the mode, so if the
# workflow still branches on the secret itself it can build unsigned whatever
# the gate says.
test_the_release_workflow_does_not_decide_the_mode_itself() {
    local wf="$REPO_ROOT/.github/workflows/release.yml" rc=0 body
    body="$(grep -v '^\s*#' "$wf")"
    case "$body" in
        *release-signing-gate.sh*) ;;
        *) echo "  release.yml never invokes the signing gate" >&2; rc=1 ;;
    esac
    # The original defect, in its exact shape.
    case "$body" in
        *'-n "${DEVELOPER_ID:-}"'*)
            echo "  release.yml still picks the build mode from DEVELOPER_ID itself," >&2
            echo "  which is the branch that shipped an ad-hoc DMG from a tag" >&2
            rc=1 ;;
    esac
    # Both halves have to be wired. The preflight alone can be satisfied by a
    # secret that is present and a build that drops it anyway; only the verify
    # looks at what is about to be published.
    case "$body" in
        *"release-signing-gate.sh verify"*) ;;
        *) echo "  release.yml never verifies the built artifact's signature" >&2; rc=1 ;;
    esac
    case "$body" in
        *"release-signing-gate.sh preflight"*) ;;
        *) echo "  release.yml never runs the preflight" >&2; rc=1 ;;
    esac
    return "$rc"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_test "a tag build without a certificate is refused"          test_a_tag_build_without_a_certificate_is_refused
run_test "a tag build with a certificate selects signed mode"    test_a_tag_build_with_a_certificate_selects_the_signed_mode
run_test "a branch build without a certificate still builds"     test_a_branch_build_without_a_certificate_still_builds_adhoc
run_test "the appstore variant on a tag is not required signed"  test_the_appstore_variant_on_a_tag_is_not_required_to_be_signed
run_test "a non-version tag is not treated as a release"         test_a_non_version_tag_is_not_treated_as_a_release
run_test "the verdict tells a Developer ID from an ad-hoc sig"   test_the_verdict_tells_a_developer_id_from_an_adhoc_signature
run_test "a development certificate is not a Developer ID"       test_a_development_certificate_is_not_a_developer_id
run_test "a really ad-hoc signed bundle is refused"              test_a_really_adhoc_signed_bundle_is_refused
run_test "a Developer ID signed bundle passes and says so"       test_a_developer_id_signed_bundle_passes_and_says_so
run_test "the stubbed ad-hoc output is refused too"              test_the_stubbed_adhoc_output_is_refused_too
run_test "the release workflow does not decide the mode itself"  test_the_release_workflow_does_not_decide_the_mode_itself
echo

if [ "$FAILED" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests FAILED."
fi
exit "$FAILED"
