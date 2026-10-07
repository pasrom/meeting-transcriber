#!/bin/bash
# Regression test for the two readers the --quit-flush lane of e2e-app.sh
# builds its verdicts on.
#
# Both are negative-capable: the lane fails when the snapshot on disk lacks the
# job a quit owed it, and when the app leaves a `log stream` behind. A reader
# that found nothing because it looked wrongly would turn either into a pass,
# so each one is checked in both directions here, and an unreadable snapshot
# must be told apart from one that simply lacks the job.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSED=0

ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }

expect_output() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then ok "$name"; else bad "$name" "expected '$expected', got '$actual'"; fi
}

# --- snapshot_new_job_ids ----------------------------------------------------

# The shape PipelineSnapshot.save writes: a bare array of encoded PipelineJob.
SNAP="$TMP/pipeline_queue.json"
cat >"$SNAP" <<'JSON'
[
  {"id": "AAAAAAAA-0000-0000-0000-000000000001", "meetingTitle": "Microphone Recording", "state": "done"},
  {"id": "AAAAAAAA-0000-0000-0000-000000000002", "meetingTitle": "Weekly Sync", "state": "waiting"},
  {"id": "AAAAAAAA-0000-0000-0000-000000000003", "meetingTitle": "Microphone Recording", "state": "waiting"}
]
JSON

expect_output new_job_found \
    "AAAAAAAA-0000-0000-0000-000000000003" \
    "$(snapshot_new_job_ids "$SNAP" "Microphone Recording" AAAAAAAA-0000-0000-0000-000000000001)"

expect_output both_new_without_known_ids \
    "AAAAAAAA-0000-0000-0000-000000000001
AAAAAAAA-0000-0000-0000-000000000003" \
    "$(snapshot_new_job_ids "$SNAP" "Microphone Recording")"

# The title is matched exactly: a job of another meeting is never ours.
expect_output other_title_ignored "" \
    "$(snapshot_new_job_ids "$SNAP" "Weekly" )"

# Every titled job already known: nothing new, status 0 (the file was read).
status=0
out="$(snapshot_new_job_ids "$SNAP" "Microphone Recording" \
    AAAAAAAA-0000-0000-0000-000000000001 AAAAAAAA-0000-0000-0000-000000000003)" || status=$?
if [ "$status" -eq 0 ] && [ -z "$out" ]; then ok all_known_is_empty_not_error
else bad all_known_is_empty_not_error "status $status, output '$out'"; fi

# A missing or unparseable snapshot is not "the job is absent": status 2, so
# the lane can say which of the two it was.
status=0
snapshot_new_job_ids "$TMP/missing.json" "Microphone Recording" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then ok missing_snapshot_is_status_2; else bad missing_snapshot_is_status_2 "status $status"; fi

printf '[{"id": "x", "meetingTitle": ' >"$TMP/torn.json"
status=0
snapshot_new_job_ids "$TMP/torn.json" "Microphone Recording" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then ok torn_snapshot_is_status_2; else bad torn_snapshot_is_status_2 "status $status"; fi

# --- streamer_pids -----------------------------------------------------------

# `ps -axo pid=,ppid=,command=` as the lane feeds it. 500 is the app.
PS_TABLE="  500     1 /Users/u/Applications/MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber
  501   500 /usr/bin/log stream --predicate subsystem CONTAINS 'com.meetingtranscriber' --style syslog --info
  502   500 /bin/ps -axo pid=,ppid=,command=
  600     1 /usr/bin/log stream --predicate subsystem CONTAINS 'com.meetingtranscriber' --style syslog --info
  601     1 /usr/bin/log stream --predicate subsystem == 'com.apple.coreaudio'
  602   777 /usr/bin/log stream --predicate subsystem CONTAINS 'com.meetingtranscriber' --style syslog --info
  603   500 /usr/bin/log show --last 5m"

expect_output child_of_app "501" "$(streamer_pids 500 <<<"$PS_TABLE")"
# ppid 1 is how an orphan looks; a user's own `log stream` with another
# predicate is not ours, and another instance's live streamer is not an orphan.
expect_output orphan_of_ours "600" "$(streamer_pids 1 <<<"$PS_TABLE")"
expect_output none_for_unrelated_parent "" "$(streamer_pids 4242 <<<"$PS_TABLE")"

# Two children is the regression the launch check exists for (a second
# AppState starting a second streamer); both must be reported.
expect_output two_children_both_reported "501
504" "$(streamer_pids 500 <<<"$PS_TABLE
  504   500 /usr/bin/log stream --predicate subsystem CONTAINS 'com.meetingtranscriber' --style syslog --info")"

# --- queue_snapshot_is_empty -------------------------------------------------

check_status() {
    local name="$1" expected="$2" status=0
    shift 2
    "$@" >/dev/null 2>&1 || status=$?
    if [ "$status" -eq "$expected" ]; then ok "$name"; else bad "$name" "expected status $expected, got $status"; fi
}

printf '[]' >"$TMP/empty.json"
printf '[\n]\n' >"$TMP/empty-spaced.json"
check_status empty_queue_is_empty 0 queue_snapshot_is_empty "$TMP/empty.json"
check_status whitespace_empty_queue_is_empty 0 queue_snapshot_is_empty "$TMP/empty-spaced.json"
check_status queue_with_a_job_is_not_empty 1 queue_snapshot_is_empty "$SNAP"
check_status torn_queue_is_unreadable 2 queue_snapshot_is_empty "$TMP/torn.json"
# No file means nothing was ever queued on this host.
check_status missing_queue_is_empty 0 queue_snapshot_is_empty "$TMP/never-written.json"

# --- backup_state_files / restore_state_files --------------------------------

STATE="$TMP/state"; BACKUP="$TMP/backup"
mkdir -p "$STATE"
printf '{"job_id":"DDDDDDDD-0000-0000-0000-000000000004","event":"done"}\n' >"$STATE/pipeline_log.jsonl"
printf '[{"jobID":"DDDDDDDD-0000-0000-0000-000000000004","state":"done"}]' >"$STATE/terminal_jobs.json"
backup_state_files "$STATE" "$BACKUP" pipeline_log.jsonl terminal_jobs.json processed_recordings.json
if [ -f "$BACKUP/pipeline_log.jsonl" ] && [ -f "$BACKUP/terminal_jobs.json" ] \
    && grep -qx processed_recordings.json "$BACKUP/.absent"; then
    ok backup_copies_present_and_records_absent
else
    bad backup_copies_present_and_records_absent "$(ls -A "$BACKUP")"
fi

# What a run does: appends, rewrites, creates. The created file holds only
# this run's records: its job's mix path.
RUN_IDS="$TMP/run-ids"; RUN_PATHS="$TMP/run-paths"
printf 'aaaaaaaa-0000-0000-0000-000000000001\n' >"$RUN_IDS"
printf '/Users/x/rec/20260311_140000_mix.wav\n' >"$RUN_PATHS"
printf '{"job_id":"AAAAAAAA-0000-0000-0000-000000000001","event":"enqueued"}\n' >>"$STATE/pipeline_log.jsonl"
printf '[{"jobID":"DDDDDDDD-0000-0000-0000-000000000004","state":"done"},{"jobID":"AAAAAAAA-0000-0000-0000-000000000001","state":"done"}]' \
    >"$STATE/terminal_jobs.json"
printf '["/Users/x/rec/20260311_140000_mix.wav"]' >"$STATE/processed_recordings.json"
status=0
out="$(restore_state_files "$BACKUP" "$STATE" "$RUN_IDS" "$RUN_PATHS" pipeline_log.jsonl terminal_jobs.json processed_recordings.json)" || status=$?
if [ "$status" -eq 0 ] && cmp -s "$BACKUP/pipeline_log.jsonl" "$STATE/pipeline_log.jsonl" \
    && cmp -s "$BACKUP/terminal_jobs.json" "$STATE/terminal_jobs.json"; then
    ok restore_is_byte_identical
else
    bad restore_is_byte_identical "status $status: $out"
fi
# A file that did not exist before and holds only this run's records is the
# run's own: it is removed, so the shared state ends as it began.
if [ "$status" -eq 0 ] && [ ! -e "$STATE/processed_recordings.json" ] \
    && grep -q 'processed_recordings.json: absent before, still absent' <<<"$out"; then
    ok absent_before_and_created_by_the_run_is_removed
else
    bad absent_before_and_created_by_the_run_is_removed "status $status: $out"
fi
if grep -q 'pipeline_log.jsonl: match' <<<"$out"; then ok restore_reports_the_compare; else bad restore_reports_the_compare "$out"; fi

# Each shared file proves the run created it its own way. A file absent before
# that holds a record of anyone else is left, and the restore fails loudly:
# deleting it could delete someone's state, keeping it quietly would leave the
# run's records in the installed app's data.
check_created() {
    local name="$1" file="$2" content="$3" expected="$4"
    local dir="$TMP/created-$name" backup="$TMP/created-$name-backup"
    mkdir -p "$dir"
    backup_state_files "$dir" "$backup" "$file"
    printf '%s' "$content" >"$dir/$file"
    local status=0 out
    out="$(restore_state_files "$backup" "$dir" "$RUN_IDS" "$RUN_PATHS" "$file")" || status=$?
    case "$expected" in
        removed)
            if [ "$status" -eq 0 ] && [ ! -e "$dir/$file" ]; then ok "$name"; else bad "$name" "status $status: $out"; fi ;;
        kept)
            if [ "$status" -ne 0 ] && [ -e "$dir/$file" ] && grep -q "$file: absent before, now present" <<<"$out"; then
                ok "$name"
            else
                bad "$name" "status $status: $out"
            fi ;;
    esac
}
check_created created_empty_queue_is_removed pipeline_queue.json '[]' removed
check_created created_queue_of_the_run_is_removed pipeline_queue.json \
    '[{"id":"AAAAAAAA-0000-0000-0000-000000000001","state":"done"}]' removed
check_created created_queue_with_a_foreign_job_fails pipeline_queue.json \
    '[{"id":"AAAAAAAA-0000-0000-0000-000000000001"},{"id":"BBBBBBBB-0000-0000-0000-000000000009"}]' kept
check_created created_terminal_store_of_the_run_is_removed terminal_jobs.json \
    '[{"jobID":"AAAAAAAA-0000-0000-0000-000000000001","state":"done"}]' removed
check_created created_terminal_store_with_a_foreign_job_fails terminal_jobs.json \
    '[{"jobID":"BBBBBBBB-0000-0000-0000-000000000009","state":"done"}]' kept
check_created created_log_of_the_run_is_removed pipeline_log.jsonl \
    '{"job_id":"AAAAAAAA-0000-0000-0000-000000000001","event":"enqueued"}
{"job_id":"AAAAAAAA-0000-0000-0000-000000000001","event":"done"}
' removed
check_created created_log_with_a_foreign_job_fails pipeline_log.jsonl \
    '{"job_id":"BBBBBBBB-0000-0000-0000-000000000009","event":"recovered"}
' kept
check_created created_ledger_with_a_foreign_path_fails processed_recordings.json \
    '["/Users/x/rec/20260311_140000_mix.wav","/Users/x/rec/20250101_090000_mix.wav"]' kept
check_created created_torn_file_fails terminal_jobs.json '[{"jobID":' kept

# A file that existed before is put back only when everything added since the
# backup is this run's. Something else that wrote to it after the backup (an
# app the lane did not start) would have its records erased by a blind copy:
# the restore refuses and fails loudly instead.
PROD="$TMP/producer"; PROD_BACKUP="$TMP/producer-backup"
mkdir -p "$PROD"
printf '[]' >"$PROD/pipeline_queue.json"
backup_state_files "$PROD" "$PROD_BACKUP" pipeline_queue.json
printf '[{"id":"AAAAAAAA-0000-0000-0000-000000000001"},{"id":"CCCCCCCC-0000-0000-0000-000000000003"}]' \
    >"$PROD/pipeline_queue.json"
status=0
out="$(restore_state_files "$PROD_BACKUP" "$PROD" "$RUN_IDS" "$RUN_PATHS" pipeline_queue.json)" || status=$?
if [ "$status" -ne 0 ] && grep -q 'CCCCCCCC' "$PROD/pipeline_queue.json" \
    && grep -q 'pipeline_queue.json: NOT RESTORED' <<<"$out"; then
    ok a_record_written_after_the_backup_by_someone_else_is_not_erased
else
    bad a_record_written_after_the_backup_by_someone_else_is_not_erased "status $status: $out"
fi

# The pipeline log is append-only and its history is not all JSON: the real
# file holds torn fragments of earlier interleaved appends (a few characters
# ending in `}`) and empty lines. A restore checks only what the run appended:
# the backup must be a byte prefix of the file, and every appended line must
# parse and be one of the run's.
LOGD="$TMP/log"; LOGD_BACKUP="$TMP/log-backup"
mkdir -p "$LOGD"
printf '{"job_id":"DDDDDDDD-0000-0000-0000-000000000004","event":"done"}\nab"}\n\n{"job_id":"DDDDDDDD-0000-0000-0000-000000000004","event":"x"}\n' \
    >"$LOGD/pipeline_log.jsonl"
backup_state_files "$LOGD" "$LOGD_BACKUP" pipeline_log.jsonl
printf '{"job_id":"AAAAAAAA-0000-0000-0000-000000000001","event":"enqueued"}\n' >>"$LOGD/pipeline_log.jsonl"
status=0
out="$(restore_state_files "$LOGD_BACKUP" "$LOGD" "$RUN_IDS" "$RUN_PATHS" pipeline_log.jsonl)" || status=$?
if [ "$status" -eq 0 ] && cmp -s "$LOGD_BACKUP/pipeline_log.jsonl" "$LOGD/pipeline_log.jsonl"; then
    ok a_log_with_torn_history_is_restored_from_what_the_run_appended
else
    bad a_log_with_torn_history_is_restored_from_what_the_run_appended "status $status: $out"
fi
printf '{"job_id":"CCCCCCCC-0000-0000-0000-000000000003","event":"enqueued"}\n' >>"$LOGD/pipeline_log.jsonl"
status=0
out="$(restore_state_files "$LOGD_BACKUP" "$LOGD" "$RUN_IDS" "$RUN_PATHS" pipeline_log.jsonl)" || status=$?
if [ "$status" -ne 0 ] && grep -q 'CCCCCCCC' "$LOGD/pipeline_log.jsonl" && grep -q 'pipeline_log.jsonl: NOT RESTORED' <<<"$out"; then
    ok a_foreign_line_appended_to_the_log_is_not_erased
else
    bad a_foreign_line_appended_to_the_log_is_not_erased "status $status: $out"
fi
cp "$LOGD_BACKUP/pipeline_log.jsonl" "$LOGD/pipeline_log.jsonl"
printf 'rewritten\n' >"$LOGD/pipeline_log.jsonl"
status=0
out="$(restore_state_files "$LOGD_BACKUP" "$LOGD" "$RUN_IDS" "$RUN_PATHS" pipeline_log.jsonl)" || status=$?
if [ "$status" -ne 0 ] && grep -qx 'rewritten' "$LOGD/pipeline_log.jsonl"; then
    ok a_log_that_is_no_longer_an_append_of_the_backup_is_not_restored
else
    bad a_log_that_is_no_longer_an_append_of_the_backup_is_not_restored "status $status: $out"
fi

# The backup goes once the state matched it: it holds a copy of
# speakers.json (voice embeddings and names) and the queue. Only the files the
# backup itself wrote, and the directories only when they are empty then.
GONE="$TMP/gone-backup"
mkdir -p "$TMP/gone-src"
printf '{}' >"$TMP/gone-src/speakers.json"
backup_state_files "$TMP/gone-src" "$GONE" speakers.json missing.json
status=0
out="$(remove_state_backup "$GONE" speakers.json missing.json)" || status=$?
if [ "$status" -eq 0 ] && [ ! -e "$GONE" ] && [ -f "$TMP/gone-src/speakers.json" ]; then
    ok a_matching_run_removes_its_backup
else
    bad a_matching_run_removes_its_backup "status $status: $out $(ls -A "$GONE" 2>&1)"
fi
STAY="$TMP/stay-backup"
backup_state_files "$TMP/gone-src" "$STAY" speakers.json
printf 'not ours\n' >"$STAY/notes.txt"
status=0
out="$(remove_state_backup "$STAY" speakers.json)" || status=$?
if [ "$status" -ne 0 ] && [ -f "$STAY/notes.txt" ]; then
    ok a_backup_with_a_file_it_did_not_write_is_left
else
    bad a_backup_with_a_file_it_did_not_write_is_left "status $status: $out"
fi

# compare_state_files reads only: a changed file is a mismatch, status 1.
printf '{"job_id":"DDDDDDDD-0000-0000-0000-000000000004","event":"changed"}\n' >>"$STATE/pipeline_log.jsonl"
status=0
out="$(compare_state_files "$BACKUP" "$STATE" pipeline_log.jsonl terminal_jobs.json)" || status=$?
if [ "$status" -eq 1 ] && grep -q 'pipeline_log.jsonl: MISMATCH' <<<"$out" && grep -q 'terminal_jobs.json: match' <<<"$out"; then
    ok compare_reports_mismatch
else
    bad compare_reports_mismatch "status $status: $out"
fi

echo "$PASSED passed"
