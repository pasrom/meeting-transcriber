#!/usr/bin/env python3
"""Print the mean RMS level of a WAV file in dBFS.

Used by the live-recording E2E (scripts/e2e-app.sh) to assert that a captured
*track* actually carries audio — a silent-but-full-size WAV (the Teams/Zoom
"app track is all zeros" failure mode) is otherwise indistinguishable from a
real recording by file size alone.

Reads integer PCM WAV (what AudioMixer.saveWAV writes: 16-bit mono). Prints a
single float dBFS value to stdout; silence floors at -120.0. Exit code is 0 on
success, 1 on unreadable/unsupported input.

Usage:
    wav_rms.py <file.wav>
"""
import math
import sys
import wave
from array import array

SILENCE_FLOOR_DBFS = -120.0


def rms_dbfs(path: str) -> float:
    with wave.open(path, "rb") as w:
        sampwidth = w.getsampwidth()
        nframes = w.getnframes()
        raw = w.readframes(nframes)

    if nframes == 0 or not raw:
        return SILENCE_FLOOR_DBFS

    # AudioMixer.saveWAV emits 16-bit signed PCM. Support the common widths so
    # the helper stays useful if that ever changes; reject anything exotic.
    if sampwidth == 2:
        samples = array("h")  # signed 16-bit
        full_scale = 32768.0
    elif sampwidth == 4:
        samples = array("i")  # signed 32-bit
        full_scale = 2147483648.0
    elif sampwidth == 1:
        # WAV 8-bit is unsigned; recentre to signed.
        samples = array("b", bytes((b - 128) & 0xFF for b in raw))
        full_scale = 128.0
        raw = None  # already consumed
    else:
        raise ValueError(f"unsupported sample width: {sampwidth} bytes")

    if raw is not None:
        samples.frombytes(raw)

    if len(samples) == 0:
        return SILENCE_FLOOR_DBFS

    acc = 0.0
    for s in samples:
        n = s / full_scale
        acc += n * n
    mean_sq = acc / len(samples)
    if mean_sq <= 0:
        return SILENCE_FLOOR_DBFS
    return max(SILENCE_FLOOR_DBFS, 20.0 * math.log10(math.sqrt(mean_sq)))


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: wav_rms.py <file.wav>", file=sys.stderr)
        return 1
    try:
        print(f"{rms_dbfs(sys.argv[1]):.2f}")
        return 0
    except (OSError, wave.Error, ValueError) as exc:
        print(f"wav_rms: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
