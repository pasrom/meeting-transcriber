#!/usr/bin/env python3
"""Build a quality-fixture truth sidecar from AMI Meeting Corpus annotations.

Called by scripts/generate_real_meeting_fixture.sh. Reads the NXT-format manual
annotations, picks a window that starts and ends while every speaker is silent,
and writes the same `<fixture>_truth.json` shape the synthetic fixtures use.
Prints "<start> <duration>" on stdout so the caller cuts exactly the window the
JSON describes.

The window is defined by the constants below rather than rediscovered on each
run. A generator that searches is nondeterministic by construction: a corpus
mirror change or a tie between candidates would silently produce different audio
under the same fixture name, invalidating every blessed baseline row without
changing a single tracked file. They were chosen by scanning every snap-point
pair 75-105 s apart for the one with all four speakers, the most overlapping
speech and no untranscribable audio.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Excerpt definition. Changing any of these changes the fixture, so treat it as
# a breaking change: regenerate, re-measure and re-bless in one change.
TARGET_START = 948.0
TARGET_DURATION = 94.0
MIN_GAP = 0.30  # an all-speaker-silent stretch this long counts as a snap point

NITE = "{http://nite.sourceforge.net/}"

# NXT pointer syntax inside an attribute value, not markup, so it needs a regex
# even though the surrounding XML does not.
CHILD_RE = re.compile(r"#id\((?P<first>[^)]+)\)(?:\.\.id\((?P<last>[^)]+)\))?")


def read_words(anno: Path, meeting: str, speaker: str) -> tuple[list[ET.Element], dict[str, int]]:
    """Return one speaker's annotation elements in document order, plus an id index.

    The list holds every element, not just `<w>`: segments address ranges by id
    and those ranges span vocal sounds and disfluency markers, so dropping them
    here would shift the range endpoints.
    """
    root = ET.parse(anno / "words" / f"{meeting}.{speaker}.words.xml").getroot()
    elements = list(root)
    return elements, {e.get(NITE + "id"): i for i, e in enumerate(elements)}


def read_segments(anno: Path, meeting: str, speaker: str) -> list[tuple[float, float, str, str]]:
    """Return (start, end, first word id, last word id) per transcriber segment."""
    root = ET.parse(anno / "segments" / f"{meeting}.{speaker}.segments.xml").getroot()
    segments = []
    for segment in root.iter("segment"):
        child = segment.find(NITE + "child")
        if child is None:
            continue  # segment with no transcribed content
        pointer = CHILD_RE.search(child.get("href", ""))
        if pointer is None:
            continue
        first = pointer.group("first")
        segments.append((
            float(segment.get("transcriber_start")),
            float(segment.get("transcriber_end")),
            first,
            pointer.group("last") or first,
        ))
    return segments


def render(span: list[ET.Element]) -> str:
    """Join the spoken words of a segment, attaching punctuation to the word before.

    Only `<w>` is a word. Everything else the corpus interleaves (vocal sounds,
    disfluency markers, pauses, untranscribable gaps) is an annotated event with
    timings but no transcript, and must not reach the WER reference.
    """
    out: list[str] = []
    for element in span:
        if element.tag != "w" or not (element.text or "").strip():
            continue
        text = element.text.strip()
        if element.get("punc") == "true" and out:
            out[-1] += text
        else:
            out.append(text)
    return " ".join(out)


def active_seconds(turns: list[dict], minimum: int) -> float:
    """Exact seconds during which at least `minimum` turns are simultaneously active.

    Deliberately the same sweep-line the Swift fixture tests use, so the overlap
    figure printed while choosing a window is the one the tests later enforce. A
    grid approximation drifts from it, and the obvious reach-tracking walk
    double-counts three-way overlap.
    """
    edges: list[tuple[float, int]] = []
    for turn in turns:
        edges.append((turn["start"], 1))
        edges.append((turn["end"], -1))
    edges.sort()  # at equal times -1 sorts before +1, so touching turns don't count
    active = 0
    total = 0.0
    since = 0.0
    for time, delta in edges:
        if active >= minimum:
            total += time - since
        active += delta
        since = time
    return total


def silent_instants(spans: list[tuple[float, float]], min_gap: float) -> list[float]:
    """Midpoints of every stretch where no speaker is talking."""
    ordered = sorted(spans)
    instants = [max(0.0, ordered[0][0] - min_gap)]
    reach = ordered[0][1]
    for start, end in ordered[1:]:
        if start - reach >= min_gap:
            instants.append((reach + start) / 2.0)
        reach = max(reach, end)
    instants.append(reach + min_gap)
    return instants


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--annotations", required=True, type=Path)
    parser.add_argument("--meeting", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    speakers = sorted(
        path.name.split(".")[1]
        for path in (args.annotations / "words").glob(f"{args.meeting}.*.words.xml")
    )
    if not speakers:
        print(f"ERROR: no word annotations for meeting {args.meeting}", file=sys.stderr)
        return 1

    # (speaker, start, end, [elements]) for every transcribed segment.
    turns: list[tuple[str, float, float, list[ET.Element]]] = []
    for speaker in speakers:
        elements, index = read_words(args.annotations, args.meeting, speaker)
        for start, end, first, last in read_segments(args.annotations, args.meeting, speaker):
            if first not in index or last not in index:
                print(f"ERROR: {speaker} segment references unknown word id", file=sys.stderr)
                return 1
            turns.append((speaker, start, end, elements[index[first] : index[last] + 1]))

    if not turns:
        print("ERROR: no transcribed segments parsed", file=sys.stderr)
        return 1

    instants = silent_instants([(start, end) for _, start, end, _ in turns], MIN_GAP)
    start = min(instants, key=lambda t: abs(t - TARGET_START))
    target_end = start + TARGET_DURATION
    end = min((t for t in instants if t > start), key=lambda t: abs(t - target_end))
    duration = end - start

    selected = sorted(
        (t for t in turns if t[2] > start and t[1] < end),
        key=lambda t: (t[1], t[0]),
    )
    if not selected:
        print("ERROR: window contains no speech", file=sys.stderr)
        return 1

    # Restates silent_instants' contract rather than testing an independent
    # property: its snap points are midpoints of gaps in the union of all
    # speech, so no utterance can straddle one. Kept as a cheap tripwire in case
    # that function's contract is ever loosened.
    assert not [t for t in selected if t[1] < start or t[2] > end], "window clips an utterance"

    gaps = sum(1 for _, _, _, span in selected for e in span if e.tag == "gap")
    if gaps:
        print(
            f"ERROR: window contains {gaps} untranscribable <gap> element(s); "
            "pick a different TARGET_START",
            file=sys.stderr,
        )
        return 1

    json_turns = []
    for speaker, seg_start, seg_end, span in selected:
        text = render(span)
        if not text:
            continue  # segment held only vocal sounds; no words to score
        json_turns.append({
            "speaker": speaker,
            "start": round(seg_start - start, 6),
            "end": round(seg_end - start, 6),
            "text": text,
        })

    payload = {
        "fixture": args.fixture,
        "audio": f"{args.fixture}.wav",
        "duration": round(duration, 6),
        "sampleRate": 16000,
        "source": f"AMI Meeting Corpus {args.meeting} Mix-Headset, "
                  f"{start:.3f}s-{end:.3f}s, CC BY 4.0",
        "text": " ".join(t["text"] for t in json_turns),
        "turns": json_turns,
    }
    args.out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(
        f"window {start:.3f}-{end:.3f} ({duration:.3f}s): {len(json_turns)} turns, "
        f"speakers {','.join(sorted({t['speaker'] for t in json_turns}))}, "
        f"speech {active_seconds(json_turns, 1):.1f}s, "
        f"overlap {active_seconds(json_turns, 2):.1f}s",
        file=sys.stderr,
    )

    print(f"{start:.3f} {duration:.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
