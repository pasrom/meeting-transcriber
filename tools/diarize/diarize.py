#!/usr/bin/env python3
"""Standalone speaker diarization via pyannote-audio.

NO dependency on the meeting_transcriber package.

Usage:
    python diarize.py <wav_path> [options]

Options:
    --speakers N            Expected number of speakers (0 = auto)
    --speakers-db PATH      Path to speakers.json voice profiles
    --merge-threshold 0.92  Cosine threshold for merging duplicate speakers
    --expected-names "A,B"  Participant names from meeting app
    --ipc-dir PATH          IPC directory for speaker naming via menu bar app
    --hf-token TOKEN        HuggingFace token (or set HF_TOKEN env var)

Output (JSON to stdout):
    {
      "segments": [{"start": 0.0, "end": 5.2, "speaker": "SPEAKER_00"}, ...],
      "embeddings": {"SPEAKER_00": [0.1, ...], ...},
      "auto_names": {"SPEAKER_00": "John", ...},
      "speaking_times": {"SPEAKER_00": 125.3, ...}
    }
"""

import argparse
import fcntl
import json
import logging
import os
import shutil
import subprocess
import sys
import time
import wave
from pathlib import Path

import numpy as np

log = logging.getLogger(__name__)

SIMILARITY_THRESHOLD = 0.75
MERGE_THRESHOLD = 0.92
SPEAKER_NAMING_TIMEOUT = 300
SPEAKER_COUNT_TIMEOUT = 120


# ── Speaker Database ──────────────────────────────────────────────────────────


def load_speaker_db(db_path: Path) -> dict[str, list[float]]:
    """Load saved speaker embeddings from JSON."""
    if not db_path.exists():
        return {}
    with open(db_path, encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_SH)
        try:
            raw = json.load(f)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)

    # Merge entries differing only by case
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

    if len(db) < len(raw):
        save_speaker_db(db, db_path)

    return db


def save_speaker_db(db: dict[str, list[float]], db_path: Path) -> None:
    """Save speaker embeddings to JSON."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with open(db_path, "w", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            json.dump(db, f, indent=2, ensure_ascii=False)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


# ── Similarity ────────────────────────────────────────────────────────────────


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    norm_a = np.linalg.norm(a)
    norm_b = np.linalg.norm(b)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(np.dot(a, b) / (norm_a * norm_b))


def match_speakers(
    embeddings: dict[str, np.ndarray],
    db: dict[str, list[float]],
) -> dict[str, str]:
    """Match speaker embeddings against saved profiles."""
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
        else:
            mapping[label] = label

    return mapping


def merge_similar_speakers(
    turns: list[tuple[float, float, str]],
    embeddings: dict[str, np.ndarray],
    threshold: float = MERGE_THRESHOLD,
) -> tuple[list[tuple[float, float, str]], dict[str, np.ndarray]]:
    """Merge speakers with very similar embeddings."""
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

    if not merge_map:
        return turns, embeddings

    merged_turns = [(s, e, merge_map.get(spk, spk)) for s, e, spk in turns]
    merged_embeddings = {k: v for k, v in embeddings.items() if k not in merge_map}
    return merged_turns, merged_embeddings


# ── Speaker Samples ───────────────────────────────────────────────────────────


def extract_speaker_samples(
    audio_path: Path,
    turns: list[tuple[float, float, str]],
    output_dir: Path,
    max_duration: float = 10.0,
) -> dict[str, str]:
    """Extract a WAV clip per speaker. Returns {label: filename}."""
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


# ── Speaker Naming IPC ────────────────────────────────────────────────────────


def write_speaker_request(
    mapping: dict[str, str],
    embeddings: dict[str, np.ndarray],
    speaking_times: dict[str, float],
    audio_path: Path,
    turns: list[tuple[float, float, str]],
    meeting_title: str,
    ipc_dir: Path,
    speakers_db: dict[str, list[float]],
    expected_names: list[str] | None = None,
) -> None:
    """Write speaker_request.json for the menu bar app."""
    samples_dir = ipc_dir / "speaker_samples"
    samples = extract_speaker_samples(audio_path, turns, samples_dir)

    speakers = []
    for label in sorted(mapping.keys()):
        auto_name = mapping[label] if mapping[label] != label else None
        confidence = 0.0
        if auto_name and label in embeddings and auto_name in speakers_db:
            confidence = cosine_similarity(
                embeddings[label], np.array(speakers_db[auto_name])
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
        "audio_samples_dir": str(samples_dir),
        "speakers": speakers,
        "expected_names": expected_names or [],
    }

    request_file = ipc_dir / "speaker_request.json"
    tmp_path = request_file.with_suffix(".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, request_file)


def poll_speaker_response(ipc_dir: Path, timeout: int = SPEAKER_NAMING_TIMEOUT) -> dict[str, str] | None:
    """Poll for speaker_response.json. Returns {label: name} or None."""
    response_file = ipc_dir / "speaker_response.json"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if response_file.exists():
            try:
                with open(response_file, encoding="utf-8") as f:
                    data = json.load(f)
                return data.get("speakers", {})
            except (json.JSONDecodeError, OSError):
                return None
        time.sleep(2)
    return None


def write_speaker_count_request(meeting_title: str, ipc_dir: Path) -> None:
    """Write speaker_count_request.json."""
    data = {
        "version": 1,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "meeting_title": meeting_title,
    }
    request_file = ipc_dir / "speaker_count_request.json"
    tmp_path = request_file.with_suffix(".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, request_file)


def poll_speaker_count_response(ipc_dir: Path, timeout: int = SPEAKER_COUNT_TIMEOUT) -> int | None:
    """Poll for speaker_count_response.json. Returns count or None."""
    response_file = ipc_dir / "speaker_count_response.json"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if response_file.exists():
            try:
                with open(response_file, encoding="utf-8") as f:
                    data = json.load(f)
                return data.get("speaker_count", 0)
            except (json.JSONDecodeError, OSError):
                return None
        time.sleep(2)
    return None


def cleanup_ipc(ipc_dir: Path) -> None:
    """Remove IPC files and samples directory."""
    for name in ("speaker_request.json", "speaker_response.json",
                 "speaker_count_request.json", "speaker_count_response.json"):
        try:
            (ipc_dir / name).unlink(missing_ok=True)
        except OSError:
            pass
    samples_dir = ipc_dir / "speaker_samples"
    if samples_dir.exists():
        shutil.rmtree(samples_dir, ignore_errors=True)


# ── HF Token Resolution ──────────────────────────────────────────────────────


def resolve_hf_token(explicit_token: str | None = None) -> str:
    """Resolve HuggingFace token: explicit > env > .env > Keychain."""
    if explicit_token:
        return explicit_token

    token = os.environ.get("HF_TOKEN")
    if token:
        return token

    # Try .env file
    try:
        from dotenv import load_dotenv
        load_dotenv()
        token = os.environ.get("HF_TOKEN")
        if token:
            return token
    except ImportError:
        pass

    # macOS Keychain
    if sys.platform == "darwin":
        try:
            result = subprocess.run(
                ["security", "find-generic-password",
                 "-s", "com.meetingtranscriber.app",
                 "-a", "HF_TOKEN", "-w"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()
        except (subprocess.TimeoutExpired, OSError):
            pass

    raise RuntimeError(
        "HF_TOKEN not set. Diarization requires a HuggingFace token.\n"
        "Set HF_TOKEN environment variable or pass --hf-token."
    )


# ── Diarization ───────────────────────────────────────────────────────────────


def diarize(
    audio_path: Path,
    num_speakers: int | None = None,
    merge_threshold: float = MERGE_THRESHOLD,
    hf_token: str | None = None,
) -> dict:
    """Run pyannote speaker diarization.

    Returns dict with segments, embeddings, speaking_times.
    """
    token = resolve_hf_token(hf_token)

    import torch
    from pyannote.audio import Pipeline

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        token=token,
    )
    pipeline.to(device)

    pipeline_params: dict = {}
    if num_speakers and num_speakers > 0:
        pipeline_params["num_speakers"] = num_speakers

    result = pipeline(str(audio_path), **pipeline_params)

    annotation = getattr(result, "speaker_diarization", result)
    raw_embeddings = getattr(result, "speaker_embeddings", None)

    turns = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        turns.append((turn.start, turn.end, speaker))

    speaker_labels = sorted(set(t[2] for t in turns))
    embeddings: dict[str, np.ndarray] = {}
    if raw_embeddings is not None:
        for i, label in enumerate(speaker_labels):
            if i < len(raw_embeddings):
                embeddings[label] = np.array(raw_embeddings[i])

    # Merge similar speakers
    if not num_speakers and len(speaker_labels) > 1:
        turns, embeddings = merge_similar_speakers(turns, embeddings, merge_threshold)
        speaker_labels = sorted(set(t[2] for t in turns))

    speaking_times = {}
    for label in speaker_labels:
        speaking_times[label] = sum(e - s for s, e, spk in turns if spk == label)

    return {
        "segments": [{"start": s, "end": e, "speaker": spk} for s, e, spk in turns],
        "embeddings": {k: v.tolist() for k, v in embeddings.items()},
        "speaking_times": speaking_times,
        "turns": turns,  # internal use, not serialized
    }


def run_full_pipeline(
    audio_path: Path,
    num_speakers: int | None = None,
    speakers_db_path: Path | None = None,
    merge_threshold: float = MERGE_THRESHOLD,
    expected_names: list[str] | None = None,
    ipc_dir: Path | None = None,
    meeting_title: str = "Meeting",
    hf_token: str | None = None,
) -> dict:
    """Full diarization pipeline with speaker matching and optional IPC naming."""
    result = diarize(audio_path, num_speakers, merge_threshold, hf_token)
    turns = result["turns"]
    embeddings = {k: np.array(v) for k, v in result["embeddings"].items()}
    speaking_times = result["speaking_times"]

    # Load speaker DB and match
    db: dict[str, list[float]] = {}
    if speakers_db_path:
        db = load_speaker_db(speakers_db_path)

    mapping = match_speakers(embeddings, db)

    # Pre-fill from expected names
    if expected_names:
        unmatched = [
            label for label in sorted(
                mapping.keys(),
                key=lambda lbl: speaking_times.get(lbl, 0),
                reverse=True,
            )
            if mapping[label] == label
        ]
        unused = [n for n in expected_names if n not in mapping.values()]
        for label, name in zip(unmatched, unused):
            mapping[label] = name

    # IPC-based speaker naming
    if ipc_dir:
        write_speaker_request(
            mapping, embeddings, speaking_times,
            audio_path, turns, meeting_title, ipc_dir, db, expected_names,
        )
        response = poll_speaker_response(ipc_dir)
        if response:
            for label, name in response.items():
                if name:
                    proper = " ".join(w.capitalize() for w in name.split())
                    mapping[label] = proper
                    if label in embeddings:
                        db[proper] = embeddings[label].tolist()
            if speakers_db_path:
                save_speaker_db(db, speakers_db_path)
        cleanup_ipc(ipc_dir)

    result["auto_names"] = {k: v for k, v in mapping.items() if v != k}

    # Apply names to segments
    named_segments = [
        {"start": seg["start"], "end": seg["end"], "speaker": mapping.get(seg["speaker"], seg["speaker"])}
        for seg in result["segments"]
    ]
    result["segments"] = named_segments

    # Remove internal turns field before output
    del result["turns"]

    return result


# ── CLI ───────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="Speaker diarization via pyannote-audio")
    parser.add_argument("audio", type=Path, help="Path to WAV file")
    parser.add_argument("--speakers", type=int, default=None, help="Expected number of speakers (0=auto)")
    parser.add_argument("--speakers-db", type=Path, default=None, help="Path to speakers.json")
    parser.add_argument("--merge-threshold", type=float, default=MERGE_THRESHOLD)
    parser.add_argument("--expected-names", type=str, default=None, help="Comma-separated participant names")
    parser.add_argument("--ipc-dir", type=Path, default=None, help="IPC directory for menu bar app")
    parser.add_argument("--meeting-title", type=str, default="Meeting")
    parser.add_argument("--hf-token", type=str, default=None, help="HuggingFace token")
    args = parser.parse_args()

    expected_names = args.expected_names.split(",") if args.expected_names else None
    num_speakers = args.speakers if args.speakers and args.speakers > 0 else None

    result = run_full_pipeline(
        audio_path=args.audio,
        num_speakers=num_speakers,
        speakers_db_path=args.speakers_db,
        merge_threshold=args.merge_threshold,
        expected_names=expected_names,
        ipc_dir=args.ipc_dir,
        meeting_title=args.meeting_title,
        hf_token=args.hf_token,
    )

    # Output JSON to stdout
    json.dump(result, sys.stdout, indent=2, ensure_ascii=False)
    print()


if __name__ == "__main__":
    main()
