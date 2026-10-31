#!/bin/bash
# Regression test for the helpers the --upgrade lane of e2e-app.sh seeds a
# v0.8.1 install with and compares folders by, and for the lane's argument
# checks.
#
# The lane's verdicts rest on these: a seed in the wrong shape would test a
# format no release ever wrote, a fingerprint that missed a rewrite would let a
# re-download pass as a move, and a home check that accepted the wrong folder
# would point the lane's removal at data that is not its own.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"
# shellcheck source=../lib/upgrade-seed.sh
source "$ROOT/scripts/lib/upgrade-seed.sh"

TMP="$(mktemp -d)"
COMPLETED=0
# Set at the very end; see test_kill_and_verify_gone.sh for why a `set -u`
# abort would otherwise read as a pass.
cleanup() {
    local rc=$?
    rm -rf "${TMP:?}"
    if [ "$COMPLETED" -ne 1 ]; then
        echo "FAIL: the test aborted before reaching its end" >&2
        exit 1
    fi
    exit "$rc"
}
trap cleanup EXIT
PASSED=0

ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }
expect() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then ok "$name"; else bad "$name" "expected '$expected', got '$actual'"; fi
}
yes_no() { if "$@"; then echo yes; else echo no; fi; }

# A model variant with every file a load requires, a few bytes each.
make_variant() {
    local dir="$1" bundle file
    for bundle in MelSpectrogram AudioEncoder TextDecoder; do
        for file in coremldata.bin model.mil weights/weight.bin; do
            mkdir -p "$(dirname "$dir/$bundle.mlmodelc/$file")"
            printf '%s/%s' "$bundle" "$file" >"$dir/$bundle.mlmodelc/$file"
        done
    done
    printf '{}' >"$dir/config.json"
}

# --- upgrade_variant_complete -------------------------------------------------

make_variant "$TMP/v-complete"
expect a_variant_with_every_required_file_is_complete yes "$(yes_no upgrade_variant_complete "$TMP/v-complete")"
make_variant "$TMP/v-partial"
rm "$TMP/v-partial/AudioEncoder.mlmodelc/weights/weight.bin"
expect a_variant_missing_one_weight_file_is_not "no" "$(yes_no upgrade_variant_complete "$TMP/v-partial")"
mkdir -p "$TMP/v-dirs/TextDecoder.mlmodelc/weights"
expect a_variant_of_empty_bundle_folders_is_not "no" "$(yes_no upgrade_variant_complete "$TMP/v-dirs")"

# --- upgrade_path_inside ------------------------------------------------------

expect a_path_below_the_dir_is_inside yes "$(yes_no upgrade_path_inside /h/e2e/a/b /h/e2e)"
expect the_dir_itself_is_not_inside no "$(yes_no upgrade_path_inside /h/e2e /h/e2e)"
expect a_sibling_sharing_the_prefix_is_not_inside no "$(yes_no upgrade_path_inside /h/e2e-other/a /h/e2e)"
expect a_path_climbing_out_is_not_inside no "$(yes_no upgrade_path_inside /h/e2e/../Documents /h/e2e)"
expect an_empty_dir_contains_nothing no "$(yes_no upgrade_path_inside /a "")"

# --- the v0.8.1 shapes --------------------------------------------------------

expect a_file_url_percent_encodes_each_segment "file:///tmp/Application%20Support/a_b-c.wav" \
    "$(upgrade_file_url "/tmp/Application Support/a_b-c.wav")"
expect foundation_dates_count_from_2001 0 "$(upgrade_foundation_date 978307200)"

JOB="$(upgrade_v081_pipeline_job 11111111-2222-3333-4444-555555555555 "A Title" transcribing \
    "/x/Application Support/MeetingTranscriber/recordings/s_mix.wav" 1800000000)"
# Exactly the keys v0.8.1's PipelineJob encoded for such a job, and none of the
# ones added since: a seed carrying a newer key would test today's format.
expect the_job_has_exactly_the_v081_keys \
    "appName autoSkipNaming enqueuedAt id includeFullTranscriptInProtocol meetingStartTime meetingTitle micDelay mixPath participants saveRawTranscriptSeparately state warnings" \
    "$(jq -r 'keys | join(" ")' <<<"$JOB")"
expect the_job_mix_path_is_a_file_url \
    "file:///x/Application%20Support/MeetingTranscriber/recordings/s_mix.wav" "$(jq -r .mixPath <<<"$JOB")"
expect the_job_dates_are_foundation_seconds "821692800 821692740" \
    "$(jq -r '"\(.enqueuedAt) \(.meetingStartTime)"' <<<"$JOB")"

REC="$(upgrade_v081_terminal_record 66666666-7777-8888-9999-000000000000 "Done Title" /x/t.md)"
expect the_record_has_exactly_the_v081_keys \
    "echo jobID meetingTitle state transcriptPath warnings" "$(jq -r 'keys | join(" ")' <<<"$REC")"
expect the_echo_verdict_lacks_the_newer_cancellation_time \
    "affectedWindowShare detected suppressedSegments windowsAffected windowsScored" \
    "$(jq -r '.echo | keys | join(" ")' <<<"$REC")"

# --- upgrade_seed_whisperkit --------------------------------------------------

SRC="$TMP/src/huggingface"
make_variant "$SRC/$UPGRADE_WHISPERKIT_REPO/openai_whisper-small"
mkdir -p "$SRC/$UPGRADE_TOKENIZER_ORG/whisper-small"
printf '{"t":1}' >"$SRC/$UPGRADE_TOKENIZER_ORG/whisper-small/tokenizer.json"

DST="$TMP/home1/Documents/huggingface"
upgrade_seed_whisperkit "$SRC" "$DST" openai_whisper-small whisper-small
expect the_seed_lays_the_variant_out_where_v081_downloaded_it yes \
    "$(yes_no upgrade_variant_complete "$DST/models/argmaxinc/whisperkit-coreml/openai_whisper-small")"
expect the_seed_puts_the_tokenizer_in_the_shared_cache yes \
    "$(yes_no test -f "$DST/models/openai/whisper-small/tokenizer.json")"
expect without_source_metadata_the_seed_writes_a_stand_in 3 \
    "$(wc -l <"$DST/models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/openai_whisper-small/config.json.metadata" | tr -d ' ')"

META="$SRC/$UPGRADE_WHISPERKIT_REPO/.cache/huggingface/download/openai_whisper-small/AudioEncoder.mlmodelc"
mkdir -p "$META"
printf 'real\n' >"$META/model.mil.metadata"
DST2="$TMP/home2/Documents/huggingface"
upgrade_seed_whisperkit "$SRC" "$DST2" openai_whisper-small whisper-small
expect with_source_metadata_the_seed_carries_it "real" \
    "$(cat "$DST2/models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/openai_whisper-small/AudioEncoder.mlmodelc/model.mil.metadata")"
expect the_seed_leaves_the_source_as_it_was yes \
    "$(yes_no upgrade_variant_complete "$SRC/$UPGRADE_WHISPERKIT_REPO/openai_whisper-small")"

rc=0; upgrade_seed_whisperkit "$SRC" "$TMP/home3/hf" openai_whisper-base whisper-small 2>/dev/null || rc=$?
expect an_absent_variant_is_refused 1 "$rc"
expect a_refused_seed_writes_nothing no "$(yes_no test -e "$TMP/home3")"
rc=0; upgrade_seed_whisperkit "$SRC" "$TMP/home4/hf" openai_whisper-small whisper-tiny 2>/dev/null || rc=$?
expect an_absent_tokenizer_is_refused 1 "$rc"

# --- fingerprints and digests -------------------------------------------------

make_variant "$TMP/fp/a/model"
upgrade_tree_fingerprint "$TMP/fp/a/model" >"$TMP/fp.before"
mkdir -p "$TMP/fp/b"
mv "$TMP/fp/a/model" "$TMP/fp/b/model"
upgrade_tree_fingerprint "$TMP/fp/b/model" >"$TMP/fp.moved"
expect a_moved_tree_keeps_its_fingerprint yes "$(yes_no cmp -s "$TMP/fp.before" "$TMP/fp.moved")"

cp -R "$TMP/fp/b/model" "$TMP/fp/copy"
upgrade_tree_fingerprint "$TMP/fp/copy" >"$TMP/fp.copy"
expect a_copied_tree_does_not no "$(yes_no cmp -s "$TMP/fp.before" "$TMP/fp.copy")"

sleep 1
printf 'rewritten' >"$TMP/fp/b/model/AudioEncoder.mlmodelc/model.mil"
upgrade_tree_fingerprint "$TMP/fp/b/model" >"$TMP/fp.rewritten"
expect a_file_rewritten_in_place_changes_it no "$(yes_no cmp -s "$TMP/fp.moved" "$TMP/fp.rewritten")"

touch "$TMP/fp/b/model/weight.bin.incomplete"
upgrade_tree_fingerprint "$TMP/fp/b/model" >"$TMP/fp.added"
expect an_added_file_changes_it no "$(yes_no cmp -s "$TMP/fp.rewritten" "$TMP/fp.added")"
expect a_missing_tree_fingerprints_as_absent absent "$(upgrade_tree_fingerprint "$TMP/nowhere")"

upgrade_tree_digest "$TMP/fp/copy" >"$TMP/dg.copy"
cp -R "$TMP/fp/copy" "$TMP/fp/copy2"
upgrade_tree_digest "$TMP/fp/copy2" >"$TMP/dg.copy2"
expect a_copy_has_the_same_digest yes "$(yes_no cmp -s "$TMP/dg.copy" "$TMP/dg.copy2")"
printf 'changed' >"$TMP/fp/copy2/config.json"
upgrade_tree_digest "$TMP/fp/copy2" >"$TMP/dg.changed"
expect a_changed_file_changes_the_digest no "$(yes_no cmp -s "$TMP/dg.copy" "$TMP/dg.changed")"

# --- e2e_is_lane_home ---------------------------------------------------------

expect the_upgrade_lane_home_is_recognised yes \
    "$(yes_no e2e_is_lane_home /t/e2e-upgrade-home.Ab12 e2e-upgrade-home /t)"
expect a_mic_stall_home_is_not_the_upgrade_lane_s no \
    "$(yes_no e2e_is_lane_home /t/e2e-mic-stall-home.Ab12 e2e-upgrade-home /t)"
expect a_home_in_another_parent_is_not_recognised no \
    "$(yes_no e2e_is_lane_home /elsewhere/e2e-upgrade-home.Ab12 e2e-upgrade-home /t)"
expect a_path_climbing_out_of_a_home_is_not_recognised no \
    "$(yes_no e2e_is_lane_home /t/e2e-upgrade-home.Ab12/../precious e2e-upgrade-home /t)"

# --- the lane in e2e-app.sh ---------------------------------------------------

APP_SH="$ROOT/scripts/e2e-app.sh"
# A call, not a mention: comments inside on_exit name the function too.
ON_EXIT_CALLS="$(awk '/^on_exit\(\) \{/,/^\}/' "$APP_SH" | { grep -E '^[[:space:]]*([^#[:space:]].*)?_ug_cleanup' || true; })"
expect the_exit_handler_runs_the_upgrade_cleanup yes "$([ -n "$ON_EXIT_CALLS" ] && echo yes || echo no)"

# Run only the argument parsing and the lane checks, cut from the script at the
# end of this lane's check, so nothing past them can run.
CHECK_END="$(awk '/Error: --upgrade is a standalone lane/ { found = 1 } found && /^fi$/ { print NR; exit }' "$APP_SH")"
[ -n "$CHECK_END" ] || bad the_lane_check_exists "the --upgrade check was not found in $APP_SH"
sed -n "1,${CHECK_END}p" "$APP_SH" >"$TMP/parse.sh"
parse_status() { local st=0; bash "$TMP/parse.sh" "$@" >/dev/null 2>&1 || st=$?; echo "$st"; }
expect the_lane_refuses_company "2 2 2 2" \
    "$(parse_status --upgrade --keep-app) $(parse_status --upgrade --mic-stall) $(parse_status --record-only --upgrade) $(parse_status --upgrade --fixture /x.wav)"
expect the_lane_alone_passes_the_checks "0 0" "$(parse_status --upgrade) $(parse_status --upgrade --no-build)"

COMPLETED=1
echo "all $PASSED passed"
