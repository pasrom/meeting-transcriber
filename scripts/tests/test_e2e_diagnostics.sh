#!/bin/bash
# Regression test for the diagnostics bundle a failed e2e-app.sh lane writes.
#
# The bundle is uploaded as a workflow artifact of a PUBLIC repository, so what
# matters most is what it leaves out: speaker names, meeting titles, spoken
# text, paths under a user's home, endpoints. The redaction is an allowlist, so
# these samples carry every kind of personal field /state, the queue snapshot
# and the pipeline log have today, plus one field nobody has added yet, and the
# test asserts none of it survives while the fields kept for diagnosis do.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

TMP="$(mktemp -d)"
# Set at the very end; see test_kill_and_verify_gone.sh for why a `set -u`
# abort would otherwise read as a pass.
COMPLETED=0
cleanup() {
    local rc=$?
    rm -rf "$TMP"
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

# Every string below that must not reach the bundle contains one of these.
LEAKS=("Speaker A" "Speaker B" "Speaker C" Weekly /Users/ someone 10.0.0.5 hypothesis spoken FUTURE_FIELD AirPods)
assert_no_leak() {
    local name="$1" file="$2" leak
    for leak in "${LEAKS[@]}"; do
        # Free text keeps "/Users/<user>" by design; the account name is what
        # it is checked for.
        case "$file:$leak" in *.log:/Users/ | *.ips:/Users/) continue ;; esac
        if grep -q -- "$leak" "$file"; then
            bad "$name" "'$leak' reached the bundle: $(grep -- "$leak" "$file" | head -3)"
        fi
    done
    ok "$name"
}

# A /state answer as the app serves it, with a value in every field that can
# carry personal data.
cat >"$TMP/state.json" <<'JSON'
{
  "pipeline": {"isProcessing": true, "activeJobCount": 1, "waitingJobCount": 0, "pendingNamingJobCount": 1},
  "speakerDB": {"count": 2, "recentNames": ["Speaker A", "Speaker B"], "knownSpeakerNames": ["Speaker A"]},
  "pendingNamingJobs": [{"jobID": "J-2", "meetingTitle": "Weekly sync", "speakerCount": 2, "namingSlug": "2026-11-10_Weekly_sync"}],
  "engines": {"active": "parakeet",
              "whisperKit": {"modelVariant": "openai_whisper-small", "language": "de", "modelState": "loaded"},
              "parakeet": {"customVocabularyPath": "/Users/someone/vocab.txt", "modelState": "loaded"}},
  "lastJob": {"jobID": "J-1", "state": "error", "meetingTitle": "Weekly sync", "appName": "MeetingSimulator",
              "durationSec": 61.5, "transcriptPath": "/Users/someone/Downloads/MeetingTranscriber/protocols/Weekly_sync.txt",
              "protocolPath": null, "export": {"destination": "notion", "status": "failed", "id": "abc", "url": "https://notion.so/Weekly"},
              "error": "The file “2026-11-10 Weekly sync_mix.wav” couldn’t be opened in /Users/someone/Library/Application Support/x.",
              "warnings": ["Raw transcript could not be removed", "moved file:///Users/someone/x.wav"],
              "participants": ["Speaker C"]},
  "channelHealth": {"micSilent": false, "appSilent": true, "recordingSilent": false, "appNoiseFloorOnly": false,
                    "micFault": "stalled", "appLevelDBFS": -31.5, "micStallCount": 1},
  "permissionHealth": {"screenRecording": "healthy", "microphone": "healthy", "accessibility": "denied", "isHealthy": false,
                       "notifications": "authorized", "notificationsAlertStyle": "banner",
                       "notificationsTimeSensitive": "enabled", "notificationsScheduledDelivery": "disabled"},
  "liveCaptions": {"hypothesisMic": "hypothesis text", "hypothesisApp": "more hypothesis",
                   "recentFinals": [{"text": "spoken words", "channel": "app"}]},
  "watchState": "recording",
  "pendingConsentApp": null,
  "isManualRecording": false,
  "notifications": [{"title": "Transcript Saved", "body": "Weekly sync", "postedAt": "2026-11-10T10:00:00Z", "posted": true}],
  "settings": {
    "detection": {"watchTeams": true, "watchZoom": true, "watchWebex": true, "autoWatch": true, "pollIntervalSeconds": 3},
    "recording": {"endGraceSeconds": 15, "noMic": false, "recordOnly": false, "micDeviceUID": "AirPods-UID",
                  "micName": "Speaker A's AirPods", "perChannelIndicatorEnabled": true, "liveTranscriptionEnabled": false,
                  "liveCaptionsOverlayEnabled": true, "liveCaptionsSize": "medium", "asymmetricSilenceWarningSeconds": 90},
    "transcription": {"engine": "parakeet", "whisperKitModel": "openai_whisper-small", "whisperLanguage": "de",
                      "parakeetLanguage": "", "customVocabularyEnabled": true, "customVocabularyPath": "/Users/someone/vocab.txt"},
    "diarization": {"diarize": true, "mode": "offline", "numSpeakers": 2, "vadEnabled": false, "vadThreshold": 0.5,
                    "clusterThreshold": 0.7, "warmStartFa": 0.07, "warmStartFb": 0.8, "minSegmentDurationSeconds": 1,
                    "excludeOverlap": true},
    "protocolGeneration": {"provider": "openAICompatible", "language": "German", "openAIEndpoint": "http://10.0.0.5:11434/v1",
                           "openAIModel": "Weekly-model", "openAITemperature": 0.5, "claudeBin": "/Users/someone/bin/claude"},
    "output": {"directory": "/Users/someone/Downloads/MeetingTranscriber", "hasCustomDirectory": false, "hasCustomPrompt": true,
               "includeFullTranscriptInProtocol": true, "saveRawTranscriptSeparately": false, "useAITitleForFilenames": false},
    "diagnostics": {"verboseDiagnostics": false, "debugRPCEnabled": true},
    "updates": {"checkForUpdates": true, "includePreReleases": false}
  },
  "badge": "recording",
  "updateStatus": {"available": true, "availableVersion": "v1.2.3", "isPrerelease": false, "isChecking": false,
                   "lastError": "could not reach /Users/someone"},
  "windows": [{"id": "speaker-naming", "isVisible": true, "floating": true, "canJoinAllSpaces": true, "fullScreenAuxiliary": false}],
  "FUTURE_FIELD": {"meetingTitle": "Weekly sync"}
}
JSON

e2e_redact_state <"$TMP/state.json" >"$TMP/state.out"
assert_no_leak state_drops_personal_fields "$TMP/state.out"

jq -e '.pipeline.activeJobCount == 1 and .pipeline.pendingNamingJobCount == 1
    and .speakerDB == {count: 2}
    and .pendingNamingJobs == [{jobID: "J-2", speakerCount: 2}]
    and .engines.active == "parakeet" and .engines.whisperKit.modelState == "loaded"
    and .engines.parakeet == {modelState: "loaded"}
    and .lastJob.jobID == "J-1" and .lastJob.state == "error" and .lastJob.appName == "MeetingSimulator"
    and .lastJob.hasTranscript == true and .lastJob.hasProtocol == false and .lastJob.exportStatus == "failed"
    and .lastJob.hasError == true and .lastJob.warningCount == 2
    and .lastJob.participantCount == 1
    and .channelHealth.micFault == "stalled" and .channelHealth.micStallCount == 1
    and .permissionHealth.accessibility == "denied" and .permissionHealth.notificationsAlertStyle == "banner"
    and .liveCaptions == {recentFinalsCount: 1}
    and .watchState == "recording" and .badge == "recording"
    and .notifications == [{title: "Transcript Saved", postedAt: "2026-11-10T10:00:00Z", posted: true}]
    and .settings.detection.autoWatch == true
    and .settings.recording.recordOnly == false and (.settings.recording | has("micName") | not)
    and .settings.transcription.engine == "parakeet" and (.settings.transcription | has("customVocabularyPath") | not)
    and .settings.diarization.numSpeakers == 2
    and .settings.protocolGeneration == {provider: "openAICompatible", language: "German", openAITemperature: 0.5, openAITopP: null}
    and (.settings.output | has("directory") | not) and .settings.output.hasCustomPrompt == true
    and .settings.diagnostics.debugRPCEnabled == true
    and .updateStatus == {available: true, availableVersion: "v1.2.3", isPrerelease: false, isChecking: false}
    and .windows[0].floating == true' "$TMP/state.out" >/dev/null \
    && ok state_keeps_diagnostic_fields || bad state_keeps_diagnostic_fields "$(cat "$TMP/state.out")"

# A state with no job and no settings yet (the app's first seconds).
echo '{"pipeline": {"isProcessing": false, "activeJobCount": 0, "waitingJobCount": 0, "pendingNamingJobCount": 0}, "lastJob": null}' \
    | e2e_redact_state >"$TMP/sparse.out" \
    && jq -e '.lastJob == null and .settings == null and .pendingNamingJobs == []' "$TMP/sparse.out" >/dev/null \
    && ok state_without_job_or_settings || bad state_without_job_or_settings "$(cat "$TMP/sparse.out" 2>/dev/null)"

# The queue snapshot: an array of persisted jobs.
cat >"$TMP/queue.json" <<'JSON'
[{"id": "J-1", "state": "transcribing", "meetingTitle": "Weekly sync", "appName": "Microsoft Teams",
  "mixPath": "file:///Users/someone/Library/Application%20Support/MeetingTranscriber/recordings/x_mix.wav",
  "appPath": null, "micPath": "file:///Users/someone/x_mic.wav", "micDelay": 0.25,
  "participants": ["Speaker A"], "enqueuedAt": 784000000, "error": null, "warnings": ["Weekly sync.wav not removed"],
  "transcriptPath": null, "namingSlug": "Weekly_sync", "notionExportSpeakerNames": ["Speaker B"],
  "usedDiarizerMode": "offline", "autoSkipNaming": false, "FUTURE_FIELD": "Weekly"}]
JSON
e2e_redact_queue <"$TMP/queue.json" >"$TMP/queue.out"
assert_no_leak queue_drops_personal_fields "$TMP/queue.out"
jq -e '.[0] == {id: "J-1", state: "transcribing", appName: "Microsoft Teams", enqueuedAt: 784000000,
        usedDiarizerMode: "offline", autoSkipNaming: false, hasMix: true, hasApp: false, hasMic: true,
        hasTranscript: false, hasError: false, warningCount: 1}' "$TMP/queue.out" >/dev/null \
    && ok queue_keeps_job_states || bad queue_keeps_job_states "$(cat "$TMP/queue.out")"
echo '{"not": "an array", "meetingTitle": "Weekly"}' | e2e_redact_queue >"$TMP/queue-bad.out" \
    && jq -e '. == {unreadable: true}' "$TMP/queue-bad.out" >/dev/null \
    && ok queue_of_unexpected_shape || bad queue_of_unexpected_shape "$(cat "$TMP/queue-bad.out")"

# The pipeline log: known keys per line, a broken line dropped, not the rest.
printf '%s\n' \
    '{"timestamp": "2026-11-10T10:00:00Z", "job_id": "J-1", "event": "state", "from": "-", "to": "waiting", "FUTURE_FIELD": "Weekly"}' \
    'not json at all /Users/someone' \
    '{"timestamp": "2026-11-10T10:00:05Z", "job_id": "J-1", "event": "state", "from": "waiting", "to": "transcribing"}' \
    | e2e_redact_pipeline_log >"$TMP/log.out"
assert_no_leak pipeline_log_drops_unknown_keys "$TMP/log.out"
[ "$(wc -l <"$TMP/log.out" | tr -d ' ')" = 2 ] && jq -se '.[1].to == "transcribing" and .[0].from == "-"' "$TMP/log.out" >/dev/null \
    && ok pipeline_log_keeps_transitions || bad pipeline_log_keeps_transitions "$(cat "$TMP/log.out")"

# The simulator log: the account name goes, the rest stays readable.
printf '%s\n' 'playing /Users/someone/git/Transcriber/app/Fixtures/two_speakers_de.wav' \
    | e2e_scrub_text >"$TMP/text.out"
grep -q '/Users/<user>/git/Transcriber/app/Fixtures/two_speakers_de.wav' "$TMP/text.out" \
    && ! grep -q 'someone' "$TMP/text.out" \
    && ok text_scrub || bad text_scrub "$(cat "$TMP/text.out")"

# A crash report: a one-line header, then the body. The dev app's is kept
# without its fatalError text, its mapped-file summary and the machine key;
# the installed app's (same process name) and one that does not parse are not
# taken at all.
dev_ips() {
    printf '%s\n' '{"app_name":"MeetingTranscriber","bug_type":"309","timestamp":"2026-11-10 10:00:00","name":"MeetingTranscriber","FUTURE_FIELD":"Weekly"}'
    printf '%s\n' "{\"procPath\":\"/Users/someone/Applications/$1/Contents/MacOS/MeetingTranscriber\",\"procName\":\"MeetingTranscriber\",
      \"crashReporterKey\":\"0A1B2C3D-machine\",\"exception\":{\"type\":\"EXC_BREAKPOINT\",\"signal\":\"SIGTRAP\"},
      \"asi\":{\"libswiftCore.dylib\":[\"Fatal error: no recording for Weekly sync\"]},
      \"vmSummary\":\"mapped file /Users/someone/Downloads/Weekly sync_mix.wav\",
      \"threads\":[{\"id\":1,\"frames\":[{\"symbol\":\"main\"}]}],
      \"usedImages\":[{\"path\":\"/Users/someone/Applications/$1/Contents/MacOS/MeetingTranscriber\"}]}"
}
dev_ips MeetingTranscriber-Dev.app >"$TMP/dev.ips"
if e2e_redact_crash_report "$TMP/dev.ips" >"$TMP/dev.out.ips"; then
    assert_no_leak crash_report_drops_personal_fields "$TMP/dev.out.ips"
    grep -q 0A1B2C3D "$TMP/dev.out.ips" && bad crash_report_drops_machine_key "$(cat "$TMP/dev.out.ips")"
    tail -n +2 "$TMP/dev.out.ips" | jq -e '.exception.type == "EXC_BREAKPOINT" and .threads[0].frames[0].symbol == "main"
        and (.procPath | startswith("/Users/<user>/"))' >/dev/null \
        && ok crash_report_keeps_the_crash || bad crash_report_keeps_the_crash "$(cat "$TMP/dev.out.ips")"
else
    bad crash_report_of_the_dev_app_is_taken "returned non-zero"
fi
dev_ips MeetingTranscriber.app >"$TMP/installed.ips"
! e2e_redact_crash_report "$TMP/installed.ips" >/dev/null && ok installed_app_crash_is_not_taken \
    || bad installed_app_crash_is_not_taken "was taken"
printf 'not an ips file\n' >"$TMP/broken.ips"
! e2e_redact_crash_report "$TMP/broken.ips" >/dev/null && ok unparsable_report_is_not_taken \
    || bad unparsable_report_is_not_taken "was taken"

# The whole bundle, with the app's /state stubbed (state_read is what the
# writer calls) and a crash report on each side of the run marker.
DATA="$TMP/data"
mkdir -p "$DATA/ipc" "$TMP/crash"
cp "$TMP/queue.json" "$DATA/ipc/pipeline_queue.json"
for i in $(seq 1 300); do
    printf '{"timestamp": "t%s", "job_id": "J-1", "event": "state", "from": "-", "to": "waiting"}\n' "$i"
done >"$DATA/ipc/pipeline_log.jsonl"
printf 'playing /Users/someone/fixture.wav\n' >"$TMP/sim.log"
cp "$TMP/dev.ips" "$TMP/crash/MeetingTranscriber-old.ips"
touch -t 202001010000 "$TMP/crash/MeetingTranscriber-old.ips"
MARKER="$TMP/marker"
touch -t 202001020000 "$MARKER"
cp "$TMP/dev.ips" "$TMP/crash/MeetingTranscriber-new.ips"
cp "$TMP/installed.ips" "$TMP/crash/MeetingTranscriber-installed.ips"
printf 'another app\n' >"$TMP/crash/OtherApp-new.ips"

# shellcheck disable=SC2034 # read by e2e_write_diagnostics
state_read() { STATE_BODY="$(cat "$TMP/state.json")"; return 0; }
OUT="$TMP/bundle/lane"
e2e_write_diagnostics "$OUT" "$DATA" "$MARKER" "$TMP/sim.log" "$TMP/crash"
[ -f "$OUT/state.json" ] && [ -f "$OUT/pipeline_queue.json" ] && [ -f "$OUT/pipeline_log.tail.jsonl" ] \
    && [ -f "$OUT/simulator.log" ] && [ -f "$OUT/crash-reports/MeetingTranscriber-new.ips" ] \
    && ok bundle_has_every_part || bad bundle_has_every_part "$(find "$OUT" -type f)"
[ ! -e "$OUT/crash-reports/MeetingTranscriber-old.ips" ] && [ ! -e "$OUT/crash-reports/OtherApp-new.ips" ] \
    && [ ! -e "$OUT/crash-reports/MeetingTranscriber-installed.ips" ] \
    && ok bundle_takes_only_this_runs_app_crashes || bad bundle_takes_only_this_runs_app_crashes "$(ls "$OUT/crash-reports")"
[ "$(wc -l <"$OUT/pipeline_log.tail.jsonl" | tr -d ' ')" = "$E2E_DIAG_LOG_TAIL_LINES" ] \
    && jq -se '.[-1].timestamp == "t300"' "$OUT/pipeline_log.tail.jsonl" >/dev/null \
    && ok bundle_log_is_a_tail || bad bundle_log_is_a_tail "$(wc -l <"$OUT/pipeline_log.tail.jsonl") lines"
# The free-text files keep "/Users/<user>" by design, so the account name is
# what they are checked for there.
leaked=""
while IFS= read -r f; do
    for leak in "${LEAKS[@]}"; do
        case "$f:$leak" in *.log:/Users/ | *.ips:/Users/) continue ;; esac
        if grep -q -- "$leak" "$f"; then leaked="$leaked $f:$leak"; fi
    done
done < <(find "$OUT" -type f)
[ -z "$leaked" ] && ok bundle_leaks_nothing || bad bundle_leaks_nothing "$leaked"

# An app that does not answer: the rest is still written, and the bundle says
# why there is no state rather than holding an empty file.
# shellcheck disable=SC2034 # what the real state_read leaves
state_read() { STATE_ERR="no reply"; return 2; }
OUT2="$TMP/bundle/quiet"
e2e_write_diagnostics "$OUT2" "$DATA" "$MARKER" "$TMP/sim.log" "$TMP/crash"
[ ! -e "$OUT2/state.json" ] && [ -s "$OUT2/state.unavailable.txt" ] && [ -f "$OUT2/pipeline_queue.json" ] \
    && ok bundle_without_an_answer || bad bundle_without_an_answer "$(find "$OUT2" -type f)"

# Nothing to collect (no data dir, no log, no marker): still succeeds.
OUT3="$TMP/bundle/empty"
e2e_write_diagnostics "$OUT3" "$TMP/nowhere" "" "" "$TMP/nowhere" \
    && ok bundle_with_nothing_to_collect || bad bundle_with_nothing_to_collect "returned $?"

COMPLETED=1
echo "All $PASSED tests passed."
