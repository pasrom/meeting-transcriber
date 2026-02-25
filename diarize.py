"""
Speaker diarization via pyannote-audio.
Used by meeting_transcriber_mac.py when --diarize is active.

Features:
- Speaker diarization (who spoke when)
- Speaker recognition (match voices against saved profiles)
- Interactive name assignment for unknown speakers
"""

import json
import os
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from dotenv import load_dotenv
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn

load_dotenv()

console = Console()

SPEAKERS_DB = Path("./speakers.json")
SIMILARITY_THRESHOLD = 0.75  # cosine similarity threshold for speaker recognition
MERGE_THRESHOLD = 0.85  # cosine similarity threshold for merging duplicate speakers


@dataclass
class TimestampedSegment:
    """A Whisper segment with timing and speaker info."""

    start: float  # seconds
    end: float  # seconds
    text: str
    speaker: str = ""


# ── Speaker Database ─────────────────────────────────────────────────────────


def load_speaker_db() -> dict[str, list[float]]:
    """Load saved speaker embeddings from JSON. Returns {name: embedding_vector}."""
    if not SPEAKERS_DB.exists():
        return {}
    data = json.loads(SPEAKERS_DB.read_text(encoding="utf-8"))
    return data


def save_speaker_db(db: dict[str, list[float]]) -> None:
    """Save speaker embeddings to JSON."""
    SPEAKERS_DB.write_text(
        json.dumps(db, indent=2, ensure_ascii=False), encoding="utf-8"
    )


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    """Compute cosine similarity between two vectors."""
    norm_a = np.linalg.norm(a)
    norm_b = np.linalg.norm(b)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(np.dot(a, b) / (norm_a * norm_b))


def match_speakers(
    embeddings: dict[str, np.ndarray],
    db: dict[str, list[float]],
) -> dict[str, str]:
    """Match new speaker embeddings against saved profiles.

    Returns {pyannote_label: matched_name_or_original_label}.
    """
    mapping = {}
    used_names = set()

    for label, emb in embeddings.items():
        best_name = None
        best_score = 0.0

        for name, saved_emb in db.items():
            if name in used_names:
                continue
            score = cosine_similarity(emb, np.array(saved_emb))
            if score > best_score:
                best_score = score
                best_name = name

        if best_name and best_score >= SIMILARITY_THRESHOLD:
            mapping[label] = best_name
            used_names.add(best_name)
            console.print(
                f"  [green]Recognized:[/green] {label} → {best_name}"
                f" (similarity: {best_score:.0%})"
            )
        else:
            mapping[label] = label
            if best_name:
                console.print(
                    f"  [yellow]No match:[/yellow] {label}"
                    f" (best: {best_name} at {best_score:.0%})"
                )

    return mapping


def prompt_speaker_names(
    mapping: dict[str, str],
    embeddings: dict[str, np.ndarray],
    speaking_times: dict[str, float],
    db: dict[str, list[float]],
) -> dict[str, str]:
    """Ask the user to name unrecognized speakers and save their embeddings."""
    updated = False

    for label, current_name in sorted(mapping.items()):
        if current_name != label:
            # Already recognized
            continue

        duration = speaking_times.get(label, 0)
        minutes = int(duration // 60)
        seconds = int(duration % 60)
        time_str = f"{minutes}:{seconds:02d}" if minutes else f"{seconds}s"

        name = input(
            f"  {label} (spoke {time_str}) – assign name (Enter to skip): "
        ).strip()

        if name:
            mapping[label] = name
            db[name] = embeddings[label].tolist()
            updated = True
            console.print(f"  [green]Saved:[/green] {name}")

    if updated:
        save_speaker_db(db)
        console.print(f"[dim]Speaker profiles saved to {SPEAKERS_DB}[/dim]")

    return mapping


# ── Diarization ──────────────────────────────────────────────────────────────


def merge_similar_speakers(
    turns: list[tuple[float, float, str]],
    embeddings: dict[str, np.ndarray],
) -> tuple[list[tuple[float, float, str]], dict[str, np.ndarray]]:
    """Merge speakers with very similar embeddings (likely the same person).

    Returns updated turns and embeddings with duplicates merged.
    """
    if len(embeddings) < 2:
        return turns, embeddings

    labels = list(embeddings.keys())
    merge_map: dict[str, str] = {}

    for i, label_a in enumerate(labels):
        if label_a in merge_map:
            continue
        for label_b in labels[i + 1 :]:
            if label_b in merge_map:
                continue
            score = cosine_similarity(embeddings[label_a], embeddings[label_b])
            if score >= MERGE_THRESHOLD:
                merge_map[label_b] = label_a
                console.print(
                    f"  [dim]Merged {label_b} into {label_a}"
                    f" (similarity: {score:.0%})[/dim]"
                )

    if not merge_map:
        return turns, embeddings

    # Apply merge to turns
    merged_turns = [
        (start, end, merge_map.get(s, s)) for start, end, s in turns
    ]

    # Remove merged embeddings
    merged_embeddings = {
        k: v for k, v in embeddings.items() if k not in merge_map
    }

    return merged_turns, merged_embeddings


def diarize(
    audio_path: Path,
    num_speakers: int | None = None,
    interactive: bool = True,
) -> list[tuple[float, float, str]]:
    """Run pyannote speaker diarization with speaker recognition.

    Args:
        audio_path: Path to audio file.
        num_speakers: Expected number of speakers (helps accuracy).
        interactive: Whether to prompt for unknown speaker names.

    Returns list of (start_sec, end_sec, speaker_name) tuples.
    """
    from pyannote.audio import Pipeline

    token = os.environ.get("HF_TOKEN")

    with Progress(
        SpinnerColumn(), TextColumn("{task.description}"), transient=True
    ) as progress:
        progress.add_task("Loading diarization model ...", total=None)
        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            token=token,
        )

    console.print("[dim]Diarization model loaded. Analyzing speakers ...[/dim]")

    # Pass num_speakers hint to pyannote if provided
    pipeline_params: dict = {}
    if num_speakers:
        pipeline_params["num_speakers"] = num_speakers
        console.print(f"[dim]Expected speakers: {num_speakers}[/dim]")

    with Progress(
        SpinnerColumn(), TextColumn("{task.description}"), transient=True
    ) as progress:
        progress.add_task("Diarizing audio ...", total=None)
        result = pipeline(str(audio_path), **pipeline_params)

    # pyannote 4.x returns DiarizeOutput, 3.x returns Annotation directly
    annotation = getattr(result, "speaker_diarization", result)
    raw_embeddings = getattr(result, "speaker_embeddings", None)

    # Extract turns
    turns = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        turns.append((turn.start, turn.end, speaker))

    # Build embeddings dict {label: numpy_array}
    speaker_labels = sorted(set(t[2] for t in turns))
    embeddings: dict[str, np.ndarray] = {}
    if raw_embeddings is not None:
        for i, label in enumerate(speaker_labels):
            if i < len(raw_embeddings):
                embeddings[label] = np.array(raw_embeddings[i])

    # Auto-merge similar speakers (unless num_speakers was explicitly set)
    if not num_speakers and len(speaker_labels) > 1:
        turns, embeddings = merge_similar_speakers(turns, embeddings)
        speaker_labels = sorted(set(t[2] for t in turns))

    # Compute speaking times
    speaking_times = {}
    for label in speaker_labels:
        speaking_times[label] = sum(
            end - start for start, end, s in turns if s == label
        )

    console.print(
        f"[green]Diarization complete: {len(speaker_labels)} speakers, "
        f"{len(turns)} segments[/green]"
    )

    # Match against saved speaker profiles
    db = load_speaker_db()
    if db:
        console.print(
            f"[dim]Matching against {len(db)} saved speaker profiles ...[/dim]"
        )
    mapping = match_speakers(embeddings, db)

    # Ask for names of unrecognized speakers
    if interactive and embeddings:
        unrecognized = [l for l, n in mapping.items() if l == n]
        if unrecognized:
            console.print("\n[bold]Unknown speakers:[/bold]")
            mapping = prompt_speaker_names(mapping, embeddings, speaking_times, db)

    # Apply name mapping to turns
    named_turns = [(start, end, mapping.get(s, s) or s) for start, end, s in turns]

    return named_turns


def assign_speakers(
    segments: list[TimestampedSegment],
    turns: list[tuple[float, float, str]],
) -> list[TimestampedSegment]:
    """Assign speaker labels to Whisper segments by maximum temporal overlap."""
    for seg in segments:
        best_speaker = ""
        best_overlap = 0.0

        for turn_start, turn_end, speaker in turns:
            overlap_start = max(seg.start, turn_start)
            overlap_end = min(seg.end, turn_end)
            overlap = max(0.0, overlap_end - overlap_start)

            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = speaker

        seg.speaker = best_speaker or "UNKNOWN"

    return segments


def format_diarized_transcript(segments: list[TimestampedSegment]) -> str:
    """Format segments with speaker labels, grouping consecutive same-speaker segments."""
    if not segments:
        return ""

    lines = []
    current_speaker = None

    for seg in segments:
        if seg.speaker != current_speaker:
            current_speaker = seg.speaker
            lines.append(f"\n[{current_speaker}]")
        lines.append(seg.text.strip())

    return " ".join(lines).strip()
