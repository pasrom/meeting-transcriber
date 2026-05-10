#!/usr/bin/env bash
# Generate a two-speaker German fixture with an engineered 5 s silence block
# inserted in the middle. Used by the VAD pipeline E2E test to verify that
# Voice Activity Detection trims the silence and that the remap step puts
# transcript timestamps back on the original timeline.
#
# Produces: app/MeetingTranscriber/Tests/Fixtures/two_speakers_de_with_silence.wav
# Source:   app/MeetingTranscriber/Tests/Fixtures/quality/two_speakers_de.wav (17s)
# Result:   ~22 s, 16 kHz mono PCM s16le, ~700 KB. Silence range: [8s, 13s].
#
# Requires: sox (`brew install sox`).
set -euo pipefail

command -v sox >/dev/null 2>&1 || {
    echo "ERROR: sox is required. Install with: brew install sox"
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE_DIR="$PROJECT_DIR/app/MeetingTranscriber/Tests/Fixtures"
SOURCE="$FIXTURE_DIR/quality/two_speakers_de.wav"
OUTPUT="$FIXTURE_DIR/two_speakers_de_with_silence.wav"
TMPDIR_AUDIO="$(mktemp -d)"

trap 'rm -rf "$TMPDIR_AUDIO"' EXIT

[ -f "$SOURCE" ] || {
    echo "ERROR: source fixture missing: $SOURCE"
    echo "Generate it first with: ./scripts/generate_test_audio.sh"
    exit 1
}

echo "Splitting source at t=8s …"
sox "$SOURCE" "$TMPDIR_AUDIO/front.wav" trim 0 8
sox "$SOURCE" "$TMPDIR_AUDIO/back.wav" trim 8

echo "Generating 5 s silence …"
sox -n -r 16000 -c 1 -b 16 "$TMPDIR_AUDIO/silence.wav" trim 0.0 5.0

echo "Concatenating front + silence + back …"
sox "$TMPDIR_AUDIO/front.wav" "$TMPDIR_AUDIO/silence.wav" "$TMPDIR_AUDIO/back.wav" "$OUTPUT"

DURATION=$(sox --i -D "$OUTPUT")
SIZE=$(stat -f%z "$OUTPUT")
printf 'OK: %s\n  duration=%ss  size=%s bytes  silence range=[8s, 13s]\n' \
    "$OUTPUT" "$DURATION" "$SIZE"
