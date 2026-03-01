#!/usr/bin/env bash
# Generate a two-speaker German test WAV for E2E transcription + diarization tests.
#
# Produces: tests/fixtures/two_speakers_de.wav (~15s, 16kHz mono, ~500KB)
# Requires: macOS `say` command with voices Anna and Flo installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE_DIR="$PROJECT_DIR/tests/fixtures"
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

echo "Assembling final WAV …"

# Concatenate with 1s silence gaps, resample to 16kHz mono
python3 - "$TMPDIR_AUDIO" "$OUTPUT" <<'PYEOF'
import sys
import wave
from pathlib import Path

import numpy as np

tmpdir = Path(sys.argv[1])
output = Path(sys.argv[2])
target_rate = 16000

segments_order = ["anna1.wav", "flo1.wav", "anna2.wav", "flo2.wav"]
silence_1s = np.zeros(target_rate, dtype=np.int16)  # 1s silence at 16kHz


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as wf:
        rate = wf.getframerate()
        channels = wf.getnchannels()
        raw = wf.readframes(wf.getnframes())
    samples = np.frombuffer(raw, dtype=np.int16)
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1).astype(np.int16)
    return samples, rate


def resample(samples: np.ndarray, src_rate: int, dst_rate: int) -> np.ndarray:
    if src_rate == dst_rate:
        return samples
    from math import gcd

    from scipy.signal import resample_poly

    g = gcd(src_rate, dst_rate)
    up, down = dst_rate // g, src_rate // g
    float_samples = samples.astype(np.float32) / 32768.0
    resampled = resample_poly(float_samples, up, down)
    return (np.clip(resampled, -1.0, 1.0) * 32767).astype(np.int16)


parts = []
for i, name in enumerate(segments_order):
    samples, rate = read_wav(tmpdir / name)
    samples = resample(samples, rate, target_rate)
    parts.append(samples)
    if i < len(segments_order) - 1:
        parts.append(silence_1s)

combined = np.concatenate(parts)

with wave.open(str(output), "wb") as wf:
    wf.setnchannels(1)
    wf.setsampwidth(2)
    wf.setframerate(target_rate)
    wf.writeframes(combined.tobytes())

duration = len(combined) / target_rate
size_kb = output.stat().st_size / 1024
print(f"Created {output} ({duration:.1f}s, {size_kb:.0f}KB)")
PYEOF

echo "Done: $OUTPUT"
