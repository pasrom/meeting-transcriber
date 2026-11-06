#!/usr/bin/env bash
# Guards the analyze job against an analysis that quietly covers fewer files.
#
#   check-compiler-log-coverage.sh <xcodebuild.log> [<repo-root>]
#       Fails when the log lacks a compile entry for a Swift file this
#       repository builds itself.
#   check-compiler-log-coverage.sh --analyzed <swiftlint-output> [<repo-root>]
#       Fails when `swiftlint analyze` reports a different number of analysed
#       files than the repository has.
#
# Why this exists: `swiftlint analyze` finds a file's compiler arguments by
# searching the xcodebuild log for that file, and a file with no entry is
# skipped without a finding. The analyze job restores cached dependency build
# output, and a build that decides a module is up to date prints no compile
# entry for it. A stale cache would then drop whole modules from the analysis
# while the job stays green, the one failure a faster analyze must not have.
# These checks turn that silence into a red step.
#
# What counts as "built by this repository": every .swift file under the three
# directories the MeetingTranscriber scheme compiles from this checkout (the
# app, its tests, AudioTapLib). Dependencies are checked out elsewhere and are
# not analysed, so their entries may legitimately be absent. Swift files in
# other included directories (the simulator, mt-cli, AudioTapLib's own tests)
# are not part of this scheme, so swiftlint never analyses them either; the
# expected count would have to change together with the scheme.
#
# Exit codes: 0 consistent, 1 a file is missing or the count differs (listed on
# stderr), 2 usage error or an empty file list (a vacuous pass is not a pass).

set -euo pipefail

mode=log
if [[ "${1:-}" == "--analyzed" ]]; then
    mode=analyzed
    shift
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $(basename "$0") [--analyzed] <xcodebuild.log | swiftlint-output> [<repo-root>]" >&2
    exit 2
fi

input="$1"
root="${2:-$(cd "$(dirname "$0")/../.." && pwd -P)}"
root="$(cd "$root" && pwd -P)"

if [[ ! -s "$input" ]]; then
    echo "error: $input is missing or empty" >&2
    exit 2
fi

dirs=(
    app/MeetingTranscriber/Sources
    app/MeetingTranscriber/Tests
    tools/audiotap/Sources
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A directory that moved must fail here, not shrink the expected set quietly.
for d in "${dirs[@]}"; do
    if [[ ! -d "$root/$d" ]]; then
        echo "error: $root/$d does not exist" >&2
        exit 2
    fi
done
for d in "${dirs[@]}"; do
    find "$root/$d" -name '*.swift' -type f
done | LC_ALL=C sort -u > "$tmp/expected"

if [[ ! -s "$tmp/expected" ]]; then
    echo "error: no Swift files found under $root" >&2
    exit 2
fi
total=$(wc -l < "$tmp/expected" | tr -d ' ')

if [[ "$mode" == analyzed ]]; then
    # "Done analyzing! Found 0 violations, 0 serious in 678 files."
    analyzed=$(sed -nE 's/^Done analyzing! .* in ([0-9]+) files?\.$/\1/p' "$input" | tail -1)
    if [[ -z "$analyzed" ]]; then
        echo "::error title=Analysis summary missing::$input has no 'Done analyzing!' line, so the number of analysed files is unknown." >&2
        exit 1
    fi
    if [[ "$analyzed" -ne "$total" ]]; then
        echo "::error title=Analysis covered the wrong files::swiftlint analyzed $analyzed files, the repository builds $total. The expected count is every .swift file under the dirs array in this script; a path excluded in .swiftlint.yml, or a source directory the scheme gained or lost, changes one side of the comparison." >&2
        exit 1
    fi
    echo "swiftlint analyzed all $total Swift files"
    exit 0
fi

# Seen: the files xcodebuild reports compiling, one
# `SwiftCompile <variant> <arch> <absolute path> (in target ...)` line per input
# file and target. A path that only appears in a diagnostic or a timing line
# does not count, because those can come from a compile that did not cover it.
#
# awk with a literal prefix test, not a regex built from $root: a checkout path
# with a space, `|`, `(` or `+` must not change what matches. xcodebuild escapes
# a space in a path as backslash-space, which is undone before comparing with
# the `find` output.
ROOT_PREFIX="$root/" awk '
    /^SwiftCompile [a-z]+ [a-z0-9_]+ / {
        line = $0
        sub(/^SwiftCompile [a-z]+ [a-z0-9_]+ /, "", line)
        gsub(/\\ /, " ", line)
        if (index(line, ENVIRON["ROOT_PREFIX"]) != 1) next
        sub(/ \(in target .*$/, "", line)
        if (line !~ /\.swift$/) next
        print line
    }' "$input" | LC_ALL=C sort -u > "$tmp/seen"

LC_ALL=C comm -23 "$tmp/expected" "$tmp/seen" > "$tmp/missing"

if [[ -s "$tmp/missing" ]]; then
    n=$(wc -l < "$tmp/missing" | tr -d ' ')
    echo "::error title=Compiler log incomplete::$n of $total Swift files have no compile entry in $input, so swiftlint analyze would skip them silently. If a local target was added or renamed, update scripts/ci/prune-analyze-derived-data.sh." >&2
    while IFS= read -r path; do
        printf '  missing: %s\n' "${path#"$root"/}"
    done < "$tmp/missing" >&2
    exit 1
fi

echo "compiler log covers all $total Swift files under the analysed directories"
