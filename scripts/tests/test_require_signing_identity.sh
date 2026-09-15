#!/usr/bin/env bash
# Regression test for `require_signing_identity` in scripts/lib/signing.sh.
#
# Why it exists: the e2e drivers replace the bundle at the shared, TCC-granted
# deploy path, and the grants are keyed on the certificate leaf. A driver that
# only discovers it cannot sign after that copy has swapped a working
# deployment for an unsigned one, so the decision has to be taken before the
# build, and it has to be taken for BOTH routes. A set DEVELOPER_ID is not
# evidence: the workflow exports the name on every lane and imports the
# certificate only when the keychain secret is present.
#
# The two refusals are also not interchangeable. An ambiguous identity inside
# the dev keychain is not fixed by re-running the setup script, so it must not
# be reported as if it were.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HASH_A="1234567890ABCDEF1234567890ABCDEF12345678"
HASH_B="ABCDEF1234567890ABCDEF1234567890ABCDEF12"
FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$2"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

# A `security` stand-in: `find-identity` prints whatever the fixture holds, and
# `unlock-keychain` succeeds. Nothing else is reached by the function.
_write_security_stub() {
    local dir="$1"
    mkdir -p "$dir/bin"
    cat > "$dir/bin/security" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    find-identity)   cat "$STUB_IDENTITIES" 2>/dev/null || true ;;
    unlock-keychain) ;;
esac
exit 0
STUB
    chmod +x "$dir/bin/security"
}

# Runs the function the way a driver does and echoes `<status>|<identity>`, so a
# case can assert on both the verdict and what the caller would sign with.
# A separate bash PROCESS, not a subshell: run_test calls each test from an `if`
# condition, and bash suppresses errexit for the whole dynamic extent of a
# tested command, nested subshells included.
_require() {
    local dir="$1" developer_id="$2" keychain="$3"
    # Every input the function reads is pinned, so an exported
    # E2E_SIGNING_KEYCHAIN or a renamed DEV_CERT_NAME on the developer's shell
    # cannot make these tests mean something different than they do in CI.
    PATH="$dir/bin:$PATH" \
    STUB_IDENTITIES="$dir/identities" \
    SIGNING_LIB="$REPO_ROOT/scripts/lib/signing.sh" \
    DEVELOPER_ID="$developer_id" \
    DEV_KEYCHAIN="$keychain" \
    E2E_SIGNING_KEYCHAIN="${4:-}" \
    DEV_CERT_NAME="MeetingTranscriberDevSelfHosted" \
        bash -c 'set -uo pipefail
                 source "$SIGNING_LIB"
                 if require_signing_identity 2>"$STUB_IDENTITIES.err"; then
                     printf "ok|%s|%s" "$SIGN_IDENTITY" "$SIGN_KEYCHAIN"
                 else
                     # The globals are printed on this path too: a refusal that
                     # leaves them populated would hand a caller who missed the
                     # return code the very values the function rejected.
                     printf "refused|%s|%s" "${SIGN_IDENTITY:-}" "${SIGN_KEYCHAIN:-}"
                 fi'
}

_stderr_of() { cat "$1/identities.err" 2>/dev/null; }

check() {
    local name="$1" expect_status="$2" expect_identity="$3" expect_keychain="$4"
    local out status identity keychain rest
    shift 4
    out="$("$@")"
    status="${out%%|*}"; rest="${out#*|}"
    identity="${rest%%|*}"; keychain="${rest#*|}"
    if [ "$status" = "$expect_status" ] && [ "$identity" = "$expect_identity" ] \
       && [ "$keychain" = "$expect_keychain" ]; then
        echo "  $name ... ok" >&2
        return 0
    fi
    echo "  $name: expected $expect_status/'$expect_identity'/'$expect_keychain', got $status/'$identity'/'$keychain'" >&2
    return 1
}

# An explicit Developer ID that really resolves is the CI route. The identity
# handed on is the NAME, not the hash: `resign_deployed_bundle` takes either and
# resolves it itself, and every driver has always passed the name here.
test_developer_id_that_resolves_is_accepted() {
    local dir name; dir="$(mktemp -d)"
    name="Developer ID Application: Someone (TEAM)"
    _write_security_stub "$dir"
    printf '  1) %s "%s"\n' "$HASH_A" "$name" > "$dir/identities"
    local rc=0
    check developer_id ok "$name" "$dir/ci.keychain-db" \
        _require "$dir" "$name" "$dir/absent.keychain-db" "$dir/ci.keychain-db" || rc=1
    rm -rf "$dir"; return "$rc"
}

# The name and the certificate are separate secrets, and the workflow documents
# the self-signed cert as the fallback when only the name is present. Naming an
# identity is not being able to sign with it, but it must not cost the lane its
# fallback either.
test_unresolvable_developer_id_falls_back_to_the_dev_keychain() {
    local dir; dir="$(mktemp -d)" rc=0
    _write_security_stub "$dir"
    printf '  1) %s "MeetingTranscriberDevSelfHosted"\n' "$HASH_B" > "$dir/identities"
    : > "$dir/dev.keychain-db"
    check fallback ok "$HASH_B" "$dir/dev.keychain-db" \
        _require "$dir" "Developer ID Application: Ghost (TEAM)" "$dir/dev.keychain-db" || rc=1
    case "$(_stderr_of "$dir")" in
        *"falling back to the dev keychain"*) ;;
        *) echo "  the fallback happened without saying so" >&2; rc=1 ;;
    esac
    rm -rf "$dir"; return "$rc"
}

# The self-hosted and local route.
test_dev_keychain_identity_is_accepted() {
    local dir; dir="$(mktemp -d)" rc=0
    _write_security_stub "$dir"
    printf '  1) %s "MeetingTranscriberDevSelfHosted"\n' "$HASH_B" > "$dir/identities"
    : > "$dir/dev.keychain-db"
    check dev_keychain ok "$HASH_B" "$dir/dev.keychain-db" \
        _require "$dir" "" "$dir/dev.keychain-db" || rc=1
    rm -rf "$dir"; return "$rc"
}

# Neither route: the one case the old warn-and-continue branch let through.
test_no_route_at_all_is_refused_with_both_remedies() {
    local dir; dir="$(mktemp -d)" rc=0
    _write_security_stub "$dir"
    : > "$dir/identities"
    check no_route refused "" "" _require "$dir" "" "$dir/absent.keychain-db" || rc=1
    local err; err="$(_stderr_of "$dir")"
    case "$err" in *"Set DEVELOPER_ID"*) ;; *) echo "  refusal omits the DEVELOPER_ID remedy" >&2; rc=1 ;; esac
    case "$err" in *"setup-self-hosted-runner.sh"*) ;; *) echo "  refusal omits the setup-script remedy" >&2; rc=1 ;; esac
    rm -rf "$dir"; return "$rc"
}

# Two certificates carrying the same name: identity_sha1 refuses to guess, and
# re-running the setup script would only add a third. The refusal has to say so
# rather than repeating the generic advice.
test_ambiguous_dev_identity_is_not_blamed_on_a_missing_setup() {
    local dir; dir="$(mktemp -d)" rc=0
    _write_security_stub "$dir"
    printf '  1) %s "MeetingTranscriberDevSelfHosted"\n  2) %s "MeetingTranscriberDevSelfHosted (old)"\n' \
        "$HASH_A" "$HASH_B" > "$dir/identities"
    : > "$dir/dev.keychain-db"
    check ambiguous refused "" "" _require "$dir" "" "$dir/dev.keychain-db" || rc=1
    local err; err="$(_stderr_of "$dir")"
    case "$err" in *"unambiguous"*) ;; *) echo "  refusal does not name the ambiguity" >&2; rc=1 ;; esac
    case "$err" in
        *"will not resolve it"*) ;;
        *) echo "  refusal does not say re-running the setup script will not help" >&2; rc=1 ;;
    esac
    rm -rf "$dir"; return "$rc"
}

run_test "a Developer ID that resolves is accepted"              test_developer_id_that_resolves_is_accepted
run_test "an unresolvable Developer ID falls back"              test_unresolvable_developer_id_falls_back_to_the_dev_keychain
run_test "a dev-keychain identity is accepted"                   test_dev_keychain_identity_is_accepted
run_test "no route at all is refused, naming both remedies"      test_no_route_at_all_is_refused_with_both_remedies
run_test "an ambiguous dev identity is reported as ambiguous"    test_ambiguous_dev_identity_is_not_blamed_on_a_missing_setup
echo

if [ "$FAILED" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests FAILED."
fi
exit "$FAILED"
