#!/usr/bin/env bash
# Regenerate the phone/messenger voice-format fixtures, so they are
# reproducible instead of mystery blobs.
#
# Produces in app/MeetingTranscriber/Tests/Fixtures/:
#   two_speakers_de.opus  — Ogg Opus, first 5 s of two_speakers_de.wav (~12 KB),
#                           the format messengers and voice recorders write
#   two_speakers_de.3gp   — AAC-in-3GP, 5 s at 16 kHz (~20 KB). Deliberately at
#                           the pipeline's target rate so it also exercises the
#                           AudioMixer.resampleFile byte-copy fast path
#   synthetic_amrnb.amr   — raw AMR-NB, 3 s (~4.8 KB)
#   synthetic_amrnb.3gp   — the same AMR-NB stream muxed into 3GP, the
#                           container/codec pair smartphone call recorders use
#
# Five seconds is enough for every assertion made about these (sample rate,
# non-silence, duration, decode-without-ffmpeg); the speech-content fixtures for
# WER/DER work live under Fixtures/quality/ instead.
#
# Requires: ffmpeg (brew install ffmpeg) and python3.
#
# Why AMR is synthesized rather than encoded: macOS can no longer *encode* AMR
# (`afconvert -f amrf -d samr` fails with 'fmt?') and Homebrew's ffmpeg ships AMR
# decoders only, so no encoder exists on a stock dev machine. The AMR-NB storage
# format is trivial to emit by hand, though: a magic header plus one 32-byte
# frame per 20 ms. Zero-payload frames decode to stable low-level comfort noise,
# which is all the decode path needs to be exercised.
set -euo pipefail

command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: ffmpeg is required. Install with: brew install ffmpeg"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE_DIR="$PROJECT_DIR/app/MeetingTranscriber/Tests/Fixtures"
SOURCE="$FIXTURE_DIR/two_speakers_de.wav"
CLIP_SECONDS=5

[ -f "$SOURCE" ] || { echo "ERROR: missing source fixture $SOURCE"; exit 1; }

echo "Encoding Ogg Opus …"
ffmpeg -hide_banner -loglevel error -y -i "$SOURCE" -t "$CLIP_SECONDS" \
    -c:a libopus -b:a 24k "$FIXTURE_DIR/two_speakers_de.opus"

echo "Encoding AAC-in-3GP at 16 kHz …"
ffmpeg -hide_banner -loglevel error -y -i "$SOURCE" -t "$CLIP_SECONDS" \
    -c:a aac -b:a 32k -ar 16000 "$FIXTURE_DIR/two_speakers_de.3gp"

echo "Synthesizing AMR-NB …"
python3 - "$FIXTURE_DIR/synthetic_amrnb.amr" <<'PY'
import sys

# AMR-NB storage format (RFC 4867 section 5): magic, then per 20 ms frame one
# TOC byte followed by the mode's payload. 0x3C = mode 7 (12.2 kbps) with the
# quality bit set; mode 7 carries 31 payload bytes.
FRAMES = 150  # 150 * 20 ms = 3 s
data = bytearray(b"#!AMR\n")
for _ in range(FRAMES):
    data.append(0x3C)
    data.extend(b"\x00" * 31)
with open(sys.argv[1], "wb") as f:
    f.write(bytes(data))
PY

echo "Muxing AMR-NB into 3GP …"
ffmpeg -hide_banner -loglevel error -y -i "$FIXTURE_DIR/synthetic_amrnb.amr" \
    -c:a copy "$FIXTURE_DIR/synthetic_amrnb.3gp"

echo "Done:"
ls -lh "$FIXTURE_DIR/two_speakers_de.opus" "$FIXTURE_DIR/two_speakers_de.3gp" \
    "$FIXTURE_DIR/synthetic_amrnb.amr" "$FIXTURE_DIR/synthetic_amrnb.3gp"
