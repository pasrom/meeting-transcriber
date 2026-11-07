#!/usr/bin/env bash
# Regression test for scripts/ci/check-tool-trailers.sh.
#
# The check is advisory, so a silent miss shows as green and nobody notices;
# this file is what shows it still fires, and still leaves people alone:
#   - a session-link trailer                          -> must report, exit 1
#   - an AI co-author line                            -> must report, exit 1
#   - the same line in one paragraph with other text,
#     which git's own trailer parser does not see     -> must still report
#   - a human co-author, even one called Claude       -> must stay silent, exit 0
#   - a non-AI bot co-author (an autofix action)      -> must stay silent, exit 0
#   - a tool trailer already on the base              -> must not blame the branch
#   - a base ref CI failed to fetch                   -> must read as a CI fault, exit 2
#
# Each case builds a throwaway repo in a temp dir; the whole file runs in ~1s.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_SH="$REPO_ROOT/scripts/ci/check-tool-trailers.sh"

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

commit_msg() {   # commit_msg <file> <full message>
    echo "$1" > "$1"
    g add "$1"
    g commit -q -F - <<<"$2"
}

# new_branch: fresh repo with one commit on 'main', then on branch 'feat'.
new_branch() {
    local dir
    dir=$(mktemp -d)
    cd "$dir" || return 1
    g init -q -b main .
    commit_msg base.txt "base commit"
    g switch -qc feat
}

run_check() {   # run_check <base-ref> -> sets CHECK_OUT, CHECK_RC
    CHECK_OUT=$(bash "$CHECK_SH" "$@" 2>&1)
    CHECK_RC=$?
}

fail() {
    echo
    echo "  $1"
    echo "--- check output ---"
    echo "$CHECK_OUT"
    echo "--------------------"
    return 1
}

expect_reported() {   # expect_reported <message> <text that must be named>
    local tmp; tmp=$(pwd)
    ( new_branch || exit 1
      commit_msg work.txt "$1"
      run_check main
      [ "$CHECK_RC" -eq 1 ] || fail "expected exit 1, got $CHECK_RC" || exit 1
      echo "$CHECK_OUT" | grep -qF "$2" || fail "the offending line is not named" || exit 1
      echo "$CHECK_OUT" | grep -q "PR description" \
          || fail "output does not say where the model belongs instead" || exit 1
      echo "$CHECK_OUT" | grep -q "advisory" || fail "output does not say it is advisory" || exit 1
    ) || return 1
    cd "$tmp" || return 1
}

expect_silent() {   # expect_silent <message>
    local tmp; tmp=$(pwd)
    ( new_branch || exit 1
      commit_msg work.txt "$1"
      run_check main
      [ "$CHECK_RC" -eq 0 ] || fail "expected exit 0, got $CHECK_RC" || exit 1
    ) || return 1
    cd "$tmp" || return 1
}

test_session_trailer_is_reported() {
    expect_reported $'feat: x\n\nClaude-Session: https://claude.ai/code/session_abc' \
        "Claude-Session: https://claude.ai/code/session_abc"
}

test_ai_coauthor_is_reported() {
    expect_reported $'feat: x\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' \
        "noreply@anthropic.com"
}

# Git's trailer parser ignores a last paragraph that mixes trailers with other
# lines, so this one is invisible to `%(trailers)`. Tools write exactly this.
test_coauthor_beside_other_text_is_reported() {
    expect_reported $'feat: x\n\nGenerated with a tool\nCo-Authored-By: Claude <noreply@anthropic.com>' \
        "noreply@anthropic.com"
}

test_copilot_coauthor_is_reported() {
    expect_reported $'feat: x\n\nCo-authored-by: Copilot <1+Copilot@users.noreply.github.com>' \
        "Copilot@users.noreply.github.com"
}

test_human_coauthor_named_claude_passes() {
    expect_silent $'feat: x\n\nCo-Authored-By: Claude Smith <claude.smith@example.com>'
}

test_non_ai_bot_coauthor_passes() {
    expect_silent $'style: autofix\n\nCo-authored-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'
}

# Prose that merely starts with a word ending in "Session:" is not a trailer.
test_session_word_in_prose_passes() {
    expect_silent $'fix: retain the delegate\n\nURLSession: the delegate is retained strongly, so release it on stop.'
}

# The pattern is anchored: a quoted or indented trailer in the body is prose.
test_indented_session_trailer_passes() {
    expect_silent $'docs: explain the check\n\nIt reports lines such as\n\n    Claude-Session: https://claude.ai/code/session_abc'
}

test_plain_commit_passes() {
    expect_silent $'feat: x\n\nFixes: #12'
}

test_trailer_on_base_does_not_blame_branch() {
    local tmp; tmp=$(pwd)
    ( new_branch || exit 1
      g switch -q main
      commit_msg old.txt $'chore: old\n\nClaude-Session: https://claude.ai/code/session_old'
      g switch -qc feat2
      commit_msg work.txt "feat: clean change"
      run_check main
      [ "$CHECK_RC" -eq 0 ] || fail "a trailer on the base was blamed on the branch (exit $CHECK_RC)" || exit 1
    ) || return 1
    cd "$tmp" || return 1
}

test_unresolvable_base_ref_is_a_ci_error() {
    local tmp; tmp=$(pwd)
    ( new_branch || exit 1
      run_check origin/does-not-exist
      [ "$CHECK_RC" -eq 2 ] || fail "expected exit 2, got $CHECK_RC" || exit 1
      echo "$CHECK_OUT" | grep -q "CI could not resolve the base ref" \
          || fail "missing the distinct 'could not resolve' message" || exit 1
    ) || return 1
    cd "$tmp" || return 1
}

run_test test_session_trailer_is_reported
run_test test_ai_coauthor_is_reported
run_test test_coauthor_beside_other_text_is_reported
run_test test_copilot_coauthor_is_reported
run_test test_human_coauthor_named_claude_passes
run_test test_non_ai_bot_coauthor_passes
run_test test_session_word_in_prose_passes
run_test test_indented_session_trailer_passes
run_test test_plain_commit_passes
run_test test_trailer_on_base_does_not_blame_branch
run_test test_unresolvable_base_ref_is_a_ci_error

exit "$FAILED"
