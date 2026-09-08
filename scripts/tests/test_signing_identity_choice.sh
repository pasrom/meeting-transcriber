#!/usr/bin/env bash
# Regression test for choose_signing_identity in scripts/lib/signing.sh: which
# certificate a dev bundle is signed with, so TCC keeps the grants it has made.
#
# Bug history:
#   scripts/test_rpc.sh picked its identity with
#   `security find-identity -v -p codesigning | head -1 | awk '{print $2}'`.
#   On a machine holding both an Apple Development and a Developer ID
#   certificate, `head -1` is the Apple Development one, while the Screen
#   Recording grant was made against the Developer ID. To TCC the freshly
#   signed bundle was a different app, /screenshot found no window, and the
#   smoketest died with "RPC returned HTTP 503: no window". run_app.sh already
#   had the right rule, inline; it now lives in the library so both share it.
#
# Every case runs against a `security` transcript and a stubbed or genuinely
# unsigned bundle, never against this machine's keychain: which certificates a
# contributor happens to hold must not decide whether these pass. The scripts
# that call the function are run as well, from a copy of the repository with
# the build, the keychain and codesign stubbed out, because the one thing the
# function cannot check for itself is that a caller asks it BEFORE the copy
# that destroys the answer.
#
# shellcheck disable=SC2329  # every test function is dispatched by name via run_test

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

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

# Hashes that only ever appear in transcripts. Any 40 hex digits will do: the
# library compares them as strings and never asks the keychain about them.
DEVID_A="AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111"
DEVID_B="BBBB2222BBBB2222BBBB2222BBBB2222BBBB2222"
APPLE_DEV="CCCC3333CCCC3333CCCC3333CCCC3333CCCC3333"
SELF_SIGNED="DDDD4444DDDD4444DDDD4444DDDD4444DDDD4444"
# What the `security` stand-in adds when it is asked the wrong question; see
# _write_security_stub.
REVOKED="EEEE5555EEEE5555EEEE5555EEEE5555EEEE5555"
NOT_FOR_CODE="FFFF6666FFFF6666FFFF6666FFFF6666FFFF6666"
NOTE="  NOTE: TCC grants made against a different certificate will not apply to this build."

# A genuinely unsigned throwaway .app in $1; echoes its path. Its executable is
# a shell script: real codesign answers "code object is not signed at all" and
# hands out no certificate, which makes this the honest "no previous signature"
# fixture, so those cases need no codesign stub. A copy of /bin/echo would not
# do: the copy keeps Apple's signature, and real codesign reads Apple's
# certificate out of it (measured), so such a bundle "carries" a certificate
# that merely never appears in any transcript, and the rule that a carried
# certificate must still be in the keychain is then exercised by accident
# rather than by the case written for it.
_make_bundle() {
    local bundle="$1/Some.app"
    mkdir -p "$bundle/Contents/MacOS"
    printf '#!/bin/sh\nexit 0\n' > "$bundle/Contents/MacOS/Some"
    chmod +x "$bundle/Contents/MacOS/Some"
    printf '%s' "$bundle"
}

# A `security` stand-in whose find-identity answer depends on its arguments
# the way the real tool's does. Asked the right question, `-v -p codesigning`,
# it lists the given identities in the given order, then the trailer the real
# tool prints; order is part of the fixture, the bug was "whichever is listed
# first". Asked without `-p codesigning` it adds, first, an identity the
# default policy admits although it cannot sign code. Asked without -v it
# answers in the real tool's two-section form: every matching identity, a
# revoked Developer ID first and marked as such, then the valid ones once
# more. Either way a lookup that drops a flag reads a different keychain than
# the one the case describes and fails it, instead of passing them all.
# Anything but find-identity is refused, as no test expects it.
#
# Each identity is given as `<sha1> "<name>"`; the stub numbers them.
#
# shellcheck disable=SC2016  # the single-quoted strings ARE the stub's source; its $ must not expand here
_write_security_stub() {
    local workdir="$1" line
    shift
    mkdir -p "$workdir/bin"
    {
        printf '#!/usr/bin/env bash\n'
        printf '[ "${1:-}" = find-identity ] || { echo "security stub: unexpected: $*" >&2; exit 2; }\n'
        printf 'shift\nvalid=false\npolicy=basic\n'
        printf 'while [ $# -gt 0 ]; do\n'
        printf '    case "$1" in -v) valid=true ;; -p) policy="$2"; shift ;; esac\n'
        printf '    shift\ndone\n'
        printf 'matching=()\n'
        printf '[ "$policy" = codesigning ] || matching+=(%q)\n' \
            "$NOT_FOR_CODE \"Email Encryption: Someone\""
        for line in "$@"; do printf 'matching+=(%q)\n' "$line"; done
        printf 'list() { local n=0 line; for line in "$@"; do n=$((n + 1)); printf "  %%d) %%s\\n" "$n" "$line"; done; }\n'
        printf 'if [ "$valid" = true ]; then\n'
        printf '    list "${matching[@]}"\n'
        printf '    printf "     %%d valid identities found\\n" "${#matching[@]}"\n'
        printf 'else\n'
        printf '    printf "\\nPolicy: %%s\\n  Matching identities\\n" "$policy"\n'
        printf '    list %q "${matching[@]}"\n' \
            "$REVOKED \"Developer ID Application: Revoked (TEAM)\" (CSSMERR_TP_CERT_REVOKED)"
        printf '    printf "     %%d identities found\\n\\n  Valid identities only\\n" $(( ${#matching[@]} + 1 ))\n'
        printf '    list "${matching[@]}"\n'
        printf '    printf "     %%d valid identities found\\n" "${#matching[@]}"\n'
        printf 'fi\n'
    } > "$workdir/bin/security"
    chmod +x "$workdir/bin/security"
}

# A real certificate nobody can be assumed to hold, as DER in $1/leaf.der;
# echoes its SHA-1. Non-zero when it cannot be made, because an empty hash
# would silently turn "carries X" into "unsigned" and let a case pass without
# ever exercising the rule it pins.
_make_leaf_cert() {
    local workdir="$1" hash
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$workdir/key.pem" -outform DER -out "$workdir/leaf.der" \
        -days 1 -subj "/CN=Identity Choice Test" 2>/dev/null || return 1
    hash="$(openssl x509 -inform DER -in "$workdir/leaf.der" -noout -fingerprint -sha1 2>/dev/null \
        | sed 's/^.*=//' | tr -d ':' | tr '[:lower:]' '[:upper:]')"
    [ -n "$hash" ] || return 1
    printf '%s' "$hash"
}

# Makes the bundle "carry" that certificate: a codesign stand-in hands the
# library the leaf on --extract-certificates, so bundle_signing_cert_sha1
# computes a real hash, and the transcript is then written around that hash.
# Echoes the hash; non-zero as _make_leaf_cert.
_make_carried_cert() {
    local workdir="$1" hash
    hash="$(_make_leaf_cert "$workdir")" || return 1
    mkdir -p "$workdir/bin"
    cat > "$workdir/bin/codesign" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *--extract-certificates*) cp "$workdir/leaf.der" ./codesign0 ;;
esac
exit 0
STUB
    chmod +x "$workdir/bin/codesign"
    printf '%s' "$hash"
}

# Runs the function the way a caller does: a separate bash PROCESS under
# `set -euo pipefail` (a subshell would inherit run_test's errexit suppression,
# see test_signing_resign.sh), stubs first on PATH, the library sourced. Prints
# a `field=value` report: the three globals plus the function's own stdout,
# because the note it prints is part of the contract.
_choose() {
    local workdir="$1" bundle="$2"
    PATH="$workdir/bin:$PATH" \
    SIGNING_LIB="$REPO_ROOT/scripts/lib/signing.sh" \
        bash -c 'set -euo pipefail
                 # shellcheck source=../lib/signing.sh
                 source "$SIGNING_LIB"
                 choose_signing_identity "$1" > "$2/stdout.log"
                 printf "identity=%s\nreason=%s\nlisting=%s\n" \
                     "$CHOSEN_IDENTITY" "$CHOSEN_IDENTITY_REASON" "$CHOSEN_IDENTITY_LISTING"
                 printf "stdout=%s\n" "$(cat "$2/stdout.log")"' bash "$bundle" "$workdir"
}

# _expect <report> <field> <want>: one field of _choose's report.
_expect() {
    local report="$1" field="$2" want="$3" got
    got="$(printf '%s\n' "$report" | sed -n "s/^$field=//p")"
    if [ "$got" != "$want" ]; then
        echo "  $field: expected '${want:-<empty>}', got '${got:-<empty>}'" >&2
        return 1
    fi
}

# Stages, in $1/repo, the slice of the repository the dev-bundle scripts need
# to run up to and including their signing step, and echoes that root. Around
# it, stand-ins for everything that is not the decision under test: `swift`
# builds nothing, `pgrep` finds no running app, the model fetch answers with
# a dummy file, and `open` exits 42 so a script that reaches its launch stops
# there with a status no earlier failure produces. The previous build's
# executable and the freshly built binary carry markers, and the codesign
# stand-in hands out the leaf certificate only while the previous executable
# is still in place. That is what real codesign does (measured: the intact
# bundle yields the certificate, the same bundle with a fresh binary copied in
# reports an ad-hoc signature and yields none), so a script that decides after
# its copy sees no carried certificate here exactly as it would in production.
# Every codesign call is logged to $1/codesign.log.
_stage_dev_bundle_scripts() {
    local workdir="$1" root="$1/repo" spm bundle
    spm="$root/app/MeetingTranscriber"
    bundle="$spm/.build/MeetingTranscriber-Dev.app"
    mkdir -p "$root/scripts/lib" "$root/licenses" "$root/model" "$root/tools/mt-cli" \
        "$spm/Sources" "$spm/Entitlements" "$spm/.build/release" "$bundle/Contents/MacOS" \
        "$workdir/bin" || return 1
    cp "$REPO_ROOT/scripts/run_app.sh" "$REPO_ROOT/scripts/test_rpc.sh" "$root/scripts/" || return 1
    cp "$REPO_ROOT"/scripts/lib/*.sh "$root/scripts/lib/" || return 1
    cp "$REPO_ROOT/app/MeetingTranscriber/Sources/Info.plist" "$spm/Sources/" || return 1
    cp "$REPO_ROOT/app/MeetingTranscriber/Entitlements/Homebrew.entitlements" "$spm/Entitlements/" || return 1
    printf '0.0.0\n' > "$root/VERSION"
    printf 'stand-in licence\n' > "$root/licenses/Test-LICENSE.txt"
    printf 'stand-in model\n' > "$root/model/localvqe-test.gguf"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$root/model/localvqe-test.gguf" \
        > "$root/scripts/fetch-localvqe-model.sh"
    printf 'previous build\n' > "$bundle/Contents/MacOS/MeetingTranscriber"
    printf 'fresh build\n' > "$spm/.build/release/MeetingTranscriber"
    chmod +x "$root/scripts/fetch-localvqe-model.sh" "$bundle/Contents/MacOS/MeetingTranscriber" \
        "$spm/.build/release/MeetingTranscriber" || return 1

    printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/bin/swift"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$workdir/bin/pgrep"
    printf '#!/usr/bin/env bash\nexit 42\n' > "$workdir/bin/open"
    cat > "$workdir/bin/codesign" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$workdir/codesign.log"
case "\$*" in
    *--extract-certificates*)
        if [ -f "$workdir/leaf.der" ] \\
            && grep -q 'previous build' "$bundle/Contents/MacOS/MeetingTranscriber" 2>/dev/null; then
            cp "$workdir/leaf.der" ./codesign0
        fi ;;
    *--verify*) exit 1 ;;
    *"--entitlements :-"*) printf '<key>stand-in</key>' ;;
esac
exit 0
STUB
    chmod +x "$workdir/bin/"* || return 1
    printf '%s' "$root"
}

# Runs one of the staged scripts with the stand-ins first on PATH; its output
# goes to $1/run.log, its status is returned.
_run_dev_bundle_script() {
    local workdir="$1" script="$2"
    shift 2
    PATH="$workdir/bin:$PATH" bash "$workdir/repo/scripts/$script" "$@" > "$workdir/run.log" 2>&1
}

# The identity a staged script signed with, from the codesign log.
_signed_with() {
    sed -n 's/.*--sign \([^ ]*\).*/\1/p' "$1/codesign.log" 2>/dev/null | tail -1
}

# Each test has one exit point, so the temp dir is removed exactly once: a
# RETURN trap would outlive the function that set it and fire inside run_test.

# The renewal overlap: two valid Developer ID certificates, and the one the
# bundle carries is NOT the one listed first. Switching between them voids the
# grants just as thoroughly as switching issuer would.
test_keeps_a_developer_id_the_bundle_already_carries() {
    local workdir bundle carried report status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    carried="$(_make_carried_cert "$workdir")" || {
        echo "  fixture failed: could not create a test certificate" >&2
        rm -rf "$workdir"; return 1
    }
    _write_security_stub "$workdir" \
        "$DEVID_B \"Developer ID Application: Someone (TEAM)\"" \
        "$carried \"Developer ID Application: Someone (TEAM)\""

    report="$(_choose "$workdir" "$bundle")"
    status=$?

    [ "$status" -eq 0 ] || { echo "  choose_signing_identity exited $status" >&2; rc=1; }
    _expect "$report" identity "$carried" || rc=1
    _expect "$report" reason "kept the certificate this bundle already carried" || rc=1
    _expect "$report" listing "2) $carried \"Developer ID Application: Someone (TEAM)\"" || rc=1
    _expect "$report" stdout "" || rc=1
    rm -rf "$workdir"
    return "$rc"
}

# The case that broke test_rpc.sh: the bundle was last signed with an Apple
# Development certificate (what `head -1` handed out), a Developer ID exists,
# and the TCC grants belong to the Developer ID. "Keep what is there" alone
# would pin the bundle to the wrong certificate forever, with the only escape
# being to delete the bundle by hand.
test_moves_an_apple_development_bundle_to_developer_id() {
    local workdir bundle carried report status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    carried="$(_make_carried_cert "$workdir")" || {
        echo "  fixture failed: could not create a test certificate" >&2
        rm -rf "$workdir"; return 1
    }
    _write_security_stub "$workdir" \
        "$carried \"Apple Development: Someone (ABCDE12345)\"" \
        "$DEVID_A \"Developer ID Application: Someone (TEAM)\""

    report="$(_choose "$workdir" "$bundle")"
    status=$?

    [ "$status" -eq 0 ] || { echo "  choose_signing_identity exited $status" >&2; rc=1; }
    _expect "$report" identity "$DEVID_A" || rc=1
    _expect "$report" reason "chose the Developer ID Application certificate" || rc=1
    _expect "$report" listing "2) $DEVID_A \"Developer ID Application: Someone (TEAM)\"" || rc=1
    _expect "$report" stdout "" || rc=1
    rm -rf "$workdir"
    return "$rc"
}

# Nothing to keep (a first build): the Developer ID, not whatever the keychain
# lists first.
test_prefers_developer_id_over_the_first_listed_identity() {
    local workdir bundle report status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    _write_security_stub "$workdir" \
        "$APPLE_DEV \"Apple Development: Someone (ABCDE12345)\"" \
        "$DEVID_A \"Developer ID Application: Someone (TEAM)\""

    report="$(_choose "$workdir" "$bundle")"
    status=$?

    [ "$status" -eq 0 ] || { echo "  choose_signing_identity exited $status" >&2; rc=1; }
    _expect "$report" identity "$DEVID_A" || rc=1
    _expect "$report" reason "chose the Developer ID Application certificate" || rc=1
    _expect "$report" stdout "" || rc=1
    rm -rf "$workdir"
    return "$rc"
}

# No Developer ID at all (a contributor with an Apple Development certificate,
# a self-hosted runner with its self-signed one): the first identity, and the
# log says what that costs.
test_takes_the_first_identity_when_no_developer_id_exists() {
    local workdir bundle report status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    _write_security_stub "$workdir" \
        "$SELF_SIGNED \"MeetingTranscriberDevSelfHosted\"" \
        "$APPLE_DEV \"Apple Development: Someone (ABCDE12345)\""

    report="$(_choose "$workdir" "$bundle")"
    status=$?

    [ "$status" -eq 0 ] || { echo "  choose_signing_identity exited $status" >&2; rc=1; }
    _expect "$report" identity "$SELF_SIGNED" || rc=1
    _expect "$report" reason "no Developer ID Application certificate exists, took the first identity" || rc=1
    _expect "$report" listing "1) $SELF_SIGNED \"MeetingTranscriberDevSelfHosted\"" || rc=1
    _expect "$report" stdout "$NOTE" || rc=1
    rm -rf "$workdir"
    return "$rc"
}

# Same keychain, but the bundle already carries one of its certificates: kept,
# although it is not a Developer ID one, because there is none to move to and
# moving would void the grants for nothing.
test_keeps_a_non_developer_id_certificate_when_there_is_none_to_move_to() {
    local workdir bundle carried report status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    carried="$(_make_carried_cert "$workdir")" || {
        echo "  fixture failed: could not create a test certificate" >&2
        rm -rf "$workdir"; return 1
    }
    _write_security_stub "$workdir" \
        "$APPLE_DEV \"Apple Development: Other (ABCDE12345)\"" \
        "$carried \"Apple Development: Someone (ABCDE12345)\""

    report="$(_choose "$workdir" "$bundle")"
    status=$?

    [ "$status" -eq 0 ] || { echo "  choose_signing_identity exited $status" >&2; rc=1; }
    _expect "$report" identity "$carried" || rc=1
    _expect "$report" reason "kept the certificate this bundle already carried" || rc=1
    _expect "$report" stdout "" || rc=1
    rm -rf "$workdir"
    return "$rc"
}

# The bundle carries a certificate that has since left the keychain (expired
# and removed, or the bundle was built on another machine). It cannot sign
# anything any more, so keeping it is not an option even though there is no
# Developer ID to move to: the last resort applies, note included. The
# keychain deliberately holds no Developer ID, because with one present rule 2
# would give the same answer whether or not the vanished certificate had been
# considered.
test_does_not_keep_a_carried_certificate_that_left_the_keychain() {
    local workdir bundle report status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    _make_carried_cert "$workdir" >/dev/null || {
        echo "  fixture failed: could not create a test certificate" >&2
        rm -rf "$workdir"; return 1
    }
    _write_security_stub "$workdir" \
        "$APPLE_DEV \"Apple Development: Someone (ABCDE12345)\""

    report="$(_choose "$workdir" "$bundle")"
    status=$?

    [ "$status" -eq 0 ] || { echo "  choose_signing_identity exited $status" >&2; rc=1; }
    _expect "$report" identity "$APPLE_DEV" || rc=1
    _expect "$report" reason "no Developer ID Application certificate exists, took the first identity" || rc=1
    _expect "$report" stdout "$NOTE" || rc=1
    rm -rf "$workdir"
    return "$rc"
}

# An empty keychain answers `0 valid identities found`, and `head -1 | awk`
# over that used to hand the word `valid` to codesign as the identity. The
# right answer is no identity, and a normal exit under the callers' `set -e`.
test_an_empty_keychain_yields_no_identity_and_does_not_abort() {
    local workdir bundle report status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    _write_security_stub "$workdir"

    report="$(_choose "$workdir" "$bundle")"
    status=$?

    [ "$status" -eq 0 ] || { echo "  choose_signing_identity exited $status" >&2; rc=1; }
    _expect "$report" identity "" || rc=1
    _expect "$report" reason "" || rc=1
    _expect "$report" stdout "" || rc=1
    rm -rf "$workdir"
    return "$rc"
}

# run_app.sh asks BEFORE it copies the fresh binary over the previous build's
# executable, which is where the carried certificate lives. The renewal overlap
# again, through the script itself: the carried Developer ID is kept only if
# the question was asked while it could still be answered; asked after the
# copy, the script would sign with the Developer ID listed first and the
# grants would go with the certificate it left.
test_run_app_decides_before_it_replaces_the_executable() {
    local workdir carried status signed rc=0
    workdir="$(mktemp -d)"
    if ! _stage_dev_bundle_scripts "$workdir" >/dev/null || ! carried="$(_make_leaf_cert "$workdir")"; then
        echo "  fixture failed: could not stage the scripts or create a test certificate" >&2
        rm -rf "$workdir"; return 1
    fi
    _write_security_stub "$workdir" \
        "$DEVID_B \"Developer ID Application: Someone (TEAM)\"" \
        "$carried \"Developer ID Application: Someone (TEAM)\""

    _run_dev_bundle_script "$workdir" run_app.sh --build-only
    status=$?
    signed="$(_signed_with "$workdir")"

    if [ "$status" -ne 0 ]; then
        echo "  run_app.sh exited $status; its last lines:" >&2
        tail -5 "$workdir/run.log" | sed 's/^/    /' >&2
        rc=1
    fi
    if [ "$signed" != "$carried" ]; then
        echo "  signed with '${signed:-<nothing>}' instead of the carried $carried:" >&2
        echo "  the identity was chosen after the copy replaced the executable, so the" >&2
        echo "  certificate it carried was no longer there to be kept" >&2
        rc=1
    fi
    rm -rf "$workdir"
    return "$rc"
}

# A name that merely CONTAINS the phrase is not a Developer ID. A self-signed
# certificate is named by whoever makes it (setup-self-hosted-runner.sh names
# the runner's), so `Archive of Developer ID Application: ...` listed first
# must lose to the real one listed second. Matched anywhere in the line, it won.
test_a_name_that_only_contains_developer_id_application_does_not_win() {
    local workdir bundle report status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    _write_security_stub "$workdir" \
        "$SELF_SIGNED \"Archive of Developer ID Application: Someone (TEAM)\"" \
        "$DEVID_A \"Developer ID Application: Someone (TEAM)\""

    report="$(_choose "$workdir" "$bundle")"
    status=$?

    [ "$status" -eq 0 ] || { echo "  choose_signing_identity exited $status" >&2; rc=1; }
    _expect "$report" identity "$DEVID_A" || rc=1
    _expect "$report" reason "chose the Developer ID Application certificate" || rc=1
    _expect "$report" listing "2) $DEVID_A \"Developer ID Application: Someone (TEAM)\"" || rc=1
    _expect "$report" stdout "" || rc=1
    rm -rf "$workdir"
    return "$rc"
}

# The same phrase-in-a-name on the carried side: a bundle carrying such a
# certificate is not already on a Developer ID, so with a real one in the
# keychain it moves there rather than being kept.
test_a_carried_certificate_only_named_after_developer_id_is_not_kept() {
    local workdir bundle carried report status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    carried="$(_make_carried_cert "$workdir")" || {
        echo "  fixture failed: could not create a test certificate" >&2
        rm -rf "$workdir"; return 1
    }
    _write_security_stub "$workdir" \
        "$carried \"Archive of Developer ID Application: Someone (TEAM)\"" \
        "$DEVID_A \"Developer ID Application: Someone (TEAM)\""

    report="$(_choose "$workdir" "$bundle")"
    status=$?

    [ "$status" -eq 0 ] || { echo "  choose_signing_identity exited $status" >&2; rc=1; }
    _expect "$report" identity "$DEVID_A" || rc=1
    _expect "$report" reason "chose the Developer ID Application certificate" || rc=1
    rm -rf "$workdir"
    return "$rc"
}

# A record with a hash but no name is not an identity. The real tool never
# prints one; the rules classify by name, so accepting it could only hand the
# last-resort rule something it cannot describe.
test_a_record_without_a_name_is_not_an_identity() {
    local workdir bundle report status rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    _write_security_stub "$workdir" "$DEVID_A"

    report="$(_choose "$workdir" "$bundle")"
    status=$?

    [ "$status" -eq 0 ] || { echo "  choose_signing_identity exited $status" >&2; rc=1; }
    _expect "$report" identity "" || rc=1
    _expect "$report" reason "" || rc=1
    _expect "$report" stdout "" || rc=1
    rm -rf "$workdir"
    return "$rc"
}

# prepare_signing resolves the certificate a profile covers through the same
# lookup, so the two places that ask "which one is the Developer ID" cannot
# answer differently. Real plutil on a real entitlements file; only the
# keychain is a transcript.
test_prepare_signing_resolves_the_same_developer_id() {
    local workdir bundle identity rc=0
    workdir="$(mktemp -d)"
    bundle="$(_make_bundle "$workdir")"
    mkdir -p "$workdir/profiles"
    printf 'stand-in for a provisioning profile' > "$workdir/profiles/com.example.test.provisionprofile"
    cp "$REPO_ROOT/app/MeetingTranscriber/Entitlements/Homebrew.entitlements" "$workdir/base.entitlements"
    _write_security_stub "$workdir" \
        "$SELF_SIGNED \"Archive of Developer ID Application: Someone (TEAM)\"" \
        "$DEVID_A \"Developer ID Application: Someone (TEAM)\""

    identity="$(PATH="$workdir/bin:$PATH" \
        PROFILE_DIR="$workdir/profiles" \
        SIGNING_LIB="$REPO_ROOT/scripts/lib/signing.sh" \
        bash -c 'set -euo pipefail
                 # shellcheck source=../lib/signing.sh
                 source "$SIGNING_LIB"
                 prepare_signing "$1" "$2" com.example.test "" >/dev/null
                 printf "%s" "$SIGNING_IDENTITY"' bash "$bundle" "$workdir/base.entitlements" 2>&1)"

    if [ "$identity" != "$DEVID_A" ]; then
        echo "  prepare_signing resolved '${identity:-<empty>}' instead of $DEVID_A" >&2
        rc=1
    fi
    rm -rf "$workdir"
    return "$rc"
}

echo "Testing choose_signing_identity in scripts/lib/signing.sh"
echo
run_test "a Developer ID the bundle already carries is kept over a newer one" \
    test_keeps_a_developer_id_the_bundle_already_carries
run_test "an Apple Development bundle moves to the Developer ID" \
    test_moves_an_apple_development_bundle_to_developer_id
run_test "with nothing to keep, Developer ID beats the first listed identity" \
    test_prefers_developer_id_over_the_first_listed_identity
run_test "without any Developer ID the first identity is taken, with a note" \
    test_takes_the_first_identity_when_no_developer_id_exists
run_test "a carried certificate is kept when there is no Developer ID to move to" \
    test_keeps_a_non_developer_id_certificate_when_there_is_none_to_move_to
run_test "a carried certificate that left the keychain is not kept" \
    test_does_not_keep_a_carried_certificate_that_left_the_keychain
run_test "an empty keychain yields no identity and does not abort the caller" \
    test_an_empty_keychain_yields_no_identity_and_does_not_abort
run_test "run_app.sh decides before it replaces the executable" \
    test_run_app_decides_before_it_replaces_the_executable
run_test "a name that merely contains 'Developer ID Application' does not win" \
    test_a_name_that_only_contains_developer_id_application_does_not_win
run_test "a carried certificate only named after Developer ID is not kept" \
    test_a_carried_certificate_only_named_after_developer_id_is_not_kept
run_test "a record without a name is not an identity" \
    test_a_record_without_a_name_is_not_an_identity
run_test "prepare_signing resolves the same Developer ID" \
    test_prepare_signing_resolves_the_same_developer_id
echo

if [ "$FAILED" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests FAILED."
fi
exit "$FAILED"
