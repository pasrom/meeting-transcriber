#!/bin/bash
# Regression test for what the --protocol lane of e2e-app.sh rests on: the
# local chat-completions stub, the check that reads its request log, and the
# record/restore pair that puts the host's protocol settings back.
#
# Each check of the request is shown to fire on a request that breaks only that
# one property, so a lane that passes is a lane whose request had all of them,
# and the stub is run for real in both its modes, so the 500 the failure phase
# relies on is what it actually serves.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"
STUB="$ROOT/scripts/fixtures/openai-chat-stub.py"

TMP="$(mktemp -d)"
STUB_PID=""
COMPLETED=0
# Set at the very end; see test_kill_and_verify_gone.sh for why a `set -u`
# abort would otherwise read as a pass.
cleanup() {
    local rc=$?
    if [ -n "$STUB_PID" ]; then
        kill "$STUB_PID" 2>/dev/null || true
        wait "$STUB_PID" 2>/dev/null || true
    fi
    chmod -R u+w "$TMP" 2>/dev/null || true
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
expect() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then ok "$name"; else bad "$name" "expected '$expected', got '$actual'"; fi
}

# --- openai_stub_request_violations ------------------------------------------

TRANSCRIPT=$'[00:00] Guten Morgen.\n[00:04] Hallo zusammen.'
EXPECT="$(jq -nc --arg t "$TRANSCRIPT" '{path: "/v1/chat/completions", model: "e2e-stub-model",
    language: "French", transcript: $t, temperature: 0.5, topP: null, languageInPrompt: true}')"
GOOD="$(jq -nc --arg t "$TRANSCRIPT" '{method: "POST", path: "/v1/chat/completions",
    contentType: "application/json", bodyBytes: 100, body: {model: "e2e-stub-model", stream: true,
    max_tokens: 16000, temperature: 0.5, messages: [
        {role: "system", content: "Create a structured meeting protocol in French from the following transcript."},
        {role: "user", content: $t}]}}')"

violations() { openai_stub_request_violations "$1" "${2:-$EXPECT}"; }
# One mutation of the good request must produce exactly one violation, and it
# must be the one named.
expect_one() {
    local name="$1" mutation="$2" needle="$3" out
    out="$(violations "$(jq -c "$mutation" <<<"$GOOD")")"
    if [ "$(grep -c . <<<"$out")" = 1 ] && grep -qF -- "$needle" <<<"$out"; then
        ok "$name"
    else
        bad "$name" "expected one violation mentioning '$needle', got: ${out:-<none>}"
    fi
}

expect good_request_has_no_violations "" "$(violations "$GOOD")"
expect_one wrong_path '.path = "/v1/completions"' "path is /v1/completions"
expect_one wrong_method '.method = "GET"' "method is GET"
expect_one wrong_content_type '.contentType = "text/plain"' "Content-Type"
expect_one wrong_model '.body.model = "llama3.1"' "model is \"llama3.1\""
expect_one not_streamed '.body.stream = false' "stream is false"
expect_one retried_token_name '.body |= (del(.max_tokens) | .max_completion_tokens = 16000)' "max_tokens is null"
expect_one temperature_missing 'del(.body.temperature)' "temperature is absent"
expect_one temperature_wrong '.body.temperature = 1' "temperature is 1"
expect_one top_p_sent_unset '.body.top_p = 1' "top_p was sent"
expect_one placeholder_left '.body.messages[0].content = "protocol in {LANGUAGE}, French"' "{LANGUAGE}"
expect_one language_missing '.body.messages[0].content = "protocol in German"' "does not name the protocol language"
expect_one transcript_differs '.body.messages[1].content = "something else"' "user message is not the transcript"
expect_one roles_swapped '.body.messages[1].role = "assistant"' "messages[1].role"
expect_one body_not_json '.body = null' "body is not a JSON object"
expect_one one_message_only '.body.messages |= .[:1]' "messages is not a [system, user] pair"

# A custom prompt need not name the language; only the placeholder check stays.
CUSTOM="$(jq -c '.languageInPrompt = false' <<<"$EXPECT")"
expect custom_prompt_skips_the_language_check "" \
    "$(violations "$(jq -c '.body.messages[0].content = "Summarise this."' <<<"$GOOD")" "$CUSTOM")"
# And with an override expected unset, a body without it is clean.
UNSET="$(jq -c '.temperature = null' <<<"$EXPECT")"
expect unset_override_absent_is_clean "" "$(violations "$(jq -c 'del(.body.temperature)' <<<"$GOOD")" "$UNSET")"

# --- defaults_record_keys / defaults_mark_lane_values / defaults_restore_record

PL="$TMP/prefs.plist"
REC="$TMP/record"
xml_of() { plutil -extract "$1" xml1 -o - "$PL" 2>/dev/null | sed -n '4p'; }
/usr/bin/defaults write "$PL" provider -string "claude CLI"
/usr/bin/defaults write "$PL" temp '<real>0.7</real>'
/usr/bin/defaults write "$PL" narrow -float 0.7
/usr/bin/defaults write "$PL" diarize -bool true
/usr/bin/defaults write "$PL" count -int 3
/usr/bin/defaults write "$PL" amp -string "a & <b>"
TEMP_BEFORE="$(xml_of temp)"
NARROW_BEFORE="$(xml_of narrow)"
defaults_record_keys "$REC" "$PL" provider temp narrow diarize count amp missing
expect record_has_a_line_per_key 7 "$(grep -c . "$REC")"

# What a lane does: overwrite every key, add the one that was absent.
/usr/bin/defaults write "$PL" provider -string openAICompatible
/usr/bin/defaults write "$PL" temp -float 0.5
/usr/bin/defaults write "$PL" narrow -float 0.5
/usr/bin/defaults write "$PL" diarize -bool false
/usr/bin/defaults write "$PL" count -int 7
/usr/bin/defaults write "$PL" amp -string plain
/usr/bin/defaults write "$PL" missing -string set-by-lane
rc=0; defaults_restore_record "$REC" 2>/dev/null || rc=$?
expect restore_succeeds 0 "$rc"
expect string_comes_back "claude CLI" "$(/usr/bin/defaults read "$PL" provider)"
# 0.7 as a double, bit for bit: `defaults write -float` would store a 32-bit
# 0.69999998807907104 and `defaults read` would still print 0.7.
expect double_comes_back_losslessly "<real>0.69999999999999996</real>" "$(xml_of temp)"
expect double_was_what_was_recorded "$TEMP_BEFORE" "$(xml_of temp)"
expect a_narrowed_float_comes_back_as_it_was "$NARROW_BEFORE" "$(xml_of narrow)"
expect bool_comes_back "<true/>" "$(xml_of diarize)"
expect int_comes_back "<integer>3</integer>" "$(xml_of count)"
expect xml_special_characters_come_back "a & <b>" "$(/usr/bin/defaults read "$PL" amp)"
expect absent_key_is_removed "absent" "$(/usr/bin/defaults read "$PL" missing >/dev/null 2>&1 && echo present || echo absent)"
expect record_is_removed_after_a_restore "no" "$([ -f "$REC" ] && echo yes || echo no)"

rc=0; defaults_restore_record "$REC" || rc=$?
expect no_record_is_a_no_op 0 "$rc"

# Marked with the lane's values: a key changed since keeps the newer choice,
# the rest come back, and the record still goes. Marking twice must not stack.
/usr/bin/defaults write "$PL" provider -string none
/usr/bin/defaults delete "$PL" missing 2>/dev/null || true
defaults_record_keys "$REC" "$PL" provider missing
/usr/bin/defaults write "$PL" provider -string openAICompatible
/usr/bin/defaults write "$PL" missing -string set-by-lane
defaults_mark_lane_values "$REC"
defaults_mark_lane_values "$REC"
expect marks_do_not_stack 4 "$(head -1 "$REC" | tr '\037' '\n' | grep -c '')"
/usr/bin/defaults write "$PL" provider -string chosen-since
rc=0; defaults_restore_record "$REC" 2>/dev/null || rc=$?
expect newer_choice_is_kept "0/chosen-since" "$rc/$(/usr/bin/defaults read "$PL" provider)"
expect unchanged_key_is_restored "absent/no" \
    "$(/usr/bin/defaults read "$PL" missing >/dev/null 2>&1 && echo present || echo absent)/$([ -f "$REC" ] && echo yes || echo no)"

# A value a line cannot carry is refused, and nothing of that plist is recorded.
/usr/bin/defaults write "$PL" dict -dict a b
rc=0; defaults_record_keys "$REC" "$PL" provider dict 2>/dev/null || rc=$?
expect dictionary_is_refused "1/no" "$rc/$([ -s "$REC" ] && echo yes || echo no)"
/usr/bin/defaults write "$PL" multiline -string $'two\nlines'
rc=0; defaults_record_keys "$REC" "$PL" multiline 2>/dev/null || rc=$?
expect newline_is_refused 1 "$rc"
rm -f "$REC"

# A restore that cannot land returns 1 and keeps ONLY the lines that did not
# land: a settled line left in the record would be re-applied by a later run,
# over whatever was chosen in between.
RO="$TMP/readonly"
mkdir -p "$RO"
/usr/bin/defaults write "$RO/prefs.plist" provider -string none
/usr/bin/defaults write "$PL" provider -string none
defaults_record_keys "$REC" "$RO/prefs.plist" provider
defaults_record_keys "$REC" "$PL" provider
/usr/bin/defaults write "$RO/prefs.plist" provider -string openAICompatible
/usr/bin/defaults write "$PL" provider -string openAICompatible
chmod a-w "$RO" "$RO/prefs.plist"
rc=0; defaults_restore_record "$REC" 2>/dev/null || rc=$?
expect failed_restore_returns_1 1 "$rc"
expect kept_record_holds_only_the_failed_line "1/$RO/prefs.plist" \
    "$(grep -c . "$REC")/$(cut -d $'\037' -f1 "$REC")"
expect the_writable_one_was_restored none "$(/usr/bin/defaults read "$PL" provider)"
chmod u+w "$RO" "$RO/prefs.plist"
rm -f "$REC"

# A plist that cannot be read is not a plist whose keys are absent: the line
# stays and the restore reports it, the mark refuses, nothing is dropped as
# "changed since". A line in a format this reader does not know is dropped
# (said, not kept forever), and so is a key someone set since to a value no
# line can carry: both are settled, not failures.
/usr/bin/defaults write "$PL" provider -string none
defaults_record_keys "$REC" "$PL" provider
/usr/bin/defaults write "$PL" provider -string openAICompatible
defaults_mark_lane_values "$REC"
eval "_saved_export() $(declare -f _defaults_export | tail -n +2)"
_defaults_export() { return 1; }
rc=0; defaults_mark_lane_values "$REC" 2>/dev/null || rc=$?
expect mark_refuses_an_unreadable_plist 1 "$rc"
rc=0; defaults_restore_record "$REC" 2>/dev/null || rc=$?
expect unreadable_plist_keeps_the_line "1/1/openAICompatible" \
    "$rc/$(grep -c . "$REC")/$(/usr/bin/defaults read "$PL" provider)"
eval "_defaults_export() $(declare -f _saved_export | tail -n +2)"
rc=0; defaults_restore_record "$REC" 2>/dev/null || rc=$?
expect readable_again_restores "0/none/no" "$rc/$(/usr/bin/defaults read "$PL" provider)/$([ -f "$REC" ] && echo yes || echo no)"
printf '%s\037provider\037string\037none\037string\037x\n' "$PL" >"$REC"
rc=0; defaults_restore_record "$REC" 2>/dev/null || rc=$?
expect unknown_format_is_dropped_not_applied "0/no/none" \
    "$rc/$([ -f "$REC" ] && echo yes || echo no)/$(/usr/bin/defaults read "$PL" provider)"
defaults_record_keys "$REC" "$PL" provider
/usr/bin/defaults write "$PL" provider -string openAICompatible
defaults_mark_lane_values "$REC"
/usr/bin/defaults write "$PL" provider -string $'set\nsince'
rc=0; defaults_restore_record "$REC" 2>/dev/null || rc=$?
expect unrepresentable_newer_choice_is_kept "0/no/2" \
    "$rc/$([ -f "$REC" ] && echo yes || echo no)/$(/usr/bin/defaults read "$PL" provider | grep -c .)"
rm -f "$REC"

# --- the stub, run for real ----------------------------------------------------

PORT_FILE="$TMP/port"
LOG="$TMP/requests.jsonl"
MODE="$TMP/mode"
REPLY=$'# Meeting Protocol - E2E Stub\n\nStub protocol body.'
python3 "$STUB" --port-file "$PORT_FILE" --log "$LOG" --mode-file "$MODE" --reply "$REPLY" &
STUB_PID=$!
# The port file is the stub's "listening" marker; the wait ends when it
# appears, or at once if the stub exits. 20 s is a ceiling for a stub that
# never comes up (a cold python3 start on a loaded runner can take seconds);
# curl's --max-time below is a looser ceiling than before for one that stops
# answering once up.
_stub_up() { [ -s "$PORT_FILE" ] || ! _pid_is_alive "$STUB_PID"; }
poll_until 20 0.1 _stub_up || true
[ -s "$PORT_FILE" ] || bad stub_starts "no port file (stub $(_pid_is_alive "$STUB_PID" && echo 'still starting after 20 s' || echo exited))"
PORT="$(cat "$PORT_FILE")"
ok stub_starts

post() {
    curl --silent --max-time 10 -o "$TMP/response" -w '%{http_code}' -X POST \
        -H "Content-Type: application/json" -H "Authorization: Bearer secret-key-value" \
        -H "api-key: secret-key-value" \
        --data "$(jq -c '.body' <<<"$GOOD")" "http://127.0.0.1:$PORT/v1/chat/completions"
}

# ok: the deltas must join to the reply, with a stop and the sentinel, which is
# what OpenAIProtocolGenerator.parseSSELine accumulates.
expect ok_mode_answers_200 200 "$(post)"
expect ok_mode_streams_the_reply "$REPLY" \
    "$(sed -n 's/^data: //p' "$TMP/response" | grep -v '^\[DONE\]$' | jq -j '.choices[0].delta.content // empty')"
expect ok_mode_finishes_with_stop stop \
    "$(sed -n 's/^data: //p' "$TMP/response" | grep -v '^\[DONE\]$' | jq -r '.choices[0].finish_reason // empty')"
expect ok_mode_ends_with_done "data: [DONE]" "$(grep -v '^$' "$TMP/response" | tail -1)"
expect logged_request_is_clean "" "$(violations "$(tail -1 "$LOG")")"
# A host's real key reaches the stub in the lane; it must never reach the log.
expect log_never_holds_a_key "no" "$(grep -q secret-key-value "$LOG" && echo yes || echo no)"

printf 'http500' >"$MODE"
expect http500_mode_answers_500 500 "$(post)"
expect http500_is_logged "http500/500" "$(tail -1 "$LOG" | jq -r '"\(.mode)/\(.status)"')"

code="$(curl --silent --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models")"
expect other_paths_answer_404_and_are_logged "404/GET" "$code/$(tail -1 "$LOG" | jq -r .method)"
expect every_request_is_logged 3 "$(grep -c . "$LOG")"

COMPLETED=1
echo "All $PASSED protocol-lane helper checks passed"
