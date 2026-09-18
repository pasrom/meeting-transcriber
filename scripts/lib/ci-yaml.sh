# Shared reading of GitHub workflow YAML for the shell tests under
# scripts/tests/. Source this from a bash script that has already set
# `set -euo pipefail`:
#
#   source "$ROOT/scripts/lib/ci-yaml.sh"
#   cond="$(ci_job_condition .github/workflows/ci.yml lint)"
#   body="$(ci_job_body .github/workflows/ci.yml test)"
#
# This file has no shebang and no `set -e`; it inherits the caller's.
#
# Text, not a YAML parser, on purpose: these run in the `lint` job on a fresh
# macOS runner where PyYAML is not guaranteed, and the contract for
# scripts/tests/ is self-contained and about a second. That means BSD awk and
# bash 3.2 only, so no GNU extensions such as `\<` word boundaries.
#
# The two tests that read workflows used to carry their own copies of the rule
# below that decides which job a line belongs to. They had already drifted once
# in spirit: one of them had to be hardened for `needs: [changes]` and for a
# trailing comment, and a second copy would not have been hardened with it.

# Which job each line belongs to. Spliced into the awk programs below rather
# than repeated in each of them.
CI_YAML_JOB_TRACK='
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); inneeds = 0; next }
    /^[^[:space:]]/ { job = ""; inneeds = 0; next }
'

# The JOB-level `if:` of job $2 in file $1, or the empty string. Four spaces
# exactly: a step's keys are deeper, and matching any indentation reads a
# step's condition as the job's, which is a real hazard wherever the expected
# value is something a step would plausibly carry, such as `always()`.
ci_job_condition() {
    awk -v want="$2" "$CI_YAML_JOB_TRACK"'
        job == want && /^    if:/ && cond == "" {
            cond = $0; sub(/^[[:space:]]*if:[[:space:]]*/, "", cond)
        }
        END { print cond }
    ' "$1"
}

# The body of job $2 in file $1 with comment lines removed. Both halves matter:
# a check that searches the whole file is satisfied by text belonging to another
# job, and one that keeps comments is satisfied by a note describing what the
# job used to do.
ci_job_body() {
    awk -v want="$2" "$CI_YAML_JOB_TRACK"'
        job == want && $0 !~ /^[[:space:]]*#/ { print }
    ' "$1"
}

# Every job in $1 that declares a dependency on job $2, in any spelling: the
# bare scalar, the `[x]` list form, the block sequence, and any of those with a
# trailing comment.
ci_jobs_depending_on() {
    awk -v dep="$2" "$CI_YAML_JOB_TRACK"'
        $0 ~ "^[[:space:]]*needs:[^#]*" dep && job != "" { print job; inneeds = 0; next }
        /^[[:space:]]*needs:[[:space:]]*(#.*)?$/ && job != "" { inneeds = 1; next }
        inneeds && $0 ~ "^[[:space:]]*-[[:space:]]*" dep "[[:space:]]*(#.*)?$" && job != "" { print job; next }
        inneeds && $0 !~ /^[[:space:]]*-/ { inneeds = 0 }
    ' "$1" | sort -u
}

# The contiguous run of comment lines immediately above job $2's key in $1.
# Anchored there because that block is what other jobs point a reader to; a
# comment elsewhere in the file saying the right thing does not make it correct.
ci_job_comment() {
    awk -v want="$2" '
        $0 ~ "^  " want ":[[:space:]]*$" { printf "%s", block; exit }
        /^[[:space:]]*#/ { block = block $0 "\n"; next }
        { block = "" }
    ' "$1"
}

# The `if:` of the step in job $2 of file $1 whose `run:` STARTS a line with
# the literal $3, printed as the condition, or `__NO_CONDITION__` when such a
# step exists and carries none, or nothing at all when none does.
#
# Anchored on the command, and inside the step's `run:` value rather than
# anywhere in its text. Both halves were measured. A `name:` is not an anchor:
# it can be renamed, quoted, ordered after `if:`, omitted, or worn by a second
# step. And "somewhere in the step" is not an anchor either: a step whose `run:`
# was `echo "skipping cd tools/mt-cli && swift test until the flake is fixed"`,
# one that had the command demoted to a trailing shell comment, and a decoy
# whose `name:` merely quoted it all satisfied it while the real step ran
# nowhere.
#
# An empty result also has to stop meaning two things. "No condition" and "no
# such step" were both the empty string, and a caller reading the first as
# harmless reported a step renamed away AND gated to a leg that does not exist
# as fine.
#
# KNOWN LIMIT, deliberate: a command split across a `run: |` block is not found,
# and the first matching step wins if two run the same command. The caller is
# expected to fail closed and say so rather than guess.
ci_step_condition_for_run() {
    ci_job_body "$1" "$2" | awk -v want="$3" '
        function flush() {
            if (runbuf ~ want_re) {
                print (cond == "" ? "__NO_CONDITION__" : cond)
                found = 1
            }
        }
        BEGIN {
            want_re = want; gsub(/[][(){}.*+?^$\\|]/, "\\\\&", want_re)
            want_re = "(^|\n)[[:space:]]*" want_re
        }
        # A step begins on a dash line, and its first key sits ON that line, so
        # `- if:` and `- run:` are keys like any other.
        /^      - / {
            if (!found) flush()
            runbuf = ""; cond = ""; inrun = 0
            if ($0 ~ /^      -[[:space:]]+if:/) {
                cond = $0; sub(/^[[:space:]]*-[[:space:]]*if:[[:space:]]*/, "", cond)
            }
            if ($0 ~ /^      -[[:space:]]+run:/) {
                v = $0; sub(/^[[:space:]]*-[[:space:]]*run:[[:space:]]*/, "", v)
                runbuf = v "\n"; inrun = 1
            }
            next
        }
        /^        if:/ && cond == "" {
            cond = $0; sub(/^[[:space:]]*if:[[:space:]]*/, "", cond)
        }
        /^        run:/ {
            v = $0; sub(/^[[:space:]]*run:[[:space:]]*/, "", v)
            runbuf = runbuf v "\n"; inrun = 1; next
        }
        /^        [A-Za-z_-]+:/ { inrun = 0 }
        inrun { v = $0; sub(/^[[:space:]]+/, "", v); runbuf = runbuf v "\n" }
        END { if (!found) flush() }
    '
}

# Whether job $2 of file $1 has steps at the indentation the reader above
# assumes. Four-space steps are valid YAML and are what some formatters emit;
# with them the reader sees no step boundary at all, every condition reads as
# absent, and a step gated to a leg that does not exist reported as fine.
# Measured. The caller uses this to fail with the real reason instead.
ci_job_has_readable_steps() {
    ci_job_body "$1" "$2" | grep -q '^      - '
}

# Every value of matrix key $3 in job $2 of file $1, one per line, for both the
# flow form (`variant: [a, b]`) and the block form (`variant:` then `- a`).
# Returning values instead of a regex to grep the job body with is what lets the
# caller compare whole strings: a leg containing a `.` matched any character,
# and a leg containing a `+` made grep error out and the caller blame the
# matrix. NOT read, and the caller's message has to allow for it: a flow list
# broken across several lines, and a leg contributed only through `include:`. Quotes are stripped here, not by the caller.
ci_matrix_values() {
    ci_job_body "$1" "$2" | awk -v key="$3" '
        $0 ~ "^[[:space:]]*" key ":[[:space:]]*\\[" {
            line = $0; sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
            n = split(line, a, ",")
            for (i = 1; i <= n; i++) {
                v = a[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                if (v != "") print v
            }
            inblock = 0; next
        }
        $0 ~ "^[[:space:]]*" key ":[[:space:]]*(#.*)?$" { inblock = 1; next }
        inblock && /^[[:space:]]*-[[:space:]]*/ {
            v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*$/, "", v); gsub(/[[:space:]]+$/, "", v)
            if (v != "") print v
            next
        }
        inblock && $0 !~ /^[[:space:]]*-/ { inblock = 0 }
    ' | tr -d "\"'"
}

