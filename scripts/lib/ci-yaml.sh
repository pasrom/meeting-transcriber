# Shared reading of GitHub workflow YAML for the shell tests under
# scripts/tests/. Source this from a bash script that has already set
# `set -euo pipefail`:
#
#   source "$ROOT/scripts/lib/ci-yaml.sh"
#   cond="$(ci_job_condition .github/workflows/ci.yml lint)"
#   body="$(ci_job_body .github/workflows/ci.yml test)"
#
# This file has no shebang and no `set -e` — it inherits the caller's.
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
        $0 == "  " want ":" { printf "%s", block; exit }
        /^[[:space:]]*#/ { block = block $0 "\n"; next }
        { block = "" }
    ' "$1"
}

# The `if:` of the step named $3 inside job $2 of file $1, or the empty string
# when the step has none. A step key sits at six spaces, its `if:` at eight.
ci_step_condition() {
    ci_job_body "$1" "$2" | awk -v want="$3" '
        /^      - name:[[:space:]]*/ {
            n = $0; sub(/^      - name:[[:space:]]*/, "", n)
            here = (n == want); next
        }
        /^      - / { here = 0; next }
        here && /^        if:/ && cond == "" {
            cond = $0; sub(/^[[:space:]]*if:[[:space:]]*/, "", cond)
        }
        END { print cond }
    '
}
