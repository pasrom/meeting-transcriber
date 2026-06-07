#!/usr/bin/env bash
# Generate a short English test WAV for the streaming live-captions E2E.
#
# Produces: app/MeetingTranscriber/Tests/Fixtures/two_speakers_en.wav (~15s, 16kHz mono, ~485KB)
# Requires: macOS `say` command with voices Samantha and Daniel installed, and `sox`.
#
# The script is intentionally a KNOWN word list so the real-model E2E
# (EouStreamingE2ETests) can assert word recall against it. A ≥2s silence
# block is inserted mid-clip so the end-of-utterance (EOU) streaming path
# gets realistic turn-end material — but the test never hard-asserts that
# the mid-stream EOU fires, only that the deterministic flush-final does.
set -euo pipefail

command -v sox >/dev/null 2>&1 || { echo "ERROR: sox is required. Install with: brew install sox"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE_DIR="$PROJECT_DIR/app/MeetingTranscriber/Tests/Fixtures"
OUTPUT="$FIXTURE_DIR/two_speakers_en.wav"
TMPDIR_AUDIO="$(mktemp -d)"

trap 'rm -rf "$TMPDIR_AUDIO"' EXIT

mkdir -p "$FIXTURE_DIR"

echo "Generating English speech segments …"

# Samantha (US) — first turn. Known content words for recall assertion.
say -v Samantha "Good morning everyone, welcome to the weekly project meeting." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/sam1.wav"
say -v Samantha "Let us review the status of the new feature." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/sam2.wav"

# Daniel (GB) — second turn after the pause.
say -v Daniel "Thanks. The development is going well and we are on schedule." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/dan1.wav"
say -v Daniel "All the tests are passing and the release is ready." \
    --file-format=WAVE --data-format=LEI16 -o "$TMPDIR_AUDIO/dan2.wav"

# Generate 2.5s silence at 16kHz mono — the mid-clip turn-end gap for EOU.
sox -n -r 16000 -c 1 -b 16 "$TMPDIR_AUDIO/silence.wav" trim 0.0 2.5
# Short 0.6s gap between same-speaker sentences.
sox -n -r 16000 -c 1 -b 16 "$TMPDIR_AUDIO/gap.wav" trim 0.0 0.6

echo "Assembling final WAV …"

# Resample all segments to 16kHz mono, then concatenate with silence gaps.
for f in sam1 sam2 dan1 dan2; do
    sox "$TMPDIR_AUDIO/${f}.wav" -r 16000 -c 1 "$TMPDIR_AUDIO/${f}_16k.wav"
done

sox "$TMPDIR_AUDIO/sam1_16k.wav" \
    "$TMPDIR_AUDIO/gap.wav" \
    "$TMPDIR_AUDIO/sam2_16k.wav" \
    "$TMPDIR_AUDIO/silence.wav" \
    "$TMPDIR_AUDIO/dan1_16k.wav" \
    "$TMPDIR_AUDIO/gap.wav" \
    "$TMPDIR_AUDIO/dan2_16k.wav" \
    "$OUTPUT"

DURATION=$(soxi -D "$OUTPUT" 2>/dev/null || echo "?")
SIZE_KB=$(( $(stat -f%z "$OUTPUT") / 1024 ))
echo "Created $OUTPUT (${DURATION}s, ${SIZE_KB}KB)"
echo "Done: $OUTPUT"
