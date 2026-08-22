#!/usr/bin/env bash
# Regression test for scripts/ci/check-merge-commits.sh.
#
# Why this exists: the check is a shell snippet whose whole job is to fail. A
# guard that has never been shown to fire is not evidence of anything, and the
# first version of this check lived inline in ci.yml, where the only way to
# exercise it was to hand-extract it from the workflow YAML.
#
# The four states that matter are cheap to build and easy to get wrong:
#   - a branch that merged the base in           -> must report, exit 1
#   - a clean branch                             -> must stay silent, exit 0
#   - a branch merely behind the base            -> must stay silent, exit 0
#   - a merge that is on the base already        -> must not blame the branch
#   - a base ref CI failed to fetch              -> must read as a CI fault, exit 2
#
# Each case builds a throwaway repo in a temp dir; the whole file runs in ~1s.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_SH="$REPO_ROOT/scripts/ci/check-merge-commits.sh"

FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$name"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

# Pinned identity and no signing/hooks, so a contributor's global git config
# cannot change what these fixtures look like.
g() {
    git -c user.email=test@example.invalid -c user.name=Test \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

commit_file() {   # commit_file <name> <message>
    echo "$1" > "$1"
    g add "$1"
    g commit -qm "$2"
}

# new_repo: fresh repo on branch 'main' with one commit; leaves $PWD inside it.
new_repo() {
    local dir
    dir=$(mktemp -d)
    cd "$dir" || return 1
    g init -q -b main .
    commit_file base.txt "base commit"
}

# run_check <base-ref> -> sets CHECK_OUT, CHECK_RC
run_check() {
    CHECK_OUT=$(bash "$CHECK_SH" "$@" 2>&1)
    CHECK_RC=$?
}

fail() {   # fail <message>
    echo
    echo "  $1"
    echo "--- check output ---"
    echo "$CHECK_OUT"
    echo "--------------------"
    return 1
}

test_merge_commit_is_reported() {
    local tmp; tmp=$(pwd)
    ( new_repo || exit 1
      g switch -qc feat
      commit_file work.txt "feat: the real change"
      g switch -q main
      commit_file other.txt "fix: something on main"
      g switch -q feat
      g merge -q --no-edit main               # the mistake this check exists for
      run_check main
      [ "$CHECK_RC" -eq 1 ] || fail "expected exit 1 for a merged-in base, got $CHECK_RC" || exit 1
      echo "$CHECK_OUT" | grep -q "Merge branch 'main' into feat" \
          || fail "the offending commit is not named in the output" || exit 1
      # The fix has to be the one that works in a fork clone, where `origin` is
      # the contributor's fork and rebasing onto it is a no-op.
      echo "$CHECK_OUT" | grep -q "git rebase FETCH_HEAD" \
          || fail "no fork-safe rebase command in the output" || exit 1
      echo "$CHECK_OUT" | grep -q "Allow edits by maintainers" \
          || fail "CONTRIBUTING.md's escape hatch is missing from the output" || exit 1
      echo "$CHECK_OUT" | grep -q "advisory" \
          || fail "output does not say the check is advisory" || exit 1
    ) || return 1
    cd "$tmp" || return 1
}

test_clean_branch_passes() {
    local tmp; tmp=$(pwd)
    ( new_repo || exit 1
      g switch -qc feat
      commit_file work.txt "feat: the real change"
      run_check main
      [ "$CHECK_RC" -eq 0 ] || fail "expected exit 0 for a linear branch, got $CHECK_RC" || exit 1
    ) || return 1
    cd "$tmp" || return 1
}

# A branch that is simply behind the base has no commits of its own in
# base..HEAD. It must not be reported: nothing about it is wrong.
test_branch_behind_base_passes() {
    local tmp; tmp=$(pwd)
    ( new_repo || exit 1
      g switch -qc feat
      g switch -q main
      commit_file ahead.txt "fix: base moved on"
      g switch -q feat
      run_check main
      [ "$CHECK_RC" -eq 0 ] || fail "expected exit 0 for a branch behind base, got $CHECK_RC" || exit 1
    ) || return 1
    cd "$tmp" || return 1
}

# Merges already reachable from the base are the base's history, not this
# branch's doing. Pins the range direction (base..HEAD, never --all).
test_merge_on_base_does_not_blame_branch() {
    local tmp; tmp=$(pwd)
    ( new_repo || exit 1
      g switch -qc side
      commit_file side.txt "chore: side commit"
      g switch -q main
      commit_file main2.txt "fix: main commit"
      g merge -q --no-edit side               # a merge commit that lives on main
      g switch -qc feat
      commit_file work.txt "feat: the real change"
      run_check main
      [ "$CHECK_RC" -eq 0 ] || fail "a merge on the base was blamed on the branch (exit $CHECK_RC)" || exit 1
    ) || return 1
    cd "$tmp" || return 1
}

test_unresolvable_base_ref_is_a_ci_error() {
    local tmp; tmp=$(pwd)
    ( new_repo || exit 1
      run_check origin/does-not-exist
      [ "$CHECK_RC" -eq 2 ] || fail "expected exit 2 for an unresolvable base ref, got $CHECK_RC" || exit 1
      echo "$CHECK_OUT" | grep -q "CI could not resolve the base ref" \
          || fail "missing the distinct 'could not resolve' message" || exit 1
      # Must not read as a verdict on the branch: no rebase instructions here.
      if echo "$CHECK_OUT" | grep -q "git rebase"; then
          fail "a CI fault told the contributor to rebase" || exit 1
      fi
    ) || return 1
    cd "$tmp" || return 1
}

run_test test_merge_commit_is_reported
run_test test_clean_branch_passes
run_test test_branch_behind_base_passes
run_test test_merge_on_base_does_not_blame_branch
run_test test_unresolvable_base_ref_is_a_ci_error

exit "$FAILED"
