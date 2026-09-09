#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted Markdown backticks and an awk `$1` are meant literally
# Per-body type-check timings from an xcodebuild log: which function bodies come
# closest to the limit that app/MeetingTranscriber/Package.swift enforces with
# `-warn-long-function-bodies`.
#
# Why this exists: that flag reports a body only once it is already over the
# limit, and warnings are errors in those targets, so the first signal that a
# body is close is a red build on a commit that changed nothing near it. Adding
# `-Xfrontend -debug-time-function-bodies` to the same compile makes the
# compiler print one line per type-checked body:
#
#   151.67ms<TAB>/abs/path/AppState.swift:213:5<TAB>initializer Module.(file).AppState.init(settings:)@/abs/path/AppState.swift:213:5
#
# The analyze lane in .github/workflows/ci.yml adds that flag through
# OTHER_SWIFT_FLAGS and feeds its log here. This report never gates anything:
# the limit itself stays the only enforcement, and this only makes the margin
# to it visible before it is gone.
#
# Usage:
#   type-check-timings.sh report <xcodebuild.log> [--root <dir>] [--limit <n>]
#       Writes a Markdown report to stdout and, when $GITHUB_STEP_SUMMARY is
#       set, appends it there too. Only bodies in files under <root> count
#       (default: the repository this script lives in), which drops
#       dependencies, macro expansion buffers and synthesized declarations
#       that carry no file. A body measured by several compiler jobs is listed
#       once with its slowest measurement, since the gate fires on any single
#       one. Ordered by time, then by location, so two runs with the same
#       numbers render the same table. The limit is reported per module, read
#       from that module's own compile commands in the log, and a module with
#       bodies under <root> but no limit on its commands is named as ungated.
#       Exit 0 with a table. Exit 1 when the log holds no timings under
#       <root>: the report then says so in place of the table, so an empty
#       result cannot read as "nothing is close to the limit". Exit 2 on
#       usage errors.
#   type-check-timings.sh strip
#       stdin to stdout, minus the timing lines. Used on the console stream of
#       the build, which otherwise gains some 33,000 of them, and on the output
#       of `swiftlint analyze`, which re-runs the compiler with the arguments
#       it finds in the log, timing flag included, so SourceKit prints the same
#       lines again. Always exits 0 on a readable stream.
#
# Reproduce the CI report locally (the same build the analyze lane runs):
#   cd app/MeetingTranscriber
#   xcodebuild -scheme MeetingTranscriber -destination 'platform=macOS' \
#     SWIFT_SUPPRESS_WARNINGS=NO \
#     OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -debug-time-function-bodies' \
#     build-for-testing 2>&1 | tee /tmp/xcodebuild.log | ../../scripts/ci/type-check-timings.sh strip
#   ../../scripts/ci/type-check-timings.sh report /tmp/xcodebuild.log

set -uo pipefail

# One predicate for both modes, so the lines the report parses and the lines
# `strip` removes can never drift apart: a format change makes the report say
# it found nothing while the console shows the new lines, both at once.
timing_line='$1 ~ /^[0-9]+\.[0-9]+ms$/ && NF >= 3'

usage() {
    echo "usage: $(basename "$0") report <xcodebuild.log> [--root <dir>] [--limit <n>]" >&2
    echo "       $(basename "$0") strip < build-output" >&2
    exit 2
}

mode="${1:-}"
case "$mode" in
    strip)
        [ $# -eq 1 ] || usage
        exec awk -F '\t' "!($timing_line)"
        ;;
    report) ;;
    *) usage ;;
esac
shift

log="${1:-}"
[ -n "$log" ] || usage
shift
root="$(cd "$(dirname "$0")/../.." && pwd)"
limit=10
while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            [ $# -ge 2 ] || usage
            root="$2"
            shift 2
            ;;
        --limit)
            [ $# -ge 2 ] || usage
            case "$2" in
                '' | *[!0-9]*) usage ;;
            esac
            limit="$2"
            shift 2
            ;;
        *) usage ;;
    esac
done
if [ ! -r "$log" ]; then
    echo "$(basename "$0"): cannot read log '$log'" >&2
    exit 2
fi
root="${root%/}"

rows="$(mktemp)"
counts="$(mktemp)"
gates="$(mktemp)"
report="$(mktemp)"
trap 'rm -f -- "$rows" "$counts" "$gates" "$report"' EXIT

# Pass 1: one row per location under root, keeping the slowest measurement,
# with the module that owns the body (from the Module.(file). prefix of the
# declaration reference) so the limit can be attributed per module below.
# Counts go to a second file so the report can name what it skipped.
awk -F '\t' -v root="$root/" -v counts="$counts" "
$timing_line {
    total++
    if (index(\$2, root) != 1) next
    under++
    ms = substr(\$1, 1, length(\$1) - 2) + 0
    if (!(\$2 in best) || ms > best[\$2]) {
        best[\$2] = ms
        decl[\$2] = \$3
        mod[\$2] = match(\$3, /[A-Za-z_0-9]+\\.\\(file\\)\\./) ? substr(\$3, RSTART, RLENGTH - 8) : \"\"
    }
}
END {
    for (loc in best) printf \"%.2f\t%s\t%s\t%s\n\", best[loc], loc, decl[loc], mod[loc]
    printf \"%d %d\n\", total + 0, under + 0 > counts
}" "$log" > "$rows"
read -r total under < "$counts"

# Pass 2: the gate per module, read from the compile commands in the same log
# rather than from Package.swift, so the report describes the flags each
# target actually ran under. Every package in this repository sets its own
# -warn-long-function-bodies, so one flag found anywhere in the log says
# nothing about the module a body belongs to: with the app package's gate
# gone, the local audiotap package would still supply a "300". xcodebuild
# prints the command shell-escaped, hence the optional backslash before the
# equals sign. When one command line carries the flag more than once the
# compiler applies the last (checked on Xcode 26.6: =100000 followed by =1
# warns at 1 ms), so the last value on the line is the one taken.
awk '
    match($0, /-module-name [^ ]+/) {
        module = substr($0, RSTART + 13, RLENGTH - 13)
        value = ""
        rest = $0
        while (match(rest, /-warn-long-function-bodies\\?=[0-9]+/)) {
            value = substr(rest, RSTART, RLENGTH)
            sub(/.*=/, "", value)
            rest = substr(rest, RSTART + RLENGTH)
        }
        if (value != "") print module "\t" value
    }' "$log" | LC_ALL=C sort -u > "$gates"

# gate_field <key>: one entry of the per-module gate summary computed below.
gate_field() {
    printf '%s\n' "$gate_summary" | awk -F '\t' -v k="$1" '$1 == k { print substr($0, length(k) + 2) }'
}

{
    echo "### Type-check timings (analyze build)"
    echo
    if [ "$under" -eq 0 ]; then
        echo "**No type-check timings were found under \`$root\`.**"
        echo
        if [ "$total" -eq 0 ]; then
            echo "The log has no lines of the form \`12.34ms<TAB>/path/File.swift:1:2<TAB>declaration\`, which \`-Xfrontend -debug-time-function-bodies\` prints for every type-checked body. Either the flag no longer reaches the compiler or the compiler changed the format."
        else
            echo "The log has $total such lines, none of them for a file under that root. Either the root is wrong or the flag reached only dependency targets."
        fi
        echo
        echo "Nothing is known about the margin to the type-check limit from this run."
    else
        if ! grep -qE '^\*\* (TEST )?BUILD SUCCEEDED \*\*' "$log"; then
            echo "The build did not report success, so these timings cover only the bodies checked before it stopped."
            echo
        fi
        bodies="$(wc -l < "$rows" | tr -d ' ')"
        slowest_row="$(LC_ALL=C sort -t "$(printf '\t')" -k1,1gr -k2,2 "$rows" | head -n 1)"
        slowest="$(printf '%s' "$slowest_row" | cut -f 1)"
        slowest_module="$(printf '%s' "$slowest_row" | cut -f 4)"
        # The modules with bodies under root, each with the limit its compile
        # commands carried: one value, several (conflicting), or none.
        gate_summary="$(awk -F '\t' -v gates="$gates" -v slowest_module="$slowest_module" '
            FILENAME == gates {
                if (!($1 in limit)) limit[$1] = $2
                else if (index("|" limit[$1] "|", "|" $2 "|") == 0) limit[$1] = limit[$1] "|" $2
                next
            }
            $4 != "" && !($4 in seen) { seen[$4] = 1; modules[++n] = $4 }
            END {
                for (i = 2; i <= n; i++) {
                    v = modules[i]
                    for (j = i - 1; j >= 1 && modules[j] > v; j--) modules[j + 1] = modules[j]
                    modules[j + 1] = v
                }
                for (i = 1; i <= n; i++) {
                    m = modules[i]
                    if (!(m in limit)) ungated = ungated (ungated == "" ? "" : ", ") m
                    else if (index(limit[m], "|")) {
                        c = limit[m]; gsub(/\|/, " and ", c)
                        conflicting = conflicting (conflicting == "" ? "" : ", ") m " (" c " ms)"
                    } else gated = gated (gated == "" ? "" : ", ") m " " limit[m] " ms"
                }
                print "gated\t" gated
                print "ungated\t" ungated
                print "conflicting\t" conflicting
                if ((slowest_module in limit) && !index(limit[slowest_module], "|")) print "slowest_limit\t" limit[slowest_module]
            }' "$gates" "$rows")"
        gated="$(gate_field gated)"
        ungated="$(gate_field ungated)"
        conflicting="$(gate_field conflicting)"
        slowest_limit="$(gate_field slowest_limit)"
        shown="$limit"
        [ "$bodies" -lt "$shown" ] && shown="$bodies"
        printf 'The %s slowest of %s function bodies in this repository, out of %s timings (the other %s are dependencies, macro expansions and declarations without a source location, all skipped). ' \
            "$shown" "$bodies" "$total" "$((total - under))"
        if [ -n "$gated" ]; then
            printf 'Limit (`-warn-long-function-bodies`, read from each module'"'"'s compile commands): %s. ' "$gated"
        fi
        if [ -n "$conflicting" ]; then
            printf '**Conflicting limits on the compile commands of %s.** ' "$conflicting"
        fi
        if [ -n "$ungated" ]; then
            printf '**No `-warn-long-function-bodies` limit on any compile command of %s**, so those bodies ran without the type-check gate. ' "$ungated"
        fi
        if [ -z "$gated$conflicting$ungated" ]; then
            printf 'No body under the root names its module, so the limit could not be attributed. '
        fi
        if [ -n "$slowest_limit" ]; then
            headroom="$(awk -v g="$slowest_limit" -v s="$slowest" 'BEGIN { printf "%.0f", g - s }')"
            printf 'The slowest body leaves %s ms of headroom to the limit of its module. ' "$headroom"
        fi
        echo "Times are from one run on a shared runner and vary by tens of milliseconds between runs. Non-gating: the limit is the only enforcement."
        echo
        echo "| ms | Location | Declaration |"
        echo "|---:|---|---|"
        LC_ALL=C sort -t "$(printf '\t')" -k1,1gr -k2,2 "$rows" | head -n "$limit" \
            | awk -F '\t' -v root="$root/" '
                {
                    loc = substr($2, length(root) + 1)
                    sub(/:[0-9]+$/, "", loc)               # column adds nothing a reader acts on
                    decl = $3
                    sub(/@[^@]*$/, "", decl)                # trailing @/path:line:col repeats the location
                    sub(/[A-Za-z_0-9]+\.\(file\)\./, "", decl)   # Module.(file). prefix
                    sub(/\.(getter|setter|didSet observer|willSet observer)$/, "", decl)   # repeats the leading kind word
                    gsub(/\|/, "\\|", decl)                 # keep the Markdown table intact
                    gsub(/`/, "\047", decl)
                    printf "| %s | `%s` | `%s` |\n", $1, loc, decl
                }'
    fi
    echo
} > "$report"

cat "$report"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$report" >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$under" -eq 0 ]; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning title=Type-check timings missing::The analyze build produced no per-body type-check timings under $root, so the margin to the type-check limit is unknown for this run. See the step summary."
    fi
    exit 1
fi
exit 0
