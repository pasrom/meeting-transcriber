#!/usr/bin/env bash
# Generate a three-speaker German test WAV for E2E diarization tests.
#
# Produces: app/MeetingTranscriber/Tests/Fixtures/three_speakers_de.wav (~25s, 16kHz mono)
# Requires: macOS `say` command with voices Anna, Flo, and Sandy installed, and `sox`.
set -euo pipefail

command -v sox >/dev/null 2>&1 || { echo "ERROR: sox is required. Install with: brew install sox"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE_DIR="$PROJECT_DIR/app/MeetingTranscriber/Tests/Fixtures"
OUTPUT="$FIXTURE_DIR/three_speakers_de.wav"
TMPDIR_AUDIO="$(mktemp -d)"

trap 'rm -rf "$TMPDIR_AUDIO"' EXIT

mkdir -p "$FIXTURE_DIR"

echo "Generating 3-speaker speech segments …"

# Anna segments (female voice 1)
say -v Anna "Guten Tag zusammen. Willkommen zum Sprint Review." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/seg1_anna.wav"
# Flo segments (male voice)
say -v Flo "Danke Anna. Ich berichte über den Backend Status." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/seg2_flo.wav"
# Sandy segments (female voice 2)
say -v Sandy "Und ich habe ein Update zum Frontend Design." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/seg3_sandy.wav"

say -v Anna "Sehr gut. Flo, bitte fang an mit dem Backend." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/seg4_anna.wav"
say -v Flo "Die API Entwicklung ist abgeschlossen. Alle Tests sind grün." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/seg5_flo.wav"
say -v Sandy "Das Frontend ist zu achtzig Prozent fertig. Nächste Woche sind wir bereit." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/seg6_sandy.wav"

# Generate 0.8s silence at 16kHz mono
sox -n -r 16000 -c 1 -b 16 "$TMPDIR_AUDIO/silence.wav" trim 0.0 0.8

echo "Assembling final WAV …"

# Resample all segments to 16kHz mono, then concatenate with silence gaps
for i in 1 2 3 4 5 6; do
    seg=$(ls "$TMPDIR_AUDIO"/seg${i}_*.wav)
    sox "$seg" -r 16000 -c 1 "$TMPDIR_AUDIO/seg${i}_16k.wav"
done

sox "$TMPDIR_AUDIO/seg1_16k.wav" \
    "$TMPDIR_AUDIO/silence.wav" \
    "$TMPDIR_AUDIO/seg2_16k.wav" \
    "$TMPDIR_AUDIO/silence.wav" \
    "$TMPDIR_AUDIO/seg3_16k.wav" \
    "$TMPDIR_AUDIO/silence.wav" \
    "$TMPDIR_AUDIO/seg4_16k.wav" \
    "$TMPDIR_AUDIO/silence.wav" \
    "$TMPDIR_AUDIO/seg5_16k.wav" \
    "$TMPDIR_AUDIO/silence.wav" \
    "$TMPDIR_AUDIO/seg6_16k.wav" \
    "$OUTPUT"

DURATION=$(soxi -D "$OUTPUT" 2>/dev/null || echo "?")
SIZE_KB=$(( $(stat -f%z "$OUTPUT") / 1024 ))
echo "Created $OUTPUT (${DURATION}s, ${SIZE_KB}KB)"
echo "Done: $OUTPUT"
