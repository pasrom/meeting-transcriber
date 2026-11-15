#!/bin/bash
# Regression test: a Dependabot PR does not start a job on the self-hosted
# runners on its own.
#
# The reasoning lives where the conditions sit: the `hold` step of the
# `changes` job in quality-and-safety.yml, and the comment above the `if:` of
# each label-gated E2E lane. In short: Dependabot opens its PRs
# as same-repo branches, so the fork exclusion lets them through, and the
# dependency code they bring would be built and run on a Mini before anyone
# read it.
#
# What is specific to this test, and the reason it looks the way it does:
#
# Where the decision is shell, the shell is EXECUTED, not grepped. The `hold`
# step and the sanitizer gate are extracted from the workflow and run with the
# environment each case would give them, so the cases below are the behaviour
# of the committed script and not of a copy that could drift. What cannot be
# executed here is a `${{ }}` expression: GitHub evaluates those, and nothing
# in this repo does. Those are pinned byte for byte instead, which refuses the
# near miss that token matching lets through (`user.login == 'dependabot[bot]'`
# contains every token of the guard and inverts it).
#
# No EXIT trap: without one an abort of this file exits non-zero, so it needs
# no completion sentinel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/ci-yaml.sh
source "$ROOT/scripts/lib/ci-yaml.sh"
PASSED=0
FAILED=0

ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; FAILED=1; }

qs="$ROOT/.github/workflows/quality-and-safety.yml"
TMP="$(mktemp -d)"

# --- the hold decision, executed --------------------------------------------

hold_script="$(ci_step_run_block "$qs" changes "id: hold")"
if [ -z "$hold_script" ]; then
    bad "quality-and-safety.yml:changes" "has no step \`id: hold\` with a \`run: |\` block, so nothing decides whether a Dependabot PR may start the self-hosted legs. If it was renamed, rename it here too."
fi

# run_hold <event> <author> <triggering actor> <labelled> -> prints the
# `self-hosted` output the step writes.
run_hold() {
    : > "$TMP/out"; : > "$TMP/summary"
    EVENT="$1" AUTHOR="$2" TRIGGERED_BY="$3" LABELLED="$4" \
        GITHUB_OUTPUT="$TMP/out" GITHUB_STEP_SUMMARY="$TMP/summary" \
        bash -c "set -euo pipefail; $hold_script" > /dev/null
    sed -n 's/^self-hosted=//p' "$TMP/out"
}

# case <name> <expected> <event> <author> <triggering actor> <labelled>
hold_case() {
    local name="$1" want="$2" got
    shift 2
    got="$(run_hold "$@")"
    if [ "$got" = "$want" ]; then
        ok "hold:$name"
    else
        bad "hold:$name" "self-hosted=$got, expected $want (event=$1 author=$2 triggering_actor=$3 labelled=$4)"
    fi
}

if [ -n "$hold_script" ]; then
    bot='dependabot[bot]'
    # The point of the change: Dependabot's own events start nothing.
    hold_case "dependabot PR opened, no label"            false pull_request "$bot" "$bot" false
    # A maintainer's label releases it.
    hold_case "dependabot PR labelled by a maintainer"    true  pull_request "$bot" maintainer true
    # A label is not a standing approval: Dependabot pushing to the labelled
    # branch afterwards (a rebase, a newer version) is held again ...
    hold_case "dependabot push after the label"           false pull_request "$bot" "$bot" true
    # ... until a maintainer re-runs that run, which carries the label.
    hold_case "maintainer re-runs a labelled run"         true  pull_request "$bot" maintainer true
    # Re-running a run from before the label is no visible approval.
    hold_case "maintainer re-runs an unlabelled run"      false pull_request "$bot" maintainer false
    # Keyed on the author: a person's commit on a Dependabot branch is held
    # too until labelled, and Dependabot applying the label itself (if a
    # dependabot.yml ever listed it) releases nothing.
    hold_case "person pushes to a dependabot branch"      false pull_request "$bot" maintainer false
    hold_case "dependabot applies run-quality itself"     false pull_request "$bot" "$bot" true
    # Human PRs and every non-PR event are unchanged.
    hold_case "human PR, no label"                        true  pull_request contributor contributor false
    hold_case "human PR, labelled"                        true  pull_request contributor contributor true
    hold_case "push to main"                              true  push         ""   "$bot" false
    hold_case "nightly"                                   true  schedule     ""   "$bot" false
    hold_case "dispatch"                                  true  workflow_dispatch "" maintainer false
fi

# --- what GitHub evaluates, pinned byte for byte -----------------------------

# The step's inputs. A wrong context here (`github.actor`, which stays the bot
# on a re-run; the label test against another label) changes the decision the
# executed cases above cannot see, since they set these values themselves.
hold_env="$(ci_job_body "$qs" changes | awk '
    /^      - / { instep = ($0 ~ /^      - id: hold[[:space:]]*$/); next }
    instep && /^          [A-Z_]+: / { sub(/^          /, ""); print }
')"
expected_env="EVENT: \${{ github.event_name }}
AUTHOR: \${{ github.event.pull_request.user.login }}
TRIGGERED_BY: \${{ github.triggering_actor }}
LABELLED: \${{ contains(github.event.pull_request.labels.*.name, 'run-quality') }}"
if [ "$hold_env" = "$expected_env" ]; then
    ok "quality-and-safety.yml:hold reads author, triggering actor and the run-quality label"
else
    bad "quality-and-safety.yml:hold" "its env is not the one the cases above assume.
    expected:
$expected_env
    actual:
$hold_env"
fi

if ci_job_body "$qs" changes | grep -qxF "      self-hosted: \${{ steps.hold.outputs.self-hosted }}"; then
    ok "quality-and-safety.yml:changes exports the hold as \`self-hosted\`"
else
    bad "quality-and-safety.yml:changes" "does not export \`self-hosted\` from the \`hold\` step, so the legs read an empty value."
fi

# Both legs require exactly `true`, inside the pull_request arm. `!= 'false'`
# would release them whenever the output is missing.
for leg in test-asan test-tsan; do
    arm="$(ci_job_condition_text "$qs" "$leg" | awk '/^  github.event_name == .pull_request. &&$/ { inarm = 1 } inarm')"
    if printf '%s\n' "$arm" | grep -qxF "  needs.changes.outputs.self-hosted == 'true' &&"; then
        ok "quality-and-safety.yml:$leg is held for an unreleased Dependabot PR"
    else
        bad "quality-and-safety.yml:$leg" "its pull_request arm does not require \`needs.changes.outputs.self-hosted == 'true'\`, so a Dependabot PR starts it on a self-hosted runner unreviewed."
    fi
done

if ci_job_body "$qs" sanitizer-gate | grep -qxF "          SELF_HOSTED: \${{ needs.changes.outputs.self-hosted }}"; then
    ok "quality-and-safety.yml:sanitizer-gate reads the hold"
else
    bad "quality-and-safety.yml:sanitizer-gate" "does not read \`needs.changes.outputs.self-hosted\`, so the cases below test an input the gate never gets."
fi

# --- the gate, executed --------------------------------------------------------

gate_script="$(ci_step_run_block "$qs" sanitizer-gate "name: Report which legs ran and fail unless the ones that ran passed")"
if [ -z "$gate_script" ]; then
    bad "quality-and-safety.yml:sanitizer-gate" "its report step was not found under its name; rename it here too."
fi

# gate_case <name> <expected exit> <summary must contain> then VAR=value pairs.
# Every input not named gets the value of an ordinary same-repo PR run.
gate_case() {
    local name="$1" want="$2" needle="$3" rc=0
    shift 3
    : > "$TMP/summary"
    env -i PATH="$PATH" GITHUB_STEP_SUMMARY="$TMP/summary" \
        VERDICT=true EVENT=pull_request SAME_REPO=true LABELLED=false \
        DISPATCH_SANITIZER= CHANGES_RESULT=success \
        ASAN_RESULT=success TSAN_RESULT=skipped ASAN_TESTS=success TSAN_TESTS= \
        TSAN_RELEVANT=false TSAN_REASON= SELF_HOSTED=true \
        "$@" bash -c "set -euo pipefail; $gate_script" > /dev/null 2>&1 || rc=$?
    if [ "$want" = 0 ] && [ "$rc" -ne 0 ]; then
        bad "gate:$name" "exited $rc, expected success"
    elif [ "$want" != 0 ] && [ "$rc" -eq 0 ]; then
        bad "gate:$name" "exited 0, expected a failure"
    elif [ -n "$needle" ] && ! grep -qF "$needle" "$TMP/summary"; then
        bad "gate:$name" "summary lacks \"$needle\""
    else
        ok "gate:$name"
    fi
}

if [ -n "$gate_script" ]; then
    held="Dependabot PR: held off the self-hosted runners"
    # A held PR is green, not red for the skip, and says why both legs did not run.
    gate_case "held dependabot PR is green and says so" 0 "| ASan | not run: $held" \
        SELF_HOSTED=false ASAN_RESULT=skipped ASAN_TESTS= TSAN_RELEVANT=true \
        TSAN_REASON="package manifest or sanitizer workflow changed: app/MeetingTranscriber/Package.resolved"
    gate_case "held dependabot PR names TSan as held too" 0 "| TSan | not run: $held" \
        SELF_HOSTED=false ASAN_RESULT=skipped ASAN_TESTS= LABELLED=false
    # Released by the label: both legs are expected and their verdict counts.
    gate_case "released dependabot PR, both legs pass" 0 "passed (run-quality label" \
        LABELLED=true TSAN_RESULT=success TSAN_TESTS=success
    gate_case "released dependabot PR, ASan fails" 1 "FAILED: the sanitizer tests failed" \
        LABELLED=true ASAN_RESULT=failure ASAN_TESTS=failure TSAN_RESULT=success TSAN_TESTS=success
    # A missing or garbled hold output must not read as a hold: the legs need
    # the literal `true`, skip, and the gate goes red.
    gate_case "missing hold output with skipped legs is red" 1 "SKIPPED although this event should have run it" \
        SELF_HOSTED= ASAN_RESULT=skipped ASAN_TESTS=
    # The hold is a pull_request matter only: a push run on main, which is
    # what a stable tag points at, still fails when a leg is skipped,
    # whatever the hold output says.
    gate_case "push run with a skipped leg is red" 1 "SKIPPED although this event should have run it" \
        EVENT=push SAME_REPO=false SELF_HOSTED=false TSAN_RESULT=skipped
    gate_case "push run with both legs passing is green" 0 "passed (asked unconditionally on push)" \
        EVENT=push SAME_REPO=false TSAN_RESULT=success TSAN_TESTS=success
    # A human PR is unchanged: ASan expected, so its skip is red.
    gate_case "human PR with ASan skipped is red" 1 "SKIPPED although this event should have run it" \
        ASAN_RESULT=skipped ASAN_TESTS=
fi

# The trigger list must carry `labeled`, or applying run-quality to an
# already-open Dependabot PR starts no run and the hold is never released.
if awk '/^  pull_request:/ { p = 1; next } p && /^  [a-z]/ { p = 0 } p && /types:/' "$qs" \
    | grep -qE 'types:.*[[ ,]labeled[],]'; then
    ok "quality-and-safety.yml:pull_request triggers on labeled"
else
    bad "quality-and-safety.yml" "its pull_request trigger no longer lists \`labeled\`, so the run-quality label cannot release a held Dependabot PR."
fi

# --- every self-hosted job a PR can reach ------------------------------------

# Jobs on a self-hosted runner in a workflow a PR event can start, as
# `<workflow file>:<job>`. Discovered, then compared with the written list
# below in both directions: a new job is unreviewed until it is listed with
# its guard, and a listed job that vanished from discovery (renamed, moved to
# another runner spelling) is a failure rather than a silent pass.
self_hosted_pr_jobs() {
    local file="$1"
    awk '
        /^on:/ { inon = 1 }
        /^on:.*(pull_request|workflow_run)/ { pr = 1 }
        inon && /^  (pull_request|pull_request_target|workflow_run):/ { pr = 1 }
        /^[^[:space:]#]/ && !/^on:/ { inon = 0 }
        END { exit pr ? 0 : 1 }
    ' "$file" || return 0
    awk "$CI_YAML_JOB_TRACK"'
        $0 ~ /^[[:space:]]*#/ { next }
        job != "" && /^    runs-on:/ { inruns = 1; if ($0 ~ /self-hosted/) print job; next }
        inruns && /^      - / { if ($0 ~ /self-hosted/) print job; next }
        { inruns = 0 }
    ' "$file" | sort -u | sed "s|^|${file##*/}:|"
}

# Control: the discovery sees a self-hosted PR job, in either runs-on
# spelling, and ignores the same job when no PR event can start it.
cat > "$TMP/probe.yml" <<'YAML'
on:
  pull_request:
jobs:
  inline:
    runs-on: [self-hosted, macOS]
  listed:
    runs-on:
      - self-hosted
  hosted:
    runs-on: ubuntu-latest
YAML
probe_pr="$(self_hosted_pr_jobs "$TMP/probe.yml" | tr '\n' ' ')"
sed 's/^  pull_request:$/  push:/' "$TMP/probe.yml" > "$TMP/probe-push.yml"
probe_push="$(self_hosted_pr_jobs "$TMP/probe-push.yml")"
if [ "$probe_pr" = "probe.yml:inline probe.yml:listed " ] && [ -z "$probe_push" ]; then
    ok "discovery_control"
else
    bad "discovery_control" "pr='$probe_pr' push='$probe_push'"
fi
rm -f "$TMP/probe.yml" "$TMP/probe-push.yml"

SELF_HOSTED_PR_JOBS="e2e-app.yml:e2e-app
e2e-browser.yml:e2e-browser
e2e-channel-fault.yml:e2e-channel-fault
e2e-crash-recovery.yml:e2e-crash-recovery
e2e.yml:e2e
quality-and-safety.yml:test-asan
quality-and-safety.yml:test-tsan"

found=""
for wf in "$ROOT"/.github/workflows/*.yml; do
    found="$found$(self_hosted_pr_jobs "$wf")
"
done
found="$(printf '%s' "$found" | sed '/^$/d' | sort)"
if [ "$found" = "$SELF_HOSTED_PR_JOBS" ]; then
    ok "self-hosted PR jobs are the reviewed list"
else
    bad "self-hosted PR jobs" "a PR event can reach a self-hosted job this test does not guard, or a guarded one moved. Give a new job the Dependabot guard and list it here.
    listed:
$SELF_HOSTED_PR_JOBS
    found:
$found"
fi

# The label-gated E2E lanes. A person applies `run-e2e`, but without the
# actor clause the label would release every later Dependabot push to the
# branch. All five carry the identical condition, so it is compared whole.
expected_e2e="github.event_name != 'pull_request' ||
(
  contains(github.event.pull_request.labels.*.name, 'run-e2e') &&
  github.event.pull_request.head.repo.full_name == github.repository &&
  (github.event.pull_request.user.login != 'dependabot[bot]' || github.triggering_actor != 'dependabot[bot]') &&
  (github.event.action != 'labeled' || github.event.label.name == 'run-e2e')
)"
for entry in $SELF_HOSTED_PR_JOBS; do
    wf="${entry%%:*}"; job="${entry#*:}"
    case "$wf" in quality-and-safety.yml) continue ;; esac
    cond="$(ci_job_condition_text "$ROOT/.github/workflows/$wf" "$job")"
    if [ "$cond" = "$expected_e2e" ]; then
        ok "$wf:$job is held for a Dependabot push"
    else
        bad "$wf:$job" "its condition is not the guarded one, so a Dependabot push to a labelled branch starts it on a self-hosted runner.
    expected:
$expected_e2e
    actual:
$cond"
    fi
done

rm -f "$TMP/out" "$TMP/summary"
rmdir "$TMP"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "$PASSED checks passed"
else
    echo "Some checks FAILED."
fi
exit "$FAILED"
