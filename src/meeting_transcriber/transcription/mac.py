"""macOS transcription via pywhispercpp (whisper.cpp)."""

import os
import wave
from pathlib import Path

import numpy as np
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn

from meeting_transcriber.config import DEFAULT_WHISPER_MODEL_MAC, TARGET_RATE

console = Console()


def _ensure_16khz(audio_path: Path) -> Path:
    """Resample WAV to 16kHz if needed (pywhispercpp requires exactly 16kHz)."""
    with wave.open(str(audio_path), "rb") as wf:
        rate = wf.getframerate()
        if rate == TARGET_RATE:
            return audio_path
        channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        raw = wf.readframes(wf.getnframes())

    if sampwidth == 2:
        samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    else:
        samples = np.frombuffer(raw, dtype=np.float32)

    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)

    from math import gcd

    from scipy.signal import resample_poly

    g = gcd(rate, TARGET_RATE)
    up, down = TARGET_RATE // g, rate // g
    resampled = resample_poly(samples, up, down)

    out_path = audio_path.with_stem(audio_path.stem + "_16k")
    audio_int16 = (np.clip(resampled, -1.0, 1.0) * 32767).astype(np.int16)
    with wave.open(str(out_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(TARGET_RATE)
        wf.writeframes(audio_int16.tobytes())

    console.print(f"[dim]Resampled {rate}→{TARGET_RATE} Hz: {out_path}[/dim]")
    return out_path


def transcribe(
    audio_path: Path,
    model: str = DEFAULT_WHISPER_MODEL_MAC,
    language: str | None = None,
    diarize_enabled: bool = False,
    num_speakers: int | None = None,
) -> str:
    """Transcribe an audio file with pywhispercpp (whisper.cpp)."""
    from pywhispercpp.model import Model

    whisper_path = _ensure_16khz(audio_path)

    n_threads = min(os.cpu_count() or 4, 8)

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        transient=True,
    ) as progress:
        progress.add_task(f"Loading Whisper model [bold]{model}[/bold] ...", total=None)
        whisper = Model(
            model,
            n_threads=n_threads,
            print_realtime=False,
            print_progress=False,
        )

    console.print(f"[dim]Model loaded ({n_threads} threads). Transcribing ...[/dim]")

    with Progress(
        SpinnerColumn(), TextColumn("{task.description}"), transient=True
    ) as progress:
        progress.add_task("Transcribing audio ...", total=None)
        segments = whisper.transcribe(str(whisper_path), language=language)

    if not diarize_enabled:
        text = " ".join(seg.text for seg in segments).strip()
        console.print(f"[green]Transcription complete ({len(text)} characters)[/green]")
        return text

    from meeting_transcriber.diarize import (
        TimestampedSegment,
        assign_speakers,
        diarize,
        format_diarized_transcript,
    )

    ts_segments = [
        TimestampedSegment(start=seg.t0 * 0.01, end=seg.t1 * 0.01, text=seg.text)
        for seg in segments
    ]

    turns = diarize(audio_path, num_speakers=num_speakers)
    ts_segments = assign_speakers(ts_segments, turns)
    text = format_diarized_transcript(ts_segments)

    console.print(
        f"[green]Transcription + diarization complete ({len(text)} characters)[/green]"
    )
    return text
