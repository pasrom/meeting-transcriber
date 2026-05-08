#!/usr/bin/env bash
# Generate quality-suite ground-truth fixtures: WAV + sidecar JSON with text +
# per-speaker turn timestamps. Used by P6 WER/DER regression suite.
#
# Each WAV gets a `<name>_truth.json` next to it describing the expected
# transcript and diarization timeline. Regenerate any time `say` voices or
# segment scripts change — the JSON is rebuilt with the audio so they stay
# consistent.
#
# Output: app/MeetingTranscriber/Tests/Fixtures/quality/
#
# Requires: macOS `say` (voices Anna, Flo, Sandy), `sox`, `python3`.

set -euo pipefail

command -v sox >/dev/null 2>&1 || { echo "ERROR: sox is required (brew install sox)"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_DIR/app/MeetingTranscriber/Tests/Fixtures/quality"
mkdir -p "$OUT_DIR"

SILENCE_DURATION=1.0

# render_segments <name> <segments...>
# Each segment is a single string "Speaker|Voice|Text" passed as positional arg.
render_segments() {
    local name="$1"; shift
    local out_wav="$OUT_DIR/${name}.wav"
    local out_json="$OUT_DIR/${name}_truth.json"
    local tmp; tmp="$(mktemp -d)"

    sox -n -r 16000 -c 1 -b 16 "$tmp/silence.wav" trim 0.0 "$SILENCE_DURATION"

    local concat_args=()
    local turns_python_args=()
    local cursor=0.0
    local full_text=""
    local idx=0
    local total=$#

    for entry in "$@"; do
        local speaker="${entry%%|*}"
        local rest="${entry#*|}"
        local voice="${rest%%|*}"
        local text="${rest#*|}"

        local seg_raw="$tmp/seg${idx}_raw.wav"
        local seg_16k="$tmp/seg${idx}_16k.wav"
        say -v "$voice" "$text" --file-format=WAVE --data-format=LEI16 -o "$seg_raw"
        sox "$seg_raw" -r 16000 -c 1 "$seg_16k"

        local seg_dur
        seg_dur=$(soxi -D "$seg_16k")

        local seg_start="$cursor"
        local seg_end
        seg_end=$(awk -v s="$seg_start" -v d="$seg_dur" 'BEGIN { printf "%.6f", s + d }')

        turns_python_args+=("$speaker" "$seg_start" "$seg_end" "$text")
        full_text="${full_text}${full_text:+ }${text}"

        concat_args+=("$seg_16k")
        if [ "$idx" -lt $((total - 1)) ]; then
            concat_args+=("$tmp/silence.wav")
            cursor=$(awk -v s="$seg_end" -v g="$SILENCE_DURATION" 'BEGIN { printf "%.6f", s + g }')
        else
            cursor="$seg_end"
        fi
        idx=$((idx + 1))
    done

    sox "${concat_args[@]}" "$out_wav"

    local total_dur
    total_dur=$(soxi -D "$out_wav")

    # Hand off to python for clean JSON formatting (avoids manual string
    # escaping for German umlauts and quotes).
    python3 - "$name" "$total_dur" "$full_text" "$out_json" "${turns_python_args[@]}" <<'PY'
import json, sys
name, total_dur, full_text, out_json, *rest = sys.argv[1:]
turns = []
for i in range(0, len(rest), 4):
    speaker, start, end, text = rest[i:i+4]
    turns.append({"speaker": speaker, "start": float(start), "end": float(end), "text": text})
data = {
    "fixture": name,
    "audio": f"{name}.wav",
    "duration": float(total_dur),
    "sampleRate": 16000,
    "text": full_text,
    "turns": turns,
}
with open(out_json, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

    rm -rf "$tmp"
    echo "Created: $out_wav (${total_dur}s) + $(basename "$out_json")"
}

render_segments "two_speakers_de" \
    "A|Anna|Guten Tag, willkommen zum Projekt Meeting." \
    "B|Flo|Danke. Ich möchte den aktuellen Status berichten." \
    "A|Anna|Sehr gut. Wie läuft die Entwicklung?" \
    "B|Flo|Die Entwicklung läuft nach Plan. Wir sind im Zeitplan."

render_segments "three_speakers_de" \
    "A|Anna|Guten Tag zusammen. Willkommen zum Sprint Review." \
    "B|Flo|Danke Anna. Ich berichte über den Backend Status." \
    "C|Sandy|Und ich habe ein Update zum Frontend Design." \
    "A|Anna|Sehr gut. Flo, bitte fang an mit dem Backend." \
    "B|Flo|Die API Entwicklung ist abgeschlossen. Alle Tests sind grün." \
    "C|Sandy|Das Frontend ist zu achtzig Prozent fertig. Nächste Woche sind wir bereit."

echo
echo "Done. Quality fixtures regenerated in: $OUT_DIR"
