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

The bleed is not a multiplication. A loudspeaker stands in a room and the call
app runs its own gain control, so two terms ride on top of the delayed copy:
a decaying tail (--reverb-ms) and a slow swing of the level (--agc-depth,
--agc-period). Both default to on, and the reason is a measurement rather than
realism for its own sake.

Measured on a real 10.8 minute Teams call over loudspeakers, then replicated
against a pair built without those two terms:

                          residual median   read as removable
  purely linear bleed          0.114              65%
  with room and gain drift     0.425              26%
  the real call                0.494               5%

A pair built the linear way is separable by a single fitted gain almost
everywhere, so a classifier that fits one gain scores near zero residual and
removes nearly everything. That is a property of the fixture. On real material
the same classifier removes a small fraction, because the level it must predict
drifts and the tail arrives where no single delayed copy puts it. A lane running
the linear pair therefore cannot fail the way the field fails, which is the one
thing a lane is for.

Detection is unaffected by either term and the control stays clean, so the two
properties the lane rests on survive: the affected pair is still detected in
every window, the control in none.

The local side is gated into short bursts rather than played end to end,
because someone in a call is mostly listening. That is not decoration: with a
continuous local voice at full level the microphone envelope follows the local
speaker and the bleed never dominates any window, so a pair built that way
measures as clean at every plausible bleed gain. Room tone would sit under the
gaps in a real recording; leaving them empty only makes the affected case
cleaner to reason about, and the control is gated identically.

The far end can be gated the same way, with --app-burst and --app-gap, and that
one is off by default. It exists for the cancellation lane rather than the
detection lane: the canceller's self-check is a difference between the windows
where the far end was playing and the windows where it was not, so a fixture
whose far end never stops offers no control group and the check refuses to
confirm the run. Measured on the ungated pair below: 42 of 50 one-second windows
carry far-end audio and only 8 do not, which is under the ten the check needs on
each side, and the run comes back unjudgeable however well it worked. At
--app-burst 2.5 --app-gap 2.5 the same pair splits 25 to 25, and the natural
pauses inside the source add to the gate's rather than fighting it.

Standard library only: the runner has no third-party Python and this must not
grow a dependency to keep working.

Measured by the lane itself with the defaults below, app=two_speakers_de.wav
(49.8 s), local=three_speakers_de.wav:

  --bleed 0    0 of 4 windows affected  → not detected, 0 segments removed
  --bleed 1.0  4 of 4 windows affected  → detected,     4 segments removed

Both margins are wide, and they are wide in opposite directions, which is the
property the lane depends on. The removal count is reported rather than
asserted at that exact value: it is a yield, and a yield moves with the ASR.
What the lane pins is that the affected pair loses segments and the control
loses none. Against the linear pair the same run removed 10 and left a 15 line
transcript, against this one it removes 4 and leaves 20 — the same classifier,
the same source audio, and the difference is entirely the two terms above.

The bleed gain sits near unity rather than well below it because that is what
an affected recording looks like: a microphone a few centimetres from the
loudspeaker hears the remote side about as loudly as the person sitting at the
machine. Below roughly 0.7 the local voice dominates
every window and the pair measures as clean, which is a fact about the fixture,
not about the detector.

With the far end gated 2.5 s on / 2.5 s off, same two sources, measured through
the production detector and the production canceller:

  --bleed 1.0  4 of 4 windows affected, window correlations 0.72 to 0.83
               canceller: 66.5 dB median where the far end plays, -0.0 dB where
               it does not, self-check says removed
  --bleed 0    0 of 4 windows affected, hottest window 0.31 against a 0.7 bar

The correlations sit closer to the 0.7 bar than the ungated pair's do, which
costs nothing: what the verdict rests on is the share of affected windows, and
at 4 of 4 it would survive losing two of them.

Usage:
  make-echo-pair.py --app A.wav --local B.wav --out DIR [--stem NAME]
                    [--bleed GAIN] [--delay-ms MS]
                    [--app-burst S --app-gap S]

--bleed 0 produces the clean control.
"""
import argparse
import array
import math
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
    detector correlates envelopes between the two tracks and never within one.

    Whole-array repetition rather than a per-sample loop: at 16 kHz these are
    hundreds of thousands of samples and the loop dominated the run."""
    repeats = -(-count // len(src))
    return (src * repeats)[:count]


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


def reverberate(samples, rate, rt60_ms, count):
    """Adds a decaying tail to a float copy of `samples`, in place.

    Why this exists: a real loudspeaker sits in a room, so what the microphone
    picks up is not the app track scaled by one number, it is that track plus
    its own reflections arriving over the next tens of milliseconds. Without a
    tail the microphone envelope is a scaled copy of the app envelope at every
    instant, and a predictor that fits one gain reproduces it essentially
    exactly. That is a property of the fixture, not of the detector, and it is
    the reason a pair built the old way could not fail the way a field
    recording does.

    Three feedback combs in series rather than a convolution with a measured
    impulse response: the runner has no third-party Python, and a dense FIR over
    a 50 s track at 16 kHz is minutes of pure-Python multiply-adds. Each comb is
    one pass and one multiply per sample, and three of them in series already
    produce a tail dense enough that no single delayed copy explains it. The
    delays are mutually prime in samples so their repetitions do not line up
    into an audible flutter, and the feedbacks are set from `rt60_ms` so the
    tail decays by 60 dB in about that time.

    The direct path keeps gain exactly 1: a comb only ever ADDS delayed copies,
    so samples before the shortest delay are untouched. `--bleed` therefore
    still means what it meant before, the level of the direct arrival, and the
    tail sits on top of it the way a room puts it there.
    """
    if rt60_ms <= 0:
        return samples
    for delay_ms in (37.0, 53.0, 71.0):
        delay = int(round(delay_ms * rate / 1000.0))
        if delay <= 0 or delay >= count:
            continue
        # 60 dB of decay over rt60 for a comb of this delay.
        feedback = 10.0 ** (-3.0 * delay_ms / rt60_ms)
        for i in range(delay, count):
            samples[i] += feedback * samples[i - delay]
    return samples


def drift_gain(bleed, depth, period_seconds, index, rate):
    """The bleed gain at one sample, slowly modulated around `bleed`.

    A call app runs its own automatic gain control on what it plays out, so the
    level the microphone picks up from the loudspeaker is not constant across a
    meeting. Measured on a real 10.8 minute Teams call over loudspeakers: the
    per-window loudspeaker-to-microphone ratio spans roughly 0.67 to 1.37, a
    factor of about 2.1 between its low and high deciles.

    `depth` is half that spread, so the default reproduces the measured factor:
    (1 + depth) / (1 - depth) with depth 0.35 is 2.08. A sine rather than steps,
    because the thing being modelled is a control loop settling, not a switch.
    """
    if depth <= 0 or period_seconds <= 0:
        return bleed
    phase = 2.0 * math.pi * (index / float(rate)) / period_seconds
    return bleed * (1.0 + depth * math.sin(phase))


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
    # Why the far end pauses at all is in the module docstring. Off by default
    # for a reason local to these two numbers: gating costs per-window envelope
    # correlation, 0.72 to 0.83 against a 0.7 bar where the ungated pair sits
    # higher, and the detection lane quotes its own calibration in its failure
    # messages. Moving that lane onto thinner margin to save one flag is a worse
    # trade than carrying two parameter sets.
    p.add_argument("--app-burst", type=float, default=0.0,
                   help="seconds the far end speaks per turn (0 disables gating)")
    p.add_argument("--app-gap", type=float, default=0.0,
                   help="seconds the far end pauses between turns")
    # The two terms that make the bleed behave like a room instead of like a
    # multiplication. Both default to the values measured on a real call rather
    # than to off: a fixture whose whole job is to stand in for an affected
    # recording should carry what an affected recording carries. Pass 0 to
    # either one to get the previous purely linear bleed back, which is what the
    # unit-level tests want when they need an exactly predictable pair.
    p.add_argument("--reverb-ms", type=float, default=180.0,
                   help="RT60 of the tail the room adds to the bleed, in ms (0 disables)")
    p.add_argument("--agc-depth", type=float, default=0.35,
                   help="relative swing of the bleed gain around --bleed (0 disables)")
    p.add_argument("--agc-period", type=float, default=20.0,
                   help="seconds for one full swing of the bleed gain")
    args = p.parse_args()

    app, app_rate = read_mono16(args.app)
    local, local_rate = read_mono16(args.local)
    if app_rate != local_rate:
        sys.exit(f"sample rates differ: {args.app} is {app_rate} Hz, {args.local} is {local_rate} Hz")
    if not app:
        sys.exit(f"{args.app}: no samples")
    if not local:
        # Mirrors the check above: without it the tiling divides by zero and the
        # lane reports a Python traceback instead of which file was empty.
        sys.exit(f"{args.local}: no samples")

    # Gated before anything derives from it, so the written far-end track and the
    # bleed built out of it carry the same pauses: a loudspeaker is silent while
    # the far end is.
    app = gate(app, app_rate, args.app_burst, args.app_gap)

    count = len(app)
    mic = gate(tiled(local, count), app_rate, args.local_burst, args.local_gap)

    if args.bleed > 0:
        # Build the bled path in floats first, then add it in once. Reverberating
        # in place on the 16-bit track would requantise the tail at every comb,
        # and the tail is exactly the quiet part being modelled.
        path = [float(sample) for sample in app]
        reverberate(path, app_rate, args.reverb_ms, count)
        delay = int(round(args.delay_ms * app_rate / 1000.0))
        for i in range(delay, count):
            gain = drift_gain(args.bleed, args.agc_depth, args.agc_period, i, app_rate)
            mic[i] = clamp(int(mic[i] + gain * path[i - delay]))

    os.makedirs(args.out, exist_ok=True)
    app_path = os.path.join(args.out, f"{args.stem}_app.wav")
    mic_path = os.path.join(args.out, f"{args.stem}_mic.wav")
    write_mono16(app_path, app, app_rate)
    write_mono16(mic_path, mic, app_rate)

    seconds = count / float(app_rate)
    if args.bleed > 0:
        kind = (f"bleed gain={args.bleed} delay={args.delay_ms}ms "
                f"reverb={args.reverb_ms}ms agc={args.agc_depth}/{args.agc_period}s")
    else:
        kind = "clean control"
    if args.app_burst > 0 and args.app_gap > 0:
        kind += f", far end gated {args.app_burst}s on / {args.app_gap}s off"
    print(f"{app_path}\n{mic_path}\n{seconds:.1f}s @ {app_rate} Hz, {kind}")


if __name__ == "__main__":
    main()
