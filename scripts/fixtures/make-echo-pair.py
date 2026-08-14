#!/usr/bin/env python3
"""Builds a dual-source recording pair for the echo-bleed E2E lane.

The lane needs a recording whose microphone track carries the remote voices
back from the loudspeaker. That cannot be produced on the CI Mac mini: it has
no microphone at all, only a virtual input device, so there is no acoustic path
to bleed through. Synthesising the pair is not a workaround for that but the
better instrument anyway, because it makes the expected verdict exact instead of
dependent on the room the runner happens to sit in.

Two tracks come out:

  <stem>_app.wav   the remote side, taken from --app unchanged
  <stem>_mic.wav   the local side: --local, plus (in the bleed case) a delayed
                   and attenuated copy of the app track

The clean control differs from the affected pair by exactly that one term, so a
lane running both cannot pass by measuring anything other than the bleed.

The local side is gated into short bursts rather than played end to end,
because someone in a call is mostly listening. That is not decoration: with a
continuous local voice at full level the microphone envelope follows the local
speaker and the bleed never dominates any window, so a pair built that way
measures as clean at every plausible bleed gain. Room tone would sit under the
gaps in a real recording; leaving them empty only makes the affected case
cleaner to reason about, and the control is gated identically.

Standard library only: the runner has no third-party Python and this must not
grow a dependency to keep working.

Measured with the defaults below, app=two_speakers_de.wav (49.8 s),
local=three_speakers_de.wav, against the detector's own thresholds (per-window
correlation 0.7 over 10 s windows):

  --bleed 0    per-window 0.351, -0.222, 0.264, -0.050  → 0 of 4, not detected
  --bleed 1.0  per-window 0.787,  0.833, 0.870,  0.918  → 4 of 4, detected

Both margins are wide, and they are wide in opposite directions, which is the
property the lane depends on. The bleed gain sits near unity rather than well
below it because that is what an affected recording looks like: a microphone a
few centimetres from the loudspeaker hears the remote side about as loudly as
the person sitting at the machine. Below roughly 0.7 the local voice dominates
every window and the pair measures as clean, which is a fact about the fixture,
not about the detector.

Usage:
  make-echo-pair.py --app A.wav --local B.wav --out DIR [--stem NAME]
                    [--bleed GAIN] [--delay-ms MS]

--bleed 0 produces the clean control.
"""
import argparse
import array
import os
import sys
import wave


def read_mono16(path):
    """Reads a 16-bit PCM WAV as mono samples. Multi-channel input is reduced
    to its first channel rather than downmixed: these are test fixtures, and a
    downmix would quietly change the very envelope being measured."""
    with wave.open(path, "rb") as w:
        if w.getsampwidth() != 2:
            sys.exit(f"{path}: expected 16-bit PCM, got {w.getsampwidth() * 8}-bit")
        rate = w.getframerate()
        channels = w.getnchannels()
        raw = w.readframes(w.getnframes())
    samples = array.array("h")
    samples.frombytes(raw)
    if channels > 1:
        samples = array.array("h", samples[::channels])
    return samples, rate


def write_mono16(path, samples, rate):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(samples.tobytes())


def tiled(src, count):
    """Repeats `src` up to `count` samples. The local track only has to be as
    long as the remote one; which words it repeats does not matter, since the
    detector correlates envelopes between the two tracks and never within one."""
    out = array.array("h", bytes(2 * count))
    length = len(src)
    for i in range(count):
        out[i] = src[i % length]
    return out


def gate(samples, rate, burst_seconds, gap_seconds):
    """Silences everything outside a repeating burst, with a short fade at each
    edge so the cut does not add a click. In place."""
    if burst_seconds <= 0 or gap_seconds <= 0:
        return samples
    period = int(round((burst_seconds + gap_seconds) * rate))
    burst = int(round(burst_seconds * rate))
    fade = min(int(0.020 * rate), burst // 2)
    for i in range(len(samples)):
        pos = i % period
        if pos >= burst:
            samples[i] = 0
        elif pos < fade:
            samples[i] = int(samples[i] * pos / fade)
        elif pos > burst - fade:
            samples[i] = int(samples[i] * (burst - pos) / fade)
    return samples


def clamp(value):
    return -32768 if value < -32768 else (32767 if value > 32767 else value)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", required=True, help="source WAV for the remote (app-audio) track")
    p.add_argument("--local", required=True, help="source WAV for the local (microphone) track")
    p.add_argument("--out", required=True, help="output directory (created if absent)")
    p.add_argument("--stem", default="echo", help="basename stem; files are <stem>_app.wav / <stem>_mic.wav")
    p.add_argument("--bleed", type=float, default=0.0,
                   help="linear gain of the app track bled into the mic track; 0 = clean control")
    p.add_argument("--delay-ms", type=float, default=15.0,
                   help="how far the bleed lags the app track, in milliseconds")
    # 1.5 on / 7.5 off: the period stays under one 10 s analysis window, so every
    # window of the clean control carries local speech. A control window that is
    # entirely silent has a flat envelope, gets skipped as carrying no evidence,
    # and would shrink the control's scored count towards the minimum a verdict
    # needs — turning a "measured clean" assertion into "measured nothing".
    p.add_argument("--local-burst", type=float, default=1.5,
                   help="seconds the local side speaks per turn (0 disables gating)")
    p.add_argument("--local-gap", type=float, default=7.5,
                   help="seconds the local side listens between turns")
    args = p.parse_args()

    app, app_rate = read_mono16(args.app)
    local, local_rate = read_mono16(args.local)
    if app_rate != local_rate:
        sys.exit(f"sample rates differ: {args.app} is {app_rate} Hz, {args.local} is {local_rate} Hz")
    if not app:
        sys.exit(f"{args.app}: no samples")

    count = len(app)
    mic = gate(tiled(local, count), app_rate, args.local_burst, args.local_gap)

    if args.bleed > 0:
        delay = int(round(args.delay_ms * app_rate / 1000.0))
        for i in range(delay, count):
            mic[i] = clamp(int(mic[i] + args.bleed * app[i - delay]))

    os.makedirs(args.out, exist_ok=True)
    app_path = os.path.join(args.out, f"{args.stem}_app.wav")
    mic_path = os.path.join(args.out, f"{args.stem}_mic.wav")
    write_mono16(app_path, app, app_rate)
    write_mono16(mic_path, mic, app_rate)

    seconds = count / float(app_rate)
    kind = f"bleed gain={args.bleed} delay={args.delay_ms}ms" if args.bleed > 0 else "clean control"
    print(f"{app_path}\n{mic_path}\n{seconds:.1f}s @ {app_rate} Hz, {kind}")


if __name__ == "__main__":
    main()
