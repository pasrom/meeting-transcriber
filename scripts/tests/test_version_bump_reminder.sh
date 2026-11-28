#!/usr/bin/env bash
# Regression test for scripts/ci/version-bump-reminder.sh.
#
# The script only runs at the end of a real stable release, so this is the one
# place its decisions are exercised before that. `gh` is replaced by a stub on
# PATH that answers only the exact argument lists the script is meant to send
# (VERSION on main, the release by tag, the tap's stable Cask, open issues)
# and exits 99 on anything else, so a changed repo, path, header, tag or
# filter fails the happy path. It records any create and fails on demand.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/version-bump-reminder.sh"

FAILED=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
raw="Accept: application/vnd.github.raw"
call=""
case "$*" in
    "api -H $raw repos/owner/app/contents/VERSION?ref=main") call=main-version ;;
    "api repos/owner/app/releases/tags/$STUB_TAG --jq .assets[].name") call=release ;;
    "api -H $raw repos/pasrom/homebrew-meeting-transcriber/contents/Casks/meeting-transcriber.rb") call=cask ;;
    "issue list --state open --limit 1000 --json title --jq .[].title") call=list ;;
    "issue create --title "*)
        if [ $# -eq 6 ] && [ "$4" = "Bump VERSION to ${STUB_TAG#v}" ] && [ "$5" = --body ]; then
            call=create
        fi ;;
esac
if [ -z "$call" ]; then
    echo "gh stub: unexpected call: $*" >&2
    exit 99
fi
if [ "$call" = "$STUB_FAIL" ]; then
    echo "gh: Internal Server Error (HTTP 500)" >&2
    exit 1
fi
case "$call" in
    main-version) printf '%s' "$STUB_MAIN_VERSION" ;;
    release)
        if [ "$STUB_FAIL" = release-404 ]; then
            echo '{"message":"Not Found","status":"404"}'
            echo "gh: Not Found (HTTP 404)" >&2
            exit 1
        fi
        printf '%s\n' "$STUB_ASSETS" ;;
    cask) printf 'cask "meeting-transcriber" do\n  version "%s"\nend\n' "$STUB_CASK_VERSION" ;;
    list) cat "$STUB_OPEN_TITLES" ;;
    create) printf '%s\n' "$@" > "$STUB_CREATED" ;;
esac
EOF
chmod +x "$WORK/bin/gh"

# run <tag> <main-version> [open title...] -> sets OUT, RC; created issue args in $WORK/created.
# By default the release carries the tag's DMG and its checksum file, and the
# Cask reads the tag's version; ASSETS, CASK_VERSION and FAIL (a call name
# from the stub, or release-404) override that for one call.
run() {
    local tag="$1" main="$2"; shift 2
    : > "$WORK/open"
    for t in "$@"; do printf '%s\n' "$t" >> "$WORK/open"; done
    rm -f "$WORK/created"
    OUT="$(PATH="$WORK/bin:$PATH" GH_REPO=owner/app STUB_TAG="$tag" STUB_MAIN_VERSION="$main" \
        STUB_OPEN_TITLES="$WORK/open" STUB_CREATED="$WORK/created" \
        STUB_ASSETS="${ASSETS-MeetingTranscriber-${tag#v}.dmg.sha256
MeetingTranscriber-${tag#v}.dmg}" \
        STUB_CASK_VERSION="${CASK_VERSION-${tag#v}}" STUB_FAIL="${FAIL:-}" \
        GITHUB_RUN_ID=42 bash "$SCRIPT" "$tag" 2>&1)"
    RC=$?
    unset ASSETS CASK_VERSION FAIL
}

check() {   # check <name> <expected rc> <expect create: yes|no> [expected title]
    local name="$1" rc="$2" create="$3" title="${4:-}"
    local ok=1
    [ "$RC" -eq "$rc" ] || ok=0
    if [ "$create" = yes ]; then
        [ -f "$WORK/created" ] && grep -qxF "$title" "$WORK/created" || ok=0
    else
        [ ! -f "$WORK/created" ] || ok=0
    fi
    if [ "$ok" = 1 ]; then
        echo "$name ... PASS"
    else
        echo "$name ... FAIL (rc=$RC, expected $rc, create expected: $create)"
        printf '%s\n' "$OUT"
        FAILED=1
    fi
}

run v0.9.0 0.8.1
check "stale VERSION opens the issue" 0 yes "Bump VERSION to 0.9.0"
if [ -f "$WORK/created" ] \
    && grep -qF 'chore: bump VERSION to 0.9.0' "$WORK/created" \
    && grep -qF 'still reads 0.8.1' "$WORK/created" \
    && grep -qF 'releases/tag/v0.9.0' "$WORK/created" \
    && grep -qF 'actions/runs/42' "$WORK/created"; then
    echo "issue body names the version, the commit and the links ... PASS"
else
    echo "issue body names the version, the commit and the links ... FAIL"
    cat "$WORK/created" 2>/dev/null
    FAILED=1
fi

run v0.9.0 "0.8.1
"
check "trailing newline in VERSION is ignored" 0 yes "Bump VERSION to 0.9.0"

run v0.10.0 0.9.0
check "numeric, not lexical, comparison" 0 yes "Bump VERSION to 0.10.0"

run v1.0.0 0.99.9
check "major bump" 0 yes "Bump VERSION to 1.0.0"

run v0.9.0 0.9.0-rc1
check "stable outranks a pre-release VERSION of the same core" 0 yes "Bump VERSION to 0.9.0"

run v0.9.0 0.9.0
check "VERSION already bumped" 0 no

run v0.8.2 0.9.0
check "hotfix below VERSION on main" 0 no

run v0.9.0-rc1 0.8.1
check "pre-release tag is skipped" 0 no

run v0.9.0 0.8.1 "Some other issue" "Bump VERSION to 0.9.0"
check "open issue with the same title is not duplicated" 0 no

run v0.9.0 0.8.1 "Bump VERSION to 0.9.0 please"
check "only an exact title counts as a duplicate" 0 yes "Bump VERSION to 0.9.0"

ASSETS="MeetingTranscriber-0.9.0.dmg.sha256
MeetingTranscriber-AppStore-0.9.0.dmg"
run v0.9.0 0.8.1
check "release without the DMG is not shipped" 0 no

FAIL="release-404"
run v0.9.0 0.8.1
check "release not created yet is not shipped" 0 no

CASK_VERSION="0.8.1"
run v0.9.0 0.8.1
check "Cask still on the old version is not shipped" 0 no

FAIL="main-version"
run v0.9.0 0.8.1
check "unreadable VERSION on main fails" 2 no

FAIL=release
run v0.9.0 0.8.1
check "unreadable release fails" 2 no

FAIL=cask
run v0.9.0 0.8.1
check "unreadable Cask fails" 2 no

FAIL=list
run v0.9.0 0.8.1
check "failed issue listing fails rather than filing blind" 2 no

FAIL=create
run v0.9.0 0.8.1
check "failed issue create fails" 2 no

run v0.9 0.8.1
check "malformed tag fails" 2 no

run v0.9.0 garbage
check "malformed VERSION fails" 2 no

run v0.9.0 ""
check "empty VERSION fails" 2 no

# The wiring in release.yml: the job runs after `build` even when a leg
# failed, only on a stable tag, with `issues: write`, a checkout that keeps no
# credentials, and calls this script with the token and repo it needs.
# shellcheck source=scripts/lib/ci-yaml.sh
source "$REPO_ROOT/scripts/lib/ci-yaml.sh"
wf="$REPO_ROOT/.github/workflows/release.yml"
want_if="\${{ !cancelled() && startsWith(github.ref, 'refs/tags/v') && !contains(github.ref_name, '-') }}"
job_if="$(ci_job_condition "$wf" version-bump-reminder)"
job_body="$(ci_job_body "$wf" version-bump-reminder)"
# shellcheck disable=SC2016  # the run line is matched literally
if [ "$job_if" = "$want_if" ] \
    && grep -qxF '    needs: build' <<< "$job_body" \
    && grep -qxF '      issues: write' <<< "$job_body" \
    && grep -qxF '          persist-credentials: false' <<< "$job_body" \
    && grep -qxF '          GH_TOKEN: ${{ github.token }}' <<< "$job_body" \
    && grep -qxF '          GH_REPO: ${{ github.repository }}' <<< "$job_body" \
    && grep -qxF '        run: ./scripts/ci/version-bump-reminder.sh "$GITHUB_REF_NAME"' <<< "$job_body"; then
    echo "release.yml wires the job ... PASS"
else
    echo "release.yml wires the job ... FAIL"
    echo "    if: $job_if"
    FAILED=1
fi

exit "$FAILED"
