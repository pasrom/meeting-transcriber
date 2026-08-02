#!/usr/bin/env bash
# Generate a two-speaker German test WAV for E2E transcription + diarization tests.
#
# Usage: ./scripts/generate_test_audio.sh [--output <path>] [--force]
#
# Produces: ~17s, 16kHz mono, ~530KB of four `say` segments with 1s gaps.
# Requires: macOS `say` command with voices Anna and Flo installed, and `sox`.
#
# THIS SCRIPT DOES NOT REPRODUCE THE COMMITTED FIXTURE. The checked-in
# app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav is 49.8s and holds a
# longer dialogue; the two drifted apart when the fixture was regenerated with
# different voices and the script was not carried along. Overwriting the fixture
# with this script's output is therefore a silent downgrade, which is why the
# default output is a temp file and the fixture path needs --force.
#
# What breaks if you do overwrite it (measured, not assumed): eight sibling
# fixtures (.m4a .mp3 .mp4 .mkv .webm .ogg .opus .3gp) are derived from that WAV
# and stay at the old duration, and FFmpegHelperTests.testMKVAndWAVProduceSimilarDuration
# compares the two, so it fails with 17.0s vs 49.8s. Regenerating the fixture for
# real means regenerating the whole family and re-checking every test that reads
# it, not running this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE_DIR="$PROJECT_DIR/app/MeetingTranscriber/Tests/Fixtures"
FIXTURE="$FIXTURE_DIR/two_speakers_de.wav"

OUTPUT=""
FORCE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUTPUT="${2:-}"; shift 2 ;;
        --output=*) OUTPUT="${1#--output=}"; shift ;;
        --force) FORCE=true; shift ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done

command -v sox >/dev/null 2>&1 || { echo "ERROR: sox is required. Install with: brew install sox"; exit 1; }

# Default to a temp file: the interesting output of this script is the audio, and
# writing it over a committed fixture that eight other fixtures are derived from
# should be a decision, not the default.
if [ -z "$OUTPUT" ]; then
    OUTPUT="$(mktemp -d)/two_speakers_de.wav"
fi

if [ "$OUTPUT" = "$FIXTURE" ] && [ "$FORCE" != true ]; then
    cat >&2 <<EOF
ERROR: refusing to overwrite the committed fixture.

  $FIXTURE

That file is 49.8s and this script produces ~17s, so the write would be a silent
downgrade. Eight sibling fixtures are derived from it and would no longer match;
FFmpegHelperTests.testMKVAndWAVProduceSimilarDuration compares WAV against MKV and
fails on the mismatch.

Run without arguments to write to a temp file, or pass --force if you really mean
to replace the fixture and will regenerate its siblings too.
EOF
    exit 1
fi

TMPDIR_AUDIO="$(mktemp -d)"

trap 'rm -rf "$TMPDIR_AUDIO"' EXIT

mkdir -p "$(dirname "$OUTPUT")"

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
