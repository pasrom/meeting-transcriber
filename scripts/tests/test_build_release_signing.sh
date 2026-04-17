#!/usr/bin/env bash
# Regression test for scripts/build_release.sh codesign-identity detection.
#
# Bug history:
#   `SIGN_HASH=$(security find-identity ... | grep | head -1)` aborted under
#   `set -euo pipefail` when no codesign identity existed (grep exits 1 on
#   no match → pipefail → set -e). Fixed by appending `|| true`.
#
# This test sources build_release.sh and calls detect_sign_hash() directly
# with a PATH-stubbed `security` to simulate "no identity installed".

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$name"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

# Creates a stub PATH directory containing a no-op `security` and prints its path.
# Caller is responsible for cleanup.
make_security_stub() {
    local dir
    dir=$(mktemp -d)
    cat > "$dir/security" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$dir/security"
    printf '%s' "$dir"
}

test_detect_sign_hash_empty_when_no_identity() {
    local stub_dir result rc
    stub_dir=$(make_security_stub)
    # Expand $stub_dir now (single command string), not at RETURN time —
    # the local goes out of scope when the function returns.
    trap "rm -rf -- '$stub_dir'" RETURN

    result=$(PATH="$stub_dir:$PATH" bash -c "set -euo pipefail; source '$REPO_ROOT/scripts/build_release.sh'; detect_sign_hash")
    rc=$?

    if [ "$rc" -ne 0 ]; then
        echo
        echo "  detect_sign_hash aborted with exit $rc under set -euo pipefail"
        return 1
    fi
    if [ -n "$result" ]; then
        echo
        echo "  expected empty result, got: $result"
        return 1
    fi
    return 0
}

run_test test_detect_sign_hash_empty_when_no_identity

exit "$FAILED"
