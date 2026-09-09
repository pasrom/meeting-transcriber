#!/usr/bin/env python3
"""Builds the two dual-source pairs for the speaker-naming switch E2E lane.

The lane reproduces the crash in issue #700: the naming dialog moves on to the
next pending job of the same meeting title, a speaker label that survives the
switch keeps its text field, and typing into that field wrote through a binding
captured at the row's OLD position. Whether that misroutes or traps depends on
where the surviving label sits in each job, and that position is decided by
diarization, not by anything a lane can set directly.

The position arithmetic, for a dual-source job. Labels are sorted, and the mic
track's `M_` labels sort ahead of the app track's `R_` labels, so the first
remote speaker sits at index (number of mic clusters). The trap needs that
index in the FIRST job to be at or past the SECOND job's total speaker count:

    mic clusters(first) >= mic clusters(second) + app clusters(second)

The app side is pinned by the lane through the "expected speakers" setting,
which forces exactly one remote cluster on both jobs. This script supplies the
mic side:

  first/<stem>_mic.wav    a genuine multi-speaker recording, so the mic track
                          clusters into several `M_` speakers
  second/<stem>_mic.wav   ONE voice, cut from a fixture whose ground truth says
                          who speaks when, so the mic track clusters into a
                          single `M_` speaker

Both pairs get the same app track and the same stem. The stem is what a paired
import uses as its meeting title, and the two jobs MUST share a title: the
naming window keys its view on the title, so a different title would give the
second job fresh fields and the retained coordinator under test would never be
exercised. Separate directories keep the resolver from merging the pairs.

The single voice is assembled from the ground-truth turns of one speaker with a
short gap between them, then repeated until it is long enough for the diarizer
to treat it as a real track rather than a fragment. Repeating the same voice
adds no speaker.

Standard library only, like make-echo-pair.py: the runner has no third-party
Python.
"""
import argparse
import array
import json
import os
import shutil
import sys
import wave


def read_mono16(path):
    """Reads a 16-bit PCM WAV as mono samples (first channel of multi-channel input)."""
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


def single_voice(source, truth, speaker, gap_seconds, min_seconds):
    """One speaker's turns from `source`, per `truth`, concatenated with gaps and
    repeated until at least `min_seconds` long."""
    samples, rate = read_mono16(source)
    with open(truth) as f:
        turns = [t for t in json.load(f)["turns"] if t["speaker"] == speaker]
    if not turns:
        sys.exit(f"{truth}: no turns for speaker {speaker!r}")
    gap = array.array("h", [0] * int(gap_seconds * rate))
    voice = array.array("h")
    for turn in turns:
        start = int(turn["start"] * rate)
        end = min(int(turn["end"] * rate), len(samples))
        voice.extend(samples[start:end])
        voice.extend(gap)
    if not voice:
        sys.exit(f"{truth}: turns for speaker {speaker!r} are empty in {source}")
    out = array.array("h")
    while len(out) < min_seconds * rate:
        out.extend(voice)
    return out, rate, len(turns)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--app", required=True, help="app track shared by both pairs")
    parser.add_argument("--mic-first", required=True, help="multi-speaker mic track for the first pair")
    parser.add_argument("--voice-source", required=True, help="fixture the single voice is cut from")
    parser.add_argument("--voice-truth", required=True, help="ground-truth JSON with that fixture's turns")
    parser.add_argument("--voice-speaker", default="B", help="which speaker of the truth to keep (default B)")
    parser.add_argument("--voice-seconds", type=float, default=20.0, help="minimum length of the single-voice track")
    parser.add_argument("--gap-seconds", type=float, default=0.5, help="silence between the kept turns")
    parser.add_argument("--out", required=True, help="output directory; gets first/ and second/")
    parser.add_argument("--stem", default="meeting", help="basename shared by both pairs (becomes the meeting title)")
    args = parser.parse_args()

    for path in (args.app, args.mic_first, args.voice_source, args.voice_truth):
        if not os.path.isfile(path):
            sys.exit(f"missing input: {path}")

    first = os.path.join(args.out, "first")
    second = os.path.join(args.out, "second")
    os.makedirs(first, exist_ok=True)
    os.makedirs(second, exist_ok=True)

    shutil.copyfile(args.app, os.path.join(first, f"{args.stem}_app.wav"))
    shutil.copyfile(args.mic_first, os.path.join(first, f"{args.stem}_mic.wav"))
    shutil.copyfile(args.app, os.path.join(second, f"{args.stem}_app.wav"))

    voice, rate, turns = single_voice(
        args.voice_source, args.voice_truth, args.voice_speaker, args.gap_seconds, args.voice_seconds,
    )
    write_mono16(os.path.join(second, f"{args.stem}_mic.wav"), voice, rate)

    print(f"first:  app={os.path.basename(args.app)} mic={os.path.basename(args.mic_first)}")
    print(
        f"second: app={os.path.basename(args.app)} mic=speaker {args.voice_speaker} of "
        f"{os.path.basename(args.voice_source)} ({turns} turns, {len(voice) / rate:.1f} s)"
    )


if __name__ == "__main__":
    main()
