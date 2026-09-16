#!/usr/bin/env bash
# Regression test for the signing record beside the deployed bundle
# (`record_deployed_signing_leaf` / `assert_deployed_signing_leaf`).
#
# Why it exists: the e2e lanes share one bundle at one TCC-granted path. The
# lane that builds signs it; every `--no-build` lane inherits it, and with it
# the certificate the grants are keyed on. `scripts/e2e-silent-recording.sh` is
# the lane that cannot survive getting that wrong, because its PASS condition is
# silence on both tracks: a bundle TCC will not grant capture to delivers zeroes
# from its first buffer with no error anywhere, so a denied run and a working
# watchdog are indistinguishable from inside the lane.
#
# The expectation cannot be recomputed on the spot. DEVELOPER_ID is set per
# workflow step, and the step that lane runs in is one of the few that does not
# carry it, so "what would this host sign with" would answer with the dev
# keychain's self-signed certificate and refuse every run. Hence a record
# written by the step that signed.
#
# Two kinds of test live here, and the split is deliberate. The decision and the
# recording are exercised against the real library with `bundle_signing_cert_sha1`
# stubbed, because the decision under test is the comparison and not codesign.
# The LANE is exercised by running the real driver, because a grep over the
# driver cannot see whether the refusal is fatal, whether it is reached, or
# whether it names the right bundle: all three were shown to survive a text
# check unnoticed.

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIGNING_LIB="$REPO_ROOT/scripts/lib/signing.sh"
LEAF_A="1234567890ABCDEF1234567890ABCDEF12345678"
LEAF_B="ABCDEF1234567890ABCDEF1234567890ABCDEF12"
FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$2"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

# Runs one snippet against the real library in a separate bash PROCESS, with
# `bundle_signing_cert_sha1` replaced by a stub that answers $STUB_LEAF. A
# separate process and not a subshell: run_test calls each test from an `if`
# condition, and bash suppresses errexit for the whole dynamic extent of a
# tested command, nested subshells included.
_with_lib() {
    local leaf="$1" snippet="$2"
    # GITHUB_ACTIONS is pinned, never inherited: the rollout exemption is
    # deliberately stricter in CI, and CI is exactly where these tests run. An
    # inherited value would make every case below mean something different
    # there than it does here.
    SIGNING_LIB="$SIGNING_LIB" STUB_LEAF="$leaf" GITHUB_ACTIONS="${CI_MODE:-}" bash -c '
        set -uo pipefail
        source "$SIGNING_LIB"
        bundle_signing_cert_sha1() { printf "%s" "$STUB_LEAF"; }
        '"$snippet"
}

_expect() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then return 0; fi
    echo "  $name: expected '$want', got '$got'" >&2
    return 1
}

# --- the pure decision ------------------------------------------------------

# `have_record` is a separate input from `recorded`, and these two lines are why.
# An earlier shape folded them together, which made a deploy that signed ad-hoc
# report as "nothing recorded" and PASS. The pair that separates them is
# ("", "", yes) against ("", "", no); without it the cases below are
# order-insensitive and the two can be swapped with every test still green.
test_the_verdict_separates_no_record_from_a_recorded_adhoc() {
    local rc=0 out
    out="$(_with_lib "" '
        printf "%s %s" \
            "$(deployed_leaf_verdict "" "" yes)" \
            "$(deployed_leaf_verdict "" "" no)"')"
    _expect separation "deployed-adhoc unrecorded" "$out" || rc=1
    return "$rc"
}

test_the_verdict_names_the_remaining_cases() {
    local rc=0 out
    out="$(_with_lib "" '
        printf "%s %s %s" \
            "$(deployed_leaf_verdict "'"$LEAF_A"'" "'"$LEAF_A"'" yes)" \
            "$(deployed_leaf_verdict "'"$LEAF_B"'" "'"$LEAF_A"'" yes)" \
            "$(deployed_leaf_verdict "" "'"$LEAF_A"'" yes)"')"
    _expect verdicts "match mismatch adhoc" "$out" || rc=1
    return "$rc"
}

# The record lives BESIDE the bundle, never inside it: anything written into a
# bundle after signing invalidates the signature it is meant to describe.
test_the_record_lives_outside_the_bundle() {
    local rc=0 out
    out="$(_with_lib "" 'deployed_leaf_record "/some/where/Foo.app"')"
    case "$out" in
        /some/where/Foo.app/*) echo "  the record is inside the bundle: $out" >&2; rc=1 ;;
        /some/where/*) ;;
        *) echo "  the record is not beside the bundle: $out" >&2; rc=1 ;;
    esac
    return "$rc"
}

# A trailing slash is what `"$dir/"` style call sites produce, and it must not
# move the record into the bundle.
test_a_trailing_slash_does_not_move_the_record() {
    local rc=0 bare slashed
    bare="$(_with_lib "" 'deployed_leaf_record "/some/where/Foo.app"')"
    slashed="$(_with_lib "" 'deployed_leaf_record "/some/where/Foo.app/"')"
    _expect trailing_slash "$bare" "$slashed" || rc=1
    return "$rc"
}

# --- recording and reading back ---------------------------------------------

# The round trip asserts the record's CONTENTS, not merely that the assertion
# accepted afterwards: "accepted" is also what the rollout exemption returns, so
# a gutted recorder would pass a test that only looks at the verdict.
test_recording_writes_the_leaf_and_reads_back_as_a_match() {
    local dir rc=0 out; dir="$(mktemp -d)"
    # The bundle directory has to exist, or the assertion takes the
    # "no deployment at all" branch and returns accepted from the wrong path.
    # That is how this test was first written, and the log assertion below is
    # what caught it.
    mkdir -p "$dir/Foo.app"
    out="$(_with_lib "$LEAF_A" '
        record_deployed_signing_leaf "'"$dir"'/Foo.app"
        printf "%s|" "$(cat "'"$dir"'/.Foo.app.signing-leaf" 2>/dev/null)"
        if assert_deployed_signing_leaf "'"$dir"'/Foo.app" 2>"'"$dir"'/err"; then
            printf accepted; else printf refused; fi')"
    _expect round_trip "$LEAF_A|accepted" "$out" || rc=1
    # A pass has to be legible in the log. Silence would read the same as a
    # check that never ran, which is the hollow gate this file is about.
    # Both halves: that it said something, and that it named the certificate it
    # recognised. Naming it is the point; without this the value can be dropped
    # from the message with every test still green.
    case "$(cat "$dir/err" 2>/dev/null)" in
        *"carries the certificate the last deploy recorded"*) ;;
        *) echo "  the match passed without saying anything" >&2; rc=1 ;;
    esac
    case "$(cat "$dir/err" 2>/dev/null)" in
        *"$LEAF_A"*) ;;
        *) echo "  the match did not name the certificate it recognised" >&2; rc=1 ;;
    esac
    # And the bundle. One of the four sabotages a text check let through was
    # pointing the assertion at the build path instead of the deploy path; a
    # success line that does not name what it looked at cannot show that in a
    # log, which is the one job the line has.
    case "$(cat "$dir/err" 2>/dev/null)" in
        *"$dir/Foo.app"*) ;;
        *) echo "  the match did not name the bundle it looked at" >&2; rc=1 ;;
    esac
    rm -rf "$dir"; return "$rc"
}

# The defect this file was rewritten for. Reached through the PRODUCTION writer
# rather than by hand-writing the record: an earlier version deleted the record
# on an empty leaf, and a hand-written record hid that, because deleting and
# writing-empty both report "nothing recorded" and both PASS.
test_a_deploy_that_signed_adhoc_refuses_the_next_lane() {
    local dir rc=0 out; dir="$(mktemp -d)"
    mkdir -p "$dir/Foo.app"
    out="$(_with_lib "$LEAF_A" '
        record_deployed_signing_leaf "'"$dir"'/Foo.app"')"
    # Second deploy through the same writer, this time carrying no certificate.
    out="$(_with_lib "" '
        record_deployed_signing_leaf "'"$dir"'/Foo.app"
        if assert_deployed_signing_leaf "'"$dir"'/Foo.app" 2>"'"$dir"'/err"; then
            printf accepted; else printf refused; fi')"
    _expect adhoc_deploy refused "$out" || rc=1
    case "$(cat "$dir/err" 2>/dev/null)" in
        *"no certificate at all"*) ;;
        *) echo "  the refusal does not say the DEPLOY signed ad-hoc" >&2; rc=1 ;;
    esac
    rm -rf "$dir"; return "$rc"
}

# A bundle re-signed behind the driver's back, which is the case the mechanism
# was built for.
test_a_different_certificate_is_refused() {
    local dir rc=0 out; dir="$(mktemp -d)"
    mkdir -p "$dir/Foo.app"
    _with_lib "$LEAF_A" 'record_deployed_signing_leaf "'"$dir"'/Foo.app"'
    out="$(_with_lib "$LEAF_B" '
        if assert_deployed_signing_leaf "'"$dir"'/Foo.app" 2>"'"$dir"'/err"; then
            printf accepted; else printf refused; fi')"
    _expect mismatch refused "$out" || rc=1
    # The message has to name both halves, or the reader cannot tell which
    # certificate is the unexpected one.
    local err; err="$(cat "$dir/err" 2>/dev/null)"
    case "$err" in *"$LEAF_A"*) ;; *) echo "  refusal omits the recorded leaf" >&2; rc=1 ;; esac
    case "$err" in *"$LEAF_B"*) ;; *) echo "  refusal omits the leaf actually found" >&2; rc=1 ;; esac
    rm -rf "$dir"; return "$rc"
}

# Rollout safety: the record appears the first time a driver signs after this
# lands, and an older deployment predates it. Refusing there would turn a
# rollout into an outage for every lane that reuses the bundle, but it has to
# SAY it could not look, or the next reader takes the silence for a pass.
test_a_missing_record_warns_instead_of_refusing() {
    local dir rc=0 out; dir="$(mktemp -d)"
    mkdir -p "$dir/Foo.app"
    out="$(_with_lib "$LEAF_A" '
        if assert_deployed_signing_leaf "'"$dir"'/Foo.app" 2>"'"$dir"'/err"; then
            printf accepted; else printf refused; fi')"
    _expect unrecorded accepted "$out" || rc=1
    case "$(cat "$dir/err" 2>/dev/null)" in
        *"No signing record"*) ;;
        *) echo "  a missing record passed silently" >&2; rc=1 ;;
    esac
    rm -rf "$dir"; return "$rc"
}

# A deployment that is not there at all is a different question, and the drivers
# ask it themselves right after. Answering it here would replace their clear
# "required binary missing" with a confusing one about certificates. Fail-open
# is safe precisely because that check follows and stops the run anyway.
test_an_absent_bundle_is_left_to_the_missing_binary_check() {
    local dir rc=0 out; dir="$(mktemp -d)"
    printf '%s' "$LEAF_A" > "$dir/.Gone.app.signing-leaf"
    out="$(_with_lib "" '
        if assert_deployed_signing_leaf "'"$dir"'/Gone.app" 2>"'"$dir"'/err"; then
            printf accepted; else printf refused; fi')"
    _expect absent_bundle accepted "$out" || rc=1
    case "$(cat "$dir/err" 2>/dev/null)" in
        *"No bundle at"*) ;;
        *) echo "  it passed without saying there is no bundle" >&2; rc=1 ;;
    esac
    rm -rf "$dir"; return "$rc"
}

# In CI the exemption does not apply, and that is the whole reason it is safe to
# have one. The deploy that signs runs earlier in the same job, so a missing
# record there means the deployment came from somewhere else. Left
# unconditional, the exemption would become a permanent silent pass the first
# time anything deploys by another route, and its message would read like a
# benign rollout note rather than a dead gate.
test_a_missing_record_refuses_in_ci() {
    local dir rc=0 out; dir="$(mktemp -d)"
    mkdir -p "$dir/Foo.app"
    out="$(CI_MODE=true _with_lib "$LEAF_A" '
        if assert_deployed_signing_leaf "'"$dir"'/Foo.app" 2>"'"$dir"'/err"; then
            printf accepted; else printf refused; fi')"
    _expect unrecorded_ci refused "$out" || rc=1
    case "$(cat "$dir/err" 2>/dev/null)" in
        *"unknown provenance"*) ;;
        *) echo "  refused in CI, but not for the stated reason" >&2; rc=1 ;;
    esac
    rm -rf "$dir"; return "$rc"
}

# The passing verdicts must not claim a comparison they never made. Copying the
# match sentence into either of them leaves the rest of this file green, because
# every other assertion here is a substring match on a different sentence, and a
# log that announces a match on a path that compared nothing is the exact
# hollowness this whole change exists to remove.
test_the_non_comparing_verdicts_do_not_claim_a_match() {
    local dir rc=0 sentence="carries the certificate the last deploy recorded"
    dir="$(mktemp -d)"
    mkdir -p "$dir/Foo.app"
    _with_lib "$LEAF_A" 'assert_deployed_signing_leaf "'"$dir"'/Foo.app" 2>"'"$dir"'/err1"' >/dev/null
    case "$(cat "$dir/err1" 2>/dev/null)" in
        *"$sentence"*) echo "  the rollout exemption claims a match it never made" >&2; rc=1 ;;
    esac
    printf '%s' "$LEAF_A" > "$dir/.Gone.app.signing-leaf"
    _with_lib "" 'assert_deployed_signing_leaf "'"$dir"'/Gone.app" 2>"'"$dir"'/err2"' >/dev/null
    case "$(cat "$dir/err2" 2>/dev/null)" in
        *"$sentence"*) echo "  the absent-bundle path claims a match it never made" >&2; rc=1 ;;
    esac
    rm -rf "$dir"; return "$rc"
}

# --- the re-sign is what writes the record ----------------------------------

# Drives the real `resign_deployed_bundle` with codesign stubbed, so the
# certificate the bundle reports CHANGES when codesign signs it. Without this
# positive control, moving or misdirecting the recording call leaves the whole
# mechanism dead with every other test still green.
_resign_harness() {
    local dir="$1" start_leaf="$2" identity="$3" snippet="$4"
    printf '%s' "$start_leaf" > "$dir/leaf"
    printf '<plist/>' > "$dir/entitlements.plist"
    mkdir -p "$dir/Foo.app"
    SIGNING_LIB="$SIGNING_LIB" STATE="$dir" NEW_LEAF="$LEAF_A" \
    DEV_ENTITLEMENTS="$dir/entitlements.plist" WANT="$identity" bash -c '
        set -uo pipefail
        source "$SIGNING_LIB"
        bundle_signing_cert_sha1() { cat "$STATE/leaf" 2>/dev/null || true; }
        identity_sha1() { printf "%s" "$WANT"; }
        codesign() {
            case " $* " in
                *" --entitlements :- "*) printf "<key>com.apple.security.device.audio-input</key>\n"; return 0 ;;
                *" --force "*) printf "%s" "$NEW_LEAF" > "$STATE/leaf"; return 0 ;;
            esac
            return 0
        }
        '"$snippet"
}

# The re-sign path: the bundle arrives on another certificate, codesign puts it
# on ours, and the record must name the certificate it ENDED UP with.
test_a_real_resign_records_the_new_leaf() {
    local dir rc=0 out; dir="$(mktemp -d)"
    out="$(_resign_harness "$dir" "$LEAF_B" "$LEAF_A" '
        resign_deployed_bundle "$STATE/Foo.app" "'"$LEAF_A"'" "" >/dev/null 2>&1
        printf "%s|%s" "$?" "$(cat "$STATE/.Foo.app.signing-leaf" 2>/dev/null)"')"
    _expect resign_records "0|$LEAF_A" "$out" || rc=1
    rm -rf "$dir"; return "$rc"
}

# The branch that keeps an existing signature must record too. It is live in CI:
# a re-run whose bundle already carries the right certificate takes it, and if
# only the re-sign path recorded, every `--no-build` sibling of that run would
# inherit a stale or absent record.
test_keeping_an_existing_signature_still_records() {
    local dir rc=0 out; dir="$(mktemp -d)"
    out="$(_resign_harness "$dir" "$LEAF_A" "$LEAF_A" '
        resign_deployed_bundle "$STATE/Foo.app" "'"$LEAF_A"'" "" >"$STATE/out" 2>&1
        printf "%s|%s|" "$?" "$(cat "$STATE/.Foo.app.signing-leaf" 2>/dev/null)"
        case "$(cat "$STATE/out")" in *"Already signed"*) printf shortcircuit ;; *) printf resigned ;; esac')"
    # The third field pins that this test really exercised the keep branch; if a
    # change makes it take the re-sign path instead, the test says so rather
    # than quietly testing the branch that is already covered above.
    _expect keep_branch "0|$LEAF_A|shortcircuit" "$out" || rc=1
    rm -rf "$dir"; return "$rc"
}

# A contract rather than a live path, and labelled as one: every exit in
# verify_signing today is `return 0`, so it cannot currently withhold a record.
# This pins that a future verify_signing which CAN fail does not silently start
# recording bundles it rejected, and that the caller's status survives.
test_a_failed_verification_would_record_nothing() {
    local dir rc=0 out; dir="$(mktemp -d)"
    out="$(SIGNING_LIB="$SIGNING_LIB" RECORD_DIR="$dir" bash -c '
        set -uo pipefail
        source "$SIGNING_LIB"
        bundle_signing_cert_sha1() { printf "%s" "'"$LEAF_A"'"; }
        identity_sha1() { printf "%s" "'"$LEAF_A"'"; }
        codesign() { return 0; }
        verify_signing() { return 3; }
        # stdout swallowed, not stderr-merged: the function narrates its
        # decision there, and only the status is under test here.
        resign_deployed_bundle "$RECORD_DIR/Foo.app" "'"$LEAF_A"'" "" >/dev/null
        printf "%s" "$?"' 2>/dev/null)"
    _expect status 3 "$out" || rc=1
    if [ -e "$dir/.Foo.app.signing-leaf" ]; then
        echo "  a bundle that failed verification was recorded as signed" >&2
        rc=1
    fi
    rm -rf "$dir"; return "$rc"
}

# --- the lane itself, run for real ------------------------------------------

# Runs the actual driver on its `--no-build` path against a throwaway HOME.
#
# A grep over the driver was tried first and thrown away: it stayed green when
# the refusal was downgraded to `|| true`, when the call was wrapped in an `if`
# that never runs, when it was replaced by a comment, and when it was pointed at
# the build path instead of the deploy path. All four are the whole point.
#
# Safe to run from a test: with HOME redirected, the deploy path, the recordings
# dir and the defaults domain are all inside the temp tree; the driver's exit
# trap only restores defaults it actually snapshotted (it has not got that far),
# and `launchctl` is stubbed so the cleanup cannot boot out a developer's real
# dev app.
_lane_sandbox() {
    local home="$1"
    mkdir -p "$home/bin" "$home/Applications/MeetingTranscriber-Dev.app"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/bin/launchctl"
    chmod +x "$home/bin/launchctl"
}

_run_lane() {
    local home="$1"
    HOME="$home" PATH="$home/bin:$PATH" GITHUB_ACTIONS="${CI_MODE:-}" \
        bash "$REPO_ROOT/scripts/e2e-silent-recording.sh" --no-build \
        > "$home/out" 2>&1
    printf '%s' "$?"
}

# The control, and the half that makes the other half mean something: with no
# record the lane must NOT refuse on signing grounds. It still stops, at its own
# missing-binary check, which is how we know the refusal below is caused by the
# record and not by the sandbox.
test_the_lane_does_not_refuse_when_nothing_was_recorded() {
    local home rc=0 status; home="$(mktemp -d)"
    _lane_sandbox "$home"
    status="$(_run_lane "$home")"
    if [ "$status" -eq 0 ]; then
        echo "  the lane ran to completion inside the sandbox, which it cannot" >&2
        rc=1
    fi
    case "$(cat "$home/out" 2>/dev/null)" in
        *"required binary missing"*) ;;
        *) echo "  expected the missing-binary stop, got:" >&2
           sed 's|^|    |' "$home/out" >&2; rc=1 ;;
    esac
    rm -rf "$home"; return "$rc"
}

# The property the commit exists for: on the path where the lane signs nothing,
# a deployment that is not the one that was signed stops the run.
test_the_lane_refuses_a_bundle_that_is_not_the_one_recorded() {
    local home rc=0 status; home="$(mktemp -d)"
    _lane_sandbox "$home"
    # The sandbox bundle carries no certificate, so a record naming one is the
    # "something replaced it" state.
    printf '%s' "$LEAF_A" > "$home/Applications/.MeetingTranscriber-Dev.app.signing-leaf"
    status="$(_run_lane "$home")"
    if [ "$status" -eq 0 ]; then
        echo "  the lane accepted a bundle that is not the one recorded" >&2
        rc=1
    fi
    local out; out="$(cat "$home/out" 2>/dev/null)"
    case "$out" in
        *"carries no certificate"*) ;;
        *) echo "  the lane stopped, but not on the signing record:" >&2
           printf '%s\n' "$out" | sed 's|^|    |' >&2; rc=1 ;;
    esac
    # It must stop BEFORE the missing-binary check, or the refusal is riding on
    # the sandbox rather than on the record.
    case "$out" in
        *"required binary missing"*)
            echo "  the lane reached its binary check, so the record did not stop it" >&2
            rc=1 ;;
    esac
    rm -rf "$home"; return "$rc"
}

run_test "the verdict separates no record from a recorded ad-hoc"  test_the_verdict_separates_no_record_from_a_recorded_adhoc
run_test "the verdict names the remaining cases"                   test_the_verdict_names_the_remaining_cases
run_test "the record lives outside the bundle"                     test_the_record_lives_outside_the_bundle
run_test "a trailing slash does not move the record"               test_a_trailing_slash_does_not_move_the_record
run_test "recording writes the leaf and reads back as a match"     test_recording_writes_the_leaf_and_reads_back_as_a_match
run_test "a deploy that signed ad-hoc refuses the next lane"       test_a_deploy_that_signed_adhoc_refuses_the_next_lane
run_test "a different certificate is refused"                      test_a_different_certificate_is_refused
run_test "a missing record warns instead of refusing"              test_a_missing_record_warns_instead_of_refusing
run_test "an absent bundle is left to the missing-binary check"    test_an_absent_bundle_is_left_to_the_missing_binary_check
run_test "a missing record refuses in CI"                        test_a_missing_record_refuses_in_ci
run_test "the non-comparing verdicts do not claim a match"       test_the_non_comparing_verdicts_do_not_claim_a_match
run_test "a real re-sign records the new leaf"                     test_a_real_resign_records_the_new_leaf
run_test "keeping an existing signature still records"             test_keeping_an_existing_signature_still_records
run_test "a failed verification would record nothing"              test_a_failed_verification_would_record_nothing
run_test "the lane does not refuse when nothing was recorded"      test_the_lane_does_not_refuse_when_nothing_was_recorded
run_test "the lane refuses a bundle that is not the one recorded"  test_the_lane_refuses_a_bundle_that_is_not_the_one_recorded
echo

if [ "$FAILED" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests FAILED."
fi
exit "$FAILED"
