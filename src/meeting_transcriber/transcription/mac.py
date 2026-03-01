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


def _load_whisper_model(model: str):
    """Load the Whisper model once (shared between single/dual-source)."""
    from pywhispercpp.model import Model

    n_threads = min(os.cpu_count() or 4, 8)

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        transient=True,
    ) as progress:
        progress.add_task(f"Loading Whisper model [bold]{model}[/bold] ...", total=None)
        try:
            whisper = Model(
                model,
                n_threads=n_threads,
                print_realtime=False,
                print_progress=False,
            )
        except Exception as exc:
            raise RuntimeError(
                f"Failed to load Whisper model '{model}': {exc}. "
                "Check that the model name is valid and you have internet "
                "access for the initial download."
            ) from exc

    console.print(f"[dim]Model loaded ({n_threads} threads).[/dim]")
    return whisper


def _transcribe_segments(whisper_model, audio_path: Path, language: str | None = None):
    """Transcribe audio into TimestampedSegments using a preloaded model."""
    from meeting_transcriber.diarize import TimestampedSegment

    whisper_path = _ensure_16khz(audio_path)

    with Progress(
        SpinnerColumn(), TextColumn("{task.description}"), transient=True
    ) as progress:
        progress.add_task(f"Transcribing {audio_path.name} ...", total=None)
        segments = whisper_model.transcribe(str(whisper_path), language=language)

    return [
        TimestampedSegment(start=seg.t0 * 0.01, end=seg.t1 * 0.01, text=seg.text)
        for seg in segments
    ]


def _merge_segments(app_segments: list, mic_segments: list) -> list:
    """Merge app and mic segments by start timestamp."""
    merged = list(app_segments) + list(mic_segments)
    merged.sort(key=lambda seg: seg.start)
    return merged


def _transcribe_dual_source(
    whisper_model,
    app_audio: Path,
    mic_audio: Path,
    language: str | None = None,
    diarize_enabled: bool = False,
    num_speakers: int | None = None,
    meeting_title: str = "Meeting",
    mic_label: str = "Me",
    mic_delay: float = 0.0,
) -> str:
    """Transcribe app and mic tracks separately, merge by timestamp."""
    from meeting_transcriber.diarize import (
        assign_speakers,
        diarize,
        format_diarized_transcript,
    )

    # 1. Transcribe both tracks
    console.print("[dim]Transcribing app audio ...[/dim]")
    app_segments = _transcribe_segments(whisper_model, app_audio, language)
    console.print(f"[dim]App: {len(app_segments)} segments[/dim]")

    console.print("[dim]Transcribing mic audio ...[/dim]")
    mic_segments = _transcribe_segments(whisper_model, mic_audio, language)
    console.print(f"[dim]Mic: {len(mic_segments)} segments[/dim]")

    # 2. Align tracks using stream start-time delta
    #    mic_delay > 0: mic started later → shift mic timestamps forward
    #    mic_delay < 0: app started later → shift app timestamps forward
    if mic_delay >= 0:
        for seg in mic_segments:
            seg.start += mic_delay
            seg.end += mic_delay
    else:
        for seg in app_segments:
            seg.start += abs(mic_delay)
            seg.end += abs(mic_delay)
    console.print(f"[dim]Track alignment: mic_delay={mic_delay:+.3f}s[/dim]")

    # 3. Label app segments
    if diarize_enabled:
        try:
            turns = diarize(
                app_audio, num_speakers=num_speakers, meeting_title=meeting_title
            )
            app_segments = assign_speakers(app_segments, turns)
        except Exception as exc:
            console.print(
                f"[red]App diarization failed: {exc}[/red]\n"
                "[yellow]Labelling app segments as 'Remote'.[/yellow]"
            )
            for seg in app_segments:
                seg.speaker = "Remote"
    else:
        for seg in app_segments:
            seg.speaker = "Remote"

    # 4. Label mic segments
    if mic_label:
        # Solo mode: single person at the mic
        for seg in mic_segments:
            seg.speaker = mic_label
    else:
        # Multi mode: diarize the mic track too
        if diarize_enabled:
            try:
                mic_turns = diarize(
                    mic_audio, num_speakers=None, meeting_title=meeting_title
                )
                mic_segments = assign_speakers(mic_segments, mic_turns)
            except Exception as exc:
                console.print(
                    f"[red]Mic diarization failed: {exc}[/red]\n"
                    "[yellow]Labelling mic segments as 'Local'.[/yellow]"
                )
                for seg in mic_segments:
                    seg.speaker = "Local"
        else:
            for seg in mic_segments:
                seg.speaker = "Local"

    # 5. Merge and format
    merged = _merge_segments(app_segments, mic_segments)
    text = format_diarized_transcript(merged)

    console.print(
        f"[green]Dual-source transcription complete ({len(text)} characters)[/green]"
    )
    return text


def transcribe(
    audio_path: Path,
    model: str = DEFAULT_WHISPER_MODEL_MAC,
    language: str | None = None,
    diarize_enabled: bool = False,
    num_speakers: int | None = None,
    meeting_title: str = "Meeting",
    *,
    app_audio: Path | None = None,
    mic_audio: Path | None = None,
    mic_label: str = "Me",
    mic_delay: float = 0.0,
) -> str:
    """Transcribe an audio file with pywhispercpp (whisper.cpp).

    If both app_audio and mic_audio are provided, uses dual-source mode:
    transcribes each track separately and merges by timestamp.
    Otherwise, falls back to single-source mode using audio_path (the mix).
    """
    whisper_model = _load_whisper_model(model)

    # Dual-source mode: separate app + mic tracks
    if app_audio and mic_audio:
        console.print("[dim]Dual-source mode: transcribing app + mic separately[/dim]")
        return _transcribe_dual_source(
            whisper_model,
            app_audio,
            mic_audio,
            language=language,
            diarize_enabled=diarize_enabled,
            num_speakers=num_speakers,
            meeting_title=meeting_title,
            mic_label=mic_label,
            mic_delay=mic_delay,
        )

    # Single-source mode (original behavior)
    whisper_path = _ensure_16khz(audio_path)

    console.print("[dim]Transcribing ...[/dim]")

    with Progress(
        SpinnerColumn(), TextColumn("{task.description}"), transient=True
    ) as progress:
        progress.add_task("Transcribing audio ...", total=None)
        segments = whisper_model.transcribe(str(whisper_path), language=language)

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

    try:
        turns = diarize(
            audio_path, num_speakers=num_speakers, meeting_title=meeting_title
        )
    except Exception as exc:
        console.print(
            f"[red]Diarization failed: {exc}[/red]\n"
            "[yellow]Falling back to transcript without speaker labels.[/yellow]"
        )
        text = " ".join(seg.text for seg in segments).strip()
        return text

    ts_segments = assign_speakers(ts_segments, turns)
    text = format_diarized_transcript(ts_segments)

    console.print(
        f"[green]Transcription + diarization complete ({len(text)} characters)[/green]"
    )
    return text
