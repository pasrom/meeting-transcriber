"""
Speaker diarization via pyannote-audio.

Features:
- Speaker diarization (who spoke when)
- Speaker recognition (match voices against saved profiles)
- Interactive name assignment for unknown speakers
"""

import fcntl
import json
import logging
import os
import shutil
import subprocess
import sys
import time
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn

log = logging.getLogger(__name__)

console = Console()

SIMILARITY_THRESHOLD = 0.75  # cosine similarity threshold for speaker recognition
MERGE_THRESHOLD = 0.92  # cosine similarity threshold for merging duplicate speakers


def _get_speakers_db() -> Path:
    """Return path to speakers.json, respecting bundle mode."""
    from meeting_transcriber.config import get_data_dir

    return get_data_dir() / "speakers.json"


@dataclass
class TimestampedSegment:
    """A Whisper segment with timing and speaker info."""

    start: float  # seconds
    end: float  # seconds
    text: str
    speaker: str = ""


# ── Speaker Database ─────────────────────────────────────────────────────────


def load_speaker_db(db_path: Path | None = None) -> dict[str, list[float]]:
    """Load saved speaker embeddings from JSON. Returns {name: embedding_vector}.

    Normalizes names to capitalize() and merges duplicates by averaging embeddings.
    Uses shared file lock to prevent corruption from concurrent access.
    """
    if db_path is None:
        db_path = _get_speakers_db()
    if not db_path.exists():
        return {}
    with open(db_path, encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_SH)
        try:
            raw = json.load(f)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)

    # Merge entries that differ only by case
    merged: dict[str, list[list[float]]] = {}
    for name, emb in raw.items():
        key = " ".join(w.capitalize() for w in name.split())
        merged.setdefault(key, []).append(emb)

    db = {}
    for name, embs in merged.items():
        if len(embs) == 1:
            db[name] = embs[0]
        else:
            db[name] = np.mean(embs, axis=0).tolist()
            console.print(f"[dim]Merged {len(embs)} profiles for '{name}'[/dim]")

    # Persist cleanup if any merges happened
    if len(db) < len(raw):
        save_speaker_db(db, db_path)

    return db


def save_speaker_db(db: dict[str, list[float]], db_path: Path | None = None) -> None:
    """Save speaker embeddings to JSON.

    Uses exclusive file lock to prevent corruption from concurrent access.
    """
    if db_path is None:
        db_path = _get_speakers_db()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with open(db_path, "w", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            json.dump(db, f, indent=2, ensure_ascii=False)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


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


def play_speaker_sample(
    audio_path: Path,
    turns: list[tuple[float, float, str]],
    speaker_label: str,
    max_duration: float = 10.0,
) -> None:
    """Play a representative audio sample for a speaker."""
    import sounddevice as sd

    # Find the longest segment for this speaker (most representative)
    speaker_turns = [(s, e) for s, e, spk in turns if spk == speaker_label]
    if not speaker_turns:
        return

    speaker_turns.sort(key=lambda t: t[1] - t[0], reverse=True)
    start, end = speaker_turns[0]
    # Limit playback duration
    end = min(end, start + max_duration)

    with wave.open(str(audio_path), "rb") as wf:
        sr = wf.getframerate()
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()

        start_frame = int(start * sr)
        end_frame = int(end * sr)
        wf.setpos(start_frame)
        frames = wf.readframes(end_frame - start_frame)

    dtype = {1: np.int8, 2: np.int16, 4: np.int32}.get(sampwidth, np.int16)
    audio = np.frombuffer(frames, dtype=dtype)
    if n_channels > 1:
        audio = audio.reshape(-1, n_channels)

    sd.play(audio, samplerate=sr)
    sd.wait()


def prompt_speaker_names(
    mapping: dict[str, str],
    embeddings: dict[str, np.ndarray],
    speaking_times: dict[str, float],
    turns: list[tuple[float, float, str]],
    audio_path: Path,
    db: dict[str, list[float]],
    db_path: Path | None = None,
) -> dict[str, str]:
    """Play audio samples and let user name or confirm all speakers."""
    if db_path is None:
        db_path = _get_speakers_db()
    updated = False

    for label, current_name in sorted(mapping.items()):
        recognized = current_name != label

        duration = speaking_times.get(label, 0)
        minutes = int(duration // 60)
        seconds = int(duration % 60)
        time_str = f"{minutes}:{seconds:02d}" if minutes else f"{seconds}s"

        # Play audio sample so user can identify the speaker
        console.print(f"  [dim]Playing sample for {label} ...[/dim]")
        try:
            play_speaker_sample(audio_path, turns, label)
        except Exception as e:
            console.print(f"  [yellow]Could not play audio: {e}[/yellow]")

        if recognized:
            prompt = (
                f"  {label} (spoke {time_str}) → [bold]{current_name}[/bold]"
                f" – Enter=accept, p=replay, or type new name: "
            )
        else:
            prompt = (
                f"  {label} (spoke {time_str}) – name (p=replay, p15=15s, Enter=skip): "
            )
        name = input(prompt).strip()
        while name.lower().startswith("p") and not name[1:].isalpha():
            dur = 10.0
            if len(name) > 1 and name[1:].isdigit():
                dur = float(name[1:])
            try:
                play_speaker_sample(audio_path, turns, label, dur)
            except Exception as e:
                console.print(f"  [yellow]Could not play: {e}[/yellow]")
            name = input(prompt).strip()

        if name:
            name = " ".join(w.capitalize() for w in name.split())
            mapping[label] = name
            if label in embeddings:
                db[name] = embeddings[label].tolist()
                updated = True
            console.print(f"  [green]Saved:[/green] {name}")
        elif recognized:
            console.print(f"  [green]Confirmed:[/green] {current_name}")

    if updated:
        save_speaker_db(db, db_path)
        console.print(f"[dim]Speaker profiles saved to {db_path}[/dim]")

    return mapping


# ── Status helpers (avoid circular import) ───────────────────────────────────


def _status_enabled() -> bool:
    """Check if the status emitter is active (menu bar app mode)."""
    from meeting_transcriber import status

    return status._enabled


def _emit_status(state: str, **kwargs) -> None:
    """Emit a status update if the status emitter is active."""
    from meeting_transcriber import status

    status.emit(state, **kwargs)


# ── Speaker Naming IPC (menu bar app) ────────────────────────────────────────


def extract_speaker_samples(
    audio_path: Path,
    turns: list[tuple[float, float, str]],
    output_dir: Path,
    max_duration: float = 10.0,
) -> dict[str, str]:
    """Extract a WAV clip per speaker (longest turn, max 10s, 16kHz mono).

    Returns {speaker_label: filename}.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    speaker_labels = sorted(set(t[2] for t in turns))
    samples: dict[str, str] = {}

    with wave.open(str(audio_path), "rb") as wf:
        sr = wf.getframerate()
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()

        for label in speaker_labels:
            speaker_turns = [(s, e) for s, e, spk in turns if spk == label]
            if not speaker_turns:
                continue

            # Pick the longest turn
            speaker_turns.sort(key=lambda t: t[1] - t[0], reverse=True)
            start, end = speaker_turns[0]
            end = min(end, start + max_duration)

            start_frame = int(start * sr)
            end_frame = int(end * sr)
            wf.setpos(start_frame)
            frames = wf.readframes(end_frame - start_frame)

            dtype = {1: np.int8, 2: np.int16, 4: np.int32}.get(sampwidth, np.int16)
            audio = np.frombuffer(frames, dtype=dtype)
            if n_channels > 1:
                audio = audio.reshape(-1, n_channels).mean(axis=1).astype(dtype)

            filename = f"{label}.wav"
            out_path = output_dir / filename
            with wave.open(str(out_path), "wb") as out_wf:
                out_wf.setnchannels(1)
                out_wf.setsampwidth(sampwidth)
                out_wf.setframerate(sr)
                out_wf.writeframes(audio.tobytes())

            samples[label] = filename

    return samples


def write_speaker_request(
    mapping: dict[str, str],
    embeddings: dict[str, np.ndarray],
    speaking_times: dict[str, float],
    audio_path: Path,
    turns: list[tuple[float, float, str]],
    meeting_title: str,
    expected_names: list[str] | None = None,
) -> None:
    """Extract audio samples and write speaker_request.json for the menu bar app."""
    from meeting_transcriber.config import SPEAKER_REQUEST_FILE, SPEAKER_SAMPLES_DIR

    samples = extract_speaker_samples(audio_path, turns, SPEAKER_SAMPLES_DIR)

    speakers = []
    for label in sorted(mapping.keys()):
        auto_name = mapping[label] if mapping[label] != label else None
        # Compute confidence from embeddings (use best match score)
        confidence = 0.0
        if auto_name and label in embeddings:
            db = load_speaker_db()
            if auto_name in db:
                confidence = cosine_similarity(
                    embeddings[label], np.array(db[auto_name])
                )

        speakers.append(
            {
                "label": label,
                "auto_name": auto_name,
                "confidence": round(confidence, 2),
                "speaking_time_seconds": round(speaking_times.get(label, 0), 1),
                "sample_file": samples.get(label, ""),
            }
        )

    data = {
        "version": 1,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "meeting_title": meeting_title,
        "audio_samples_dir": str(SPEAKER_SAMPLES_DIR),
        "speakers": speakers,
        "expected_names": expected_names or [],
    }

    SPEAKER_REQUEST_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = SPEAKER_REQUEST_FILE.with_suffix(".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, SPEAKER_REQUEST_FILE)
    log.info("Wrote speaker request: %s", SPEAKER_REQUEST_FILE)


def poll_speaker_response(timeout: int = 300) -> dict[str, str] | None:
    """Poll for speaker_response.json (written by the Swift app).

    Returns speaker mapping {label: name} or None on timeout.
    """
    from meeting_transcriber.config import SPEAKER_RESPONSE_FILE

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if SPEAKER_RESPONSE_FILE.exists():
            try:
                with open(SPEAKER_RESPONSE_FILE, encoding="utf-8") as f:
                    data = json.load(f)
                return data.get("speakers", {})
            except (json.JSONDecodeError, OSError) as e:
                log.warning("Failed to read speaker response: %s", e)
                return None
        time.sleep(2)

    log.info("Speaker naming timed out after %ds", timeout)
    return None


def cleanup_speaker_ipc() -> None:
    """Remove IPC files and speaker samples directory."""
    from meeting_transcriber.config import (
        SPEAKER_REQUEST_FILE,
        SPEAKER_RESPONSE_FILE,
        SPEAKER_SAMPLES_DIR,
    )

    for f in (SPEAKER_REQUEST_FILE, SPEAKER_RESPONSE_FILE):
        try:
            f.unlink(missing_ok=True)
        except OSError:
            pass
    if SPEAKER_SAMPLES_DIR.exists():
        shutil.rmtree(SPEAKER_SAMPLES_DIR, ignore_errors=True)


# ── Speaker Count IPC (ask before diarization) ───────────────────────────────


def write_speaker_count_request(meeting_title: str) -> None:
    """Write speaker_count_request.json for the menu bar app."""
    from meeting_transcriber.config import SPEAKER_COUNT_REQUEST_FILE

    data = {
        "version": 1,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "meeting_title": meeting_title,
    }

    SPEAKER_COUNT_REQUEST_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = SPEAKER_COUNT_REQUEST_FILE.with_suffix(".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, SPEAKER_COUNT_REQUEST_FILE)
    log.info("Wrote speaker count request: %s", SPEAKER_COUNT_REQUEST_FILE)


def poll_speaker_count_response(timeout: int = 120) -> int | None:
    """Poll for speaker_count_response.json (written by the Swift app).

    Returns speaker count (0 = auto-detect) or None on timeout.
    """
    from meeting_transcriber.config import SPEAKER_COUNT_RESPONSE_FILE

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if SPEAKER_COUNT_RESPONSE_FILE.exists():
            try:
                with open(SPEAKER_COUNT_RESPONSE_FILE, encoding="utf-8") as f:
                    data = json.load(f)
                return data.get("speaker_count", 0)
            except (json.JSONDecodeError, OSError) as e:
                log.warning("Failed to read speaker count response: %s", e)
                return None
        time.sleep(2)

    log.info("Speaker count request timed out after %ds", timeout)
    return None


def cleanup_speaker_count_ipc() -> None:
    """Remove speaker count IPC files."""
    from meeting_transcriber.config import (
        SPEAKER_COUNT_REQUEST_FILE,
        SPEAKER_COUNT_RESPONSE_FILE,
    )

    for f in (SPEAKER_COUNT_REQUEST_FILE, SPEAKER_COUNT_RESPONSE_FILE):
        try:
            f.unlink(missing_ok=True)
        except OSError:
            pass


# ── Token Resolution ─────────────────────────────────────────────────────────


def _resolve_hf_token() -> str:
    """Resolve HuggingFace token with fallback chain.

    Priority:
    1. HF_TOKEN environment variable (set by Swift app or manually exported)
    2. .env file via python-dotenv (legacy)
    3. macOS Keychain via `security` CLI
    4. RuntimeError with helpful message
    """
    # 1. Already in environment (e.g. injected by Swift PythonProcess)
    token = os.environ.get("HF_TOKEN")
    if token:
        return token

    # 2. Legacy .env file
    from dotenv import load_dotenv

    load_dotenv()
    token = os.environ.get("HF_TOKEN")
    if token:
        return token

    # 3. macOS Keychain (only on macOS)
    if sys.platform == "darwin":
        try:
            result = subprocess.run(
                [
                    "security",
                    "find-generic-password",
                    "-s",
                    "com.meetingtranscriber.app",
                    "-a",
                    "HF_TOKEN",
                    "-w",
                ],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0 and result.stdout.strip():
                token = result.stdout.strip()
                os.environ["HF_TOKEN"] = token
                return token
        except (subprocess.TimeoutExpired, OSError) as e:
            log.debug("Keychain lookup failed: %s", e)

    raise RuntimeError(
        "HF_TOKEN not set. Diarization requires a HuggingFace token.\n"
        "Options:\n"
        "  - Set it in the MeetingTranscriber app settings\n"
        "  - Add HF_TOKEN=hf_... to .env file\n"
        "  - Export HF_TOKEN=hf_... in your shell"
    )


# ── Diarization ──────────────────────────────────────────────────────────────


def merge_similar_speakers(
    turns: list[tuple[float, float, str]],
    embeddings: dict[str, np.ndarray],
    threshold: float = MERGE_THRESHOLD,
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
            if score >= threshold:
                merge_map[label_b] = label_a
                console.print(
                    f"  [dim]Merged {label_b} into {label_a}"
                    f" (similarity: {score:.0%})[/dim]"
                )

    if not merge_map:
        return turns, embeddings

    # Apply merge to turns
    merged_turns = [(start, end, merge_map.get(s, s)) for start, end, s in turns]

    # Remove merged embeddings
    merged_embeddings = {k: v for k, v in embeddings.items() if k not in merge_map}

    return merged_turns, merged_embeddings


def diarize(
    audio_path: Path,
    num_speakers: int | None = None,
    interactive: bool = True,
    meeting_title: str = "Meeting",
    merge_threshold: float = MERGE_THRESHOLD,
    expected_names: list[str] | None = None,
) -> list[tuple[float, float, str]]:
    """Run pyannote speaker diarization with speaker recognition.

    Args:
        audio_path: Path to audio file.
        num_speakers: Expected number of speakers (helps accuracy).
        interactive: Whether to prompt for unknown speaker names.
        meeting_title: Title for speaker naming IPC request.
        merge_threshold: Cosine similarity threshold for merging duplicate speakers.
        expected_names: Participant names from meeting app (e.g. Teams AX).
            Used as num_speakers hint and pre-fill for speaker naming.

    Returns list of (start_sec, end_sec, speaker_name) tuples.
    """
    # Disable interactive prompts when no TTY (e.g. launched from menu bar app)
    if interactive and not sys.stdin.isatty():
        console.print(
            "[dim]Non-interactive mode (no TTY): skipping speaker prompts[/dim]"
        )
        interactive = False

    token = _resolve_hf_token()

    import torch
    from pyannote.audio import Pipeline

    # Use MPS (Apple Silicon GPU) if available, otherwise CPU
    if torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        device = torch.device("cpu")

    with Progress(
        SpinnerColumn(), TextColumn("{task.description}"), transient=True
    ) as progress:
        progress.add_task("Loading diarization model ...", total=None)
        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            token=token,
        )
        pipeline.to(device)

    console.print(
        f"[dim]Diarization model loaded ({device}). Analyzing speakers ...[/dim]"
    )

    # Use expected_names as num_speakers hint if not explicitly set
    if expected_names and not num_speakers:
        num_speakers = len(expected_names)
        console.print(
            f"[dim]Using participant count from meeting app: "
            f"{num_speakers} ({', '.join(expected_names)})[/dim]"
        )

    # Ask for speaker count before diarization (improves accuracy)
    if interactive and not num_speakers:
        answer = input("  Number of speakers? (Enter = auto-detect): ").strip()
        if answer.isdigit() and int(answer) > 0:
            num_speakers = int(answer)
    elif not interactive and _status_enabled() and not num_speakers:
        from meeting_transcriber.config import SPEAKER_COUNT_TIMEOUT

        write_speaker_count_request(meeting_title)
        _emit_status("waiting_for_speaker_count", detail="How many speakers?")
        console.print(
            f"[dim]Waiting for speaker count via app "
            f"(timeout {SPEAKER_COUNT_TIMEOUT}s)...[/dim]"
        )
        response = poll_speaker_count_response(SPEAKER_COUNT_TIMEOUT)
        if response and response > 0:
            num_speakers = response
        cleanup_speaker_count_ipc()

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
        turns, embeddings = merge_similar_speakers(turns, embeddings, merge_threshold)
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

    # Interactive: ask if speaker count is correct, re-run if needed
    if interactive and not num_speakers and len(speaker_labels) > 1:
        for label in speaker_labels:
            t = speaking_times.get(label, 0)
            m, s = int(t // 60), int(t % 60)
            time_str = f"{m}:{s:02d}" if m else f"{s}s"
            console.print(f"  {label} ({time_str})")

        answer = input(
            "\n  Correct number of speakers? (Enter=yes, or type number): "
        ).strip()
        if answer.isdigit() and int(answer) != len(speaker_labels):
            corrected = int(answer)
            console.print(
                f"[dim]Re-running diarization with {corrected} speakers ...[/dim]"
            )
            return diarize(
                audio_path,
                num_speakers=corrected,
                interactive=interactive,
                meeting_title=meeting_title,
                merge_threshold=merge_threshold,
                expected_names=expected_names,
            )

    # Match against saved speaker profiles
    db = load_speaker_db()
    if db:
        console.print(
            f"[dim]Matching against {len(db)} saved speaker profiles ...[/dim]"
        )
    mapping = match_speakers(embeddings, db)

    # Pre-fill unmatched speakers with expected_names (by speaking time order)
    if expected_names:
        unmatched_labels = [
            label
            for label in sorted(
                mapping.keys(),
                key=lambda lbl: speaking_times.get(lbl, 0),
                reverse=True,
            )
            if mapping[label] == label  # not yet matched by voice profile
        ]
        unused_names = [n for n in expected_names if n not in mapping.values()]
        for label, name in zip(unmatched_labels, unused_names):
            mapping[label] = name
            console.print(
                f"  [cyan]Suggested:[/cyan] {label} → {name} (from participant list)"
            )

    # Let user confirm/name all speakers
    if interactive and embeddings:
        console.print("\n[bold]Speaker identification:[/bold]")
        mapping = prompt_speaker_names(
            mapping, embeddings, speaking_times, turns, audio_path, db
        )
    elif not interactive and _status_enabled() and embeddings:
        # App-flow: file-based IPC for speaker naming via menu bar app
        from meeting_transcriber.config import SPEAKER_NAMING_TIMEOUT

        write_speaker_request(
            mapping,
            embeddings,
            speaking_times,
            audio_path,
            turns,
            meeting_title,
            expected_names=expected_names,
        )
        _emit_status(
            "waiting_for_speaker_names",
            detail=f"{len(speaker_labels)} speakers detected",
        )
        console.print(
            f"[dim]Waiting for speaker names via app "
            f"(timeout {SPEAKER_NAMING_TIMEOUT}s)...[/dim]"
        )
        response = poll_speaker_response(SPEAKER_NAMING_TIMEOUT)
        if response:
            for label, name in response.items():
                if name:
                    proper = " ".join(w.capitalize() for w in name.split())
                    mapping[label] = proper
                    if label in embeddings:
                        db[proper] = embeddings[label].tolist()
            save_speaker_db(db)
            console.print("[green]Speaker names received from app.[/green]")
        else:
            console.print(
                "[yellow]No speaker names received, using auto-detected.[/yellow]"
            )
        cleanup_speaker_ipc()

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


def _format_timestamp(seconds: float) -> str:
    """Format seconds as [MM:SS] or [H:MM:SS] for longer recordings."""
    total = int(seconds)
    h, remainder = divmod(total, 3600)
    m, s = divmod(remainder, 60)
    if h > 0:
        return f"[{h}:{m:02d}:{s:02d}]"
    return f"[{m:02d}:{s:02d}]"


def format_diarized_transcript(segments: list[TimestampedSegment]) -> str:
    """Format segments with timestamps and speaker labels."""
    if not segments:
        return ""

    lines = []

    for seg in segments:
        ts = _format_timestamp(seg.start)
        text = seg.text.strip()
        if not text:
            continue
        lines.append(f"{ts} [{seg.speaker}] {text}")

    return "\n".join(lines)
