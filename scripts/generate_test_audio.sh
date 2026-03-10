#!/usr/bin/env bash
# Generate a two-speaker German test WAV for E2E transcription + diarization tests.
#
# Produces: app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav (~15s, 16kHz mono, ~500KB)
# Requires: macOS `say` command with voices Anna and Flo installed, and `sox`.
set -euo pipefail

command -v sox >/dev/null 2>&1 || { echo "ERROR: sox is required. Install with: brew install sox"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE_DIR="$PROJECT_DIR/app/MeetingTranscriber/Tests/Fixtures"
OUTPUT="$FIXTURE_DIR/two_speakers_de.wav"
TMPDIR_AUDIO="$(mktemp -d)"

trap 'rm -rf "$TMPDIR_AUDIO"' EXIT

mkdir -p "$FIXTURE_DIR"

echo "Generating speech segments …"

# Anna segments
say -v Anna "Guten Tag, willkommen zum Projekt Meeting." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/anna1.wav"
say -v Anna "Sehr gut. Wie läuft die Entwicklung?" \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/anna2.wav"

# Flo segments
say -v Flo "Danke. Ich möchte den aktuellen Status berichten." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/flo1.wav"
say -v Flo "Die Entwicklung läuft nach Plan. Wir sind im Zeitplan." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/flo2.wav"

# Generate 1s silence at 16kHz mono
sox -n -r 16000 -c 1 -b 16 "$TMPDIR_AUDIO/silence.wav" trim 0.0 1.0

echo "Assembling final WAV …"

# Resample all segments to 16kHz mono, then concatenate with silence gaps
for f in anna1 flo1 anna2 flo2; do
    sox "$TMPDIR_AUDIO/${f}.wav" -r 16000 -c 1 "$TMPDIR_AUDIO/${f}_16k.wav"
done

sox "$TMPDIR_AUDIO/anna1_16k.wav" \
    "$TMPDIR_AUDIO/silence.wav" \
    "$TMPDIR_AUDIO/flo1_16k.wav" \
    "$TMPDIR_AUDIO/silence.wav" \
    "$TMPDIR_AUDIO/anna2_16k.wav" \
    "$TMPDIR_AUDIO/silence.wav" \
    "$TMPDIR_AUDIO/flo2_16k.wav" \
    "$OUTPUT"

DURATION=$(soxi -D "$OUTPUT" 2>/dev/null || echo "?")
SIZE_KB=$(( $(stat -f%z "$OUTPUT") / 1024 ))
echo "Created $OUTPUT (${DURATION}s, ${SIZE_KB}KB)"
echo "Done: $OUTPUT"
