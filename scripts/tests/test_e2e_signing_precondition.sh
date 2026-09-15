#!/usr/bin/env bash
# Lane assertion: a driver that overwrites the shared deployed bundle must
# establish its signing identity BEFORE it does so.
#
# Why the order is the thing worth pinning, and not merely that a check exists:
# the deploy runs `rsync -a --delete` over $HOME/Applications/..., the path whose
# TCC grants are keyed on the certificate leaf, and every `--no-build` sibling
# lane reuses that same bundle. A driver that refuses AFTER the rsync has
# already replaced a signed, granted deployment with an unsigned one, so the
# refusal leaves the host worse off than no check at all.
#
# This is a grep over the real drivers rather than a synthetic fixture, matching
# the lane assertions in test_signing_resign.sh: the property is about the
# scripts as committed, so reading anything else would not pin them.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$2"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

# Drivers deliberately exempted. Empty, and meant to stay that way: every lane
# that deploys now takes the precondition. A name added here has to come with a
# reason, and the second assertion below removes it again as soon as the lane
# stops needing the exemption.
KNOWN_LAGGING=""

# First matching line number, comment lines excluded so that documenting a
# command cannot stand in for running it.
_first_line() {
    grep -nE "^[^#]*$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

test_identity_is_established_before_the_deployment_is_overwritten() {
    local lane base rsync_line identity_line offenders="" rc=0 examined=0
    for lane in "$REPO_ROOT"/scripts/e2e-*.sh; do
        base="$(basename "$lane")"
        case " $KNOWN_LAGGING " in *" $base "*) continue ;; esac

        rsync_line="$(_first_line "$lane" 'rsync -a --delete')"
        [ -n "$rsync_line" ] || continue          # lane does not deploy

        examined=$(( examined + 1 ))
        identity_line="$(_first_line "$lane" 'require_signing_identity')"
        if [ -z "$identity_line" ]; then
            offenders="$offenders  $base: overwrites the deployment, never resolves an identity"$'\n'
            rc=1
        elif [ "$identity_line" -gt "$rsync_line" ]; then
            offenders="$offenders  $base: identity at line $identity_line, rsync at line $rsync_line"$'\n'
            rc=1
        fi
    done

    # A scan that inspected nothing must not read as a pass: a rename, a move to
    # scripts/e2e/, or an over-full exemption list would otherwise make this
    # permanently and silently green.
    if [ "$examined" -eq 0 ]; then
        echo "  no deploying driver was examined at all — the scan matched nothing" >&2
        return 1
    fi

    if [ "$rc" -ne 0 ]; then
        echo "  these drivers replace the granted deployment before they know they" >&2
        echo "  can re-sign it, so refusing afterwards strands an unsigned bundle at" >&2
        echo "  the path every --no-build sibling lane reuses:" >&2
        printf '%s' "$offenders" >&2
    fi
    return "$rc"
}

# The exclusion list is only honest while its members really are lagging. If one
# is fixed, it has to leave the list, or the list starts hiding a lane that no
# longer needs hiding and the next reader trusts it.
test_the_exclusion_list_has_no_stale_members() {
    local base lane rsync_line identity_line stale="" rc=0
    for base in $KNOWN_LAGGING; do
        lane="$REPO_ROOT/scripts/$base"
        if [ ! -f "$lane" ]; then
            stale="$stale  $base: listed but no such driver"$'\n'; rc=1; continue
        fi
        rsync_line="$(_first_line "$lane" 'rsync -a --delete')"
        identity_line="$(_first_line "$lane" 'require_signing_identity')"
        if [ -n "$rsync_line" ] && [ -n "$identity_line" ] && [ "$identity_line" -lt "$rsync_line" ]; then
            stale="$stale  $base: already resolves the identity first; drop it from KNOWN_LAGGING"$'\n'
            rc=1
        fi
    done

    if [ "$rc" -ne 0 ]; then
        echo "  the exclusion list is out of date:" >&2
        printf '%s' "$stale" >&2
    fi
    return "$rc"
}

run_test "identity established before the deployment is overwritten" \
    test_identity_is_established_before_the_deployment_is_overwritten
run_test "exclusion list has no stale members" \
    test_the_exclusion_list_has_no_stale_members
echo

if [ "$FAILED" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests FAILED."
fi
exit "$FAILED"
