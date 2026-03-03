#!/usr/bin/env bash
# Generate a three-speaker German test WAV for E2E diarization tests.
#
# Produces: tests/fixtures/three_speakers_de.wav (~25s, 16kHz mono)
# Requires: macOS `say` command with voices Anna, Flo, and Sandy installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE_DIR="$PROJECT_DIR/tests/fixtures"
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

echo "Assembling final WAV …"

# Concatenate with 0.8s silence gaps, resample to 16kHz mono
python3 - "$TMPDIR_AUDIO" "$OUTPUT" <<'PYEOF'
import sys
import wave
from pathlib import Path

import numpy as np

tmpdir = Path(sys.argv[1])
output = Path(sys.argv[2])
target_rate = 16000

segments_order = [
    "seg1_anna.wav",
    "seg2_flo.wav",
    "seg3_sandy.wav",
    "seg4_anna.wav",
    "seg5_flo.wav",
    "seg6_sandy.wav",
]
silence_gap = np.zeros(int(target_rate * 0.8), dtype=np.int16)  # 0.8s silence


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
        parts.append(silence_gap)

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
