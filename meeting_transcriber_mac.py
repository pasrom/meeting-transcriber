#!/usr/bin/env python3
"""
Meeting Transcriber – macOS Edition
App audio (ScreenCaptureKit via ProcTap) + microphone → Whisper → Claude → protocol

Setup:
    pip install proc-tap pywhispercpp sounddevice numpy rich

Requires macOS 13+ (Ventura) for ScreenCaptureKit.
On first launch, the "Screen Recording" permission will be requested.
"""

import os
import subprocess
import sys
import tempfile
import threading
import wave
import argparse
import datetime
from pathlib import Path

import numpy as np
import sounddevice as sd
from rich.console import Console
from rich.markdown import Markdown
from rich.progress import Progress, SpinnerColumn, TextColumn

console = Console()

# ── Configuration ────────────────────────────────────────────────────────────

WHISPER_MODEL = (
    "large-v3-turbo-q5_0"  # tiny | base | small | medium | large-v3-turbo-q5_0
)
WHISPER_LANG = None  # None = auto-detect
OUTPUT_DIR = Path("./protocols")

PROTOCOL_PROMPT = """You are a professional meeting minute taker.
Create a structured meeting protocol in German from the following transcript.

Return ONLY the finished Markdown document - no explanations, no introduction, no comments before or after.

Use exactly this structure:

# Meeting Protocol - [Meeting Title]
**Date:** [Date from context or today]

---

## Summary
[3-5 sentence summary of the meeting]

## Participants
- [Name 1]
- [Name 2]

## Topics Discussed

### [Topic 1]
[What was discussed]

### [Topic 2]
[What was discussed]

## Decisions
- [Decision 1]
- [Decision 2]

## Tasks
| Task | Responsible | Deadline | Priority |
|------|-------------|----------|----------|
| [Description] | [Name] | [Date or open] | 🔴 high / 🟡 medium / 🟢 low |

## Open Questions
- [Question 1]
- [Question 2]

---

## Full Transcript
[Insert the full transcript here]

---
Transcript:
"""

# ── App Selection ────────────────────────────────────────────────────────────


def list_audio_apps() -> list[dict]:
    """List running GUI apps (macOS) via NSWorkspace."""
    try:
        from AppKit import NSWorkspace, NSApplicationActivationPolicyRegular
    except ImportError:
        console.print(
            "[red]pyobjc not installed: pip install pyobjc-framework-Cocoa[/red]"
        )
        return []

    apps = []
    for app in NSWorkspace.sharedWorkspace().runningApplications():
        if app.activationPolicy() == NSApplicationActivationPolicyRegular:
            name = app.localizedName()
            pid = app.processIdentifier()
            if name and pid > 0:
                apps.append({"name": name, "pid": pid})
    return sorted(apps, key=lambda a: a["name"].lower())


def choose_app(app_name: str | None) -> dict | None:
    """Select an app by name or show interactive selection."""
    apps = list_audio_apps()
    if not apps:
        console.print("[yellow]No running apps found.[/yellow]")
        return None

    if app_name:
        matches = [a for a in apps if app_name.lower() in a["name"].lower()]
        if len(matches) == 1:
            console.print(
                f"[green]App found:[/green] {matches[0]['name']}"
                f" (PID {matches[0]['pid']})"
            )
            return matches[0]
        if len(matches) > 1:
            console.print(f"[yellow]Multiple matches for '{app_name}':[/yellow]")
            for i, a in enumerate(matches, 1):
                console.print(f"  {i}. {a['name']} (PID {a['pid']})")
            choice = input("Choose number: ").strip()
            try:
                return matches[int(choice) - 1]
            except (ValueError, IndexError):
                console.print("[red]Invalid selection.[/red]")
                sys.exit(1)
        console.print(f"[red]No app with name '{app_name}' found.[/red]")
        sys.exit(1)

    # Interactive selection
    console.print("\n[bold]Running apps:[/bold]")
    for i, a in enumerate(apps, 1):
        console.print(f"  {i}. {a['name']} (PID {a['pid']})")
    choice = input("\nChoose number (or Enter for microphone only): ").strip()
    if not choice:
        return None
    try:
        return apps[int(choice) - 1]
    except (ValueError, IndexError):
        console.print("[red]Invalid selection.[/red]")
        sys.exit(1)


# ── Audio Recording ──────────────────────────────────────────────────────────

TARGET_RATE = 16000  # Whisper expects 16 kHz


def record_audio(
    output_path: Path, app_pid: int | None = None, mic_only: bool = False
) -> Path:
    """Record app audio (ProcTap) and/or microphone (sounddevice)."""
    frames_app: list[bytes] = []
    frames_mic: list[np.ndarray] = []
    stop_event = threading.Event()
    app_rate = 48000
    app_channels = 2

    # ── App audio via ProcTap ────────────────────────────────────────────
    tap = None
    if app_pid and not mic_only:
        try:
            from proctap import ProcessAudioCapture
        except ImportError:
            console.print("[red]proc-tap not installed: pip install proc-tap[/red]")
            sys.exit(1)

        def on_app_audio(pcm: bytes, frames: int) -> None:
            if not stop_event.is_set():
                frames_app.append(pcm)

        try:
            tap = ProcessAudioCapture(pid=app_pid, on_data=on_app_audio)
            tap.start()
            fmt = tap.get_format()
            app_rate = fmt.get("sample_rate", 48000)
            app_channels = fmt.get("channels", 2)
            console.print(
                f"[dim]App audio active: PID {app_pid}"
                f" ({app_rate} Hz, {app_channels}ch)[/dim]"
            )
        except Exception as e:
            console.print(
                f"[yellow]App audio failed ({type(e).__name__}: {e}),"
                " microphone only.[/yellow]"
            )
            tap = None

    # ── Microphone via sounddevice ───────────────────────────────────────
    mic_rate = TARGET_RATE

    def mic_callback(indata, frame_count, time_info, status):
        if not stop_event.is_set():
            frames_mic.append(indata[:, 0].copy())

    mic_stream = sd.InputStream(
        samplerate=mic_rate,
        channels=1,
        dtype="float32",
        callback=mic_callback,
        blocksize=1024,
    )
    mic_stream.start()
    console.print(f"[dim]Microphone active ({mic_rate} Hz, mono)[/dim]")

    # ── Recording loop ───────────────────────────────────────────────────
    console.print(
        "\n[bold green]Recording ...[/bold green]  [dim]Press Enter to stop[/dim]\n"
    )
    input()
    stop_event.set()

    mic_stream.stop()
    mic_stream.close()
    if tap:
        tap.close()

    # ── Mix → WAV ────────────────────────────────────────────────────────
    audio_mic = np.concatenate(frames_mic) if frames_mic else np.zeros(0)

    audio_app = np.zeros(0)
    if frames_app:
        raw = np.frombuffer(b"".join(frames_app), dtype=np.float32)
        # Stereo → Mono
        if app_channels == 2 and len(raw) >= 2:
            raw = raw.reshape(-1, 2).mean(axis=1)
        # Resample to 16 kHz
        if app_rate != TARGET_RATE and len(raw) > 1:
            ratio = TARGET_RATE / app_rate
            new_len = int(len(raw) * ratio)
            audio_app = np.interp(
                np.linspace(0, len(raw) - 1, new_len),
                np.arange(len(raw)),
                raw,
            )
        else:
            audio_app = raw

    # Mix
    min_len = min(len(audio_mic), len(audio_app))
    if min_len > 0:
        mixed = (audio_mic[:min_len] + audio_app[:min_len]) / 2
        # Append remainder
        if len(audio_mic) > min_len:
            mixed = np.concatenate([mixed, audio_mic[min_len:] / 2])
        elif len(audio_app) > min_len:
            mixed = np.concatenate([mixed, audio_app[min_len:] / 2])
    else:
        mixed = audio_mic if len(audio_mic) > 0 else audio_app

    if len(mixed) == 0:
        console.print("[red]No audio data recorded.[/red]")
        sys.exit(1)

    audio_int16 = (np.clip(mixed, -1.0, 1.0) * 32767).astype(np.int16)

    with wave.open(str(output_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(TARGET_RATE)
        wf.writeframes(audio_int16.tobytes())

    duration = len(mixed) / TARGET_RATE
    console.print(f"[green]Recording saved ({duration:.1f}s): {output_path}[/green]")
    return output_path


# ── Transcription ────────────────────────────────────────────────────────────


def transcribe(
    audio_path: Path, diarize_enabled: bool = False, num_speakers: int | None = None
) -> str:
    """Transcribe an audio file with pywhispercpp (whisper.cpp)."""
    from pywhispercpp.model import Model

    n_threads = min(os.cpu_count() or 4, 8)

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        transient=True,
    ) as progress:
        progress.add_task(
            f"Loading Whisper model [bold]{WHISPER_MODEL}[/bold] ...", total=None
        )
        model = Model(
            WHISPER_MODEL,
            n_threads=n_threads,
            print_realtime=False,
            print_progress=False,
        )

    console.print(f"[dim]Model loaded ({n_threads} threads). Transcribing ...[/dim]")

    with Progress(
        SpinnerColumn(), TextColumn("{task.description}"), transient=True
    ) as progress:
        progress.add_task("Transcribing audio ...", total=None)
        segments = model.transcribe(str(audio_path), language=WHISPER_LANG)

    if not diarize_enabled:
        text = " ".join(seg.text for seg in segments).strip()
        console.print(f"[green]Transcription complete ({len(text)} characters)[/green]")
        return text

    from diarize import (
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


# ── Protocol via Claude CLI ──────────────────────────────────────────────────


def generate_protocol_cli(transcript: str, diarized: bool = False) -> str:
    """Call claude --print and pass the transcript via stdin."""
    prompt = PROTOCOL_PROMPT
    if diarized:
        prompt += (
            "\nNote: The transcript contains speaker labels like [SPEAKER_00], "
            "[SPEAKER_01] etc. Use these to identify different participants. "
            "In the Participants section, list them as Speaker 1, Speaker 2 etc. "
            "(or by name if mentioned in the conversation). "
            "In the Topics Discussed section, attribute key statements to speakers.\n\n"
        )
    prompt += transcript

    tmp_in = tempfile.NamedTemporaryFile(
        suffix=".txt", delete=False, mode="w", encoding="utf-8"
    )
    tmp_in.write(prompt)
    tmp_in.close()
    in_file = Path(tmp_in.name)

    tmp_out = tempfile.NamedTemporaryFile(suffix=".txt", delete=False)
    tmp_out.close()
    out_file = Path(tmp_out.name)

    console.print("[dim]Generating protocol with Claude CLI ...[/dim]")

    try:
        with (
            open(in_file, encoding="utf-8") as fin,
            open(out_file, "w", encoding="utf-8") as fout,
        ):
            subprocess.run(
                ["claude", "--print"],
                stdin=fin,
                stdout=fout,
                timeout=300,
            )
    except FileNotFoundError:
        console.print(
            "[red]'claude' CLI not found. Please install:"
            " npm install -g @anthropic-ai/claude-code[/red]"
        )
        sys.exit(1)
    except subprocess.TimeoutExpired:
        console.print("[red]Timeout – Claude took too long (>5 min).[/red]")
        sys.exit(1)
    finally:
        in_file.unlink(missing_ok=True)

    text = ""
    if out_file.exists():
        text = out_file.read_text(encoding="utf-8").strip()
        out_file.unlink(missing_ok=True)

    if not text:
        console.print("[red]Protocol is empty.[/red]")
        console.print("[dim]Tip: Test manually: echo Hello | claude --print[/dim]")
        sys.exit(1)

    return text


# ── Output ───────────────────────────────────────────────────────────────────


def save_transcript(transcript: str, title: str) -> Path:
    OUTPUT_DIR.mkdir(exist_ok=True)
    slug = title.lower().replace(" ", "_")
    date = datetime.datetime.now().strftime("%Y%m%d_%H%M")
    path = OUTPUT_DIR / f"{date}_{slug}.txt"
    path.write_text(transcript, encoding="utf-8")
    return path


# ── CLI ──────────────────────────────────────────────────────────────────────


def main():
    global WHISPER_MODEL

    parser = argparse.ArgumentParser(
        description="macOS Meeting Transcriber – app audio + microphone → Whisper → Claude → protocol"
    )
    parser.add_argument(
        "--app",
        "-a",
        type=str,
        default=None,
        help="App name for audio capture (e.g. 'Microsoft Teams')",
    )
    parser.add_argument(
        "--pid",
        type=int,
        default=None,
        help="PID of the app for audio capture (alternative to --app)",
    )
    parser.add_argument(
        "--list-apps",
        action="store_true",
        help="List running apps and exit",
    )
    parser.add_argument(
        "--mic-only",
        action="store_true",
        help="Record microphone only, no app audio",
    )
    parser.add_argument(
        "--file",
        "-f",
        type=Path,
        help="Audio file (mp3, wav, m4a, ...) OR transcript (.txt)",
    )
    parser.add_argument(
        "--title",
        "-t",
        default="Meeting",
        help="Meeting title for the output file",
    )
    parser.add_argument(
        "--model",
        "-m",
        default=WHISPER_MODEL,
        help=f"Whisper model (default: {WHISPER_MODEL})",
    )
    parser.add_argument(
        "--diarize",
        action="store_true",
        help="Enable speaker diarization (requires pyannote.audio + HuggingFace token)",
    )
    parser.add_argument(
        "--speakers",
        type=int,
        default=None,
        help="Expected number of speakers (improves diarization accuracy)",
    )
    args = parser.parse_args()
    WHISPER_MODEL = args.model

    console.rule("[bold]Meeting Transcriber – macOS[/bold]")

    # --list-apps: list apps and exit
    if args.list_apps:
        apps = list_audio_apps()
        if not apps:
            console.print("[yellow]No running apps found.[/yellow]")
            sys.exit(0)
        console.print(f"\n[bold]Running apps ({len(apps)}):[/bold]\n")
        for i, a in enumerate(apps, 1):
            console.print(f"  {i:>3}. {a['name']}  [dim](PID {a['pid']})[/dim]")
        console.print()
        sys.exit(0)

    # 1. Determine audio source
    if args.file and args.file.suffix.lower() == ".txt":
        console.print(f"[blue]Transcript file detected:[/blue] {args.file}")
        transcript = args.file.read_text(encoding="utf-8").strip()
        console.print(
            f"[green]Transcript loaded ({len(transcript)} characters)[/green]"
        )
    else:
        if args.file:
            audio_path = args.file
            console.print(f"[blue]Using audio file:[/blue] {audio_path}")
        else:
            # Live recording
            app_pid = None
            if args.pid:
                app_pid = args.pid
                console.print(f"[green]Using PID:[/green] {app_pid}")
            elif not args.mic_only:
                app = choose_app(args.app)
                app_pid = app["pid"] if app else None

            tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
            audio_path = Path(tmp.name)
            tmp.close()
            record_audio(audio_path, app_pid=app_pid, mic_only=args.mic_only)

        # 2. Transcription
        transcript = transcribe(
            audio_path,
            diarize_enabled=args.diarize,
            num_speakers=args.speakers,
        )

        # 3. Save transcript
        txt_path = save_transcript(transcript, args.title)
        console.print(f"[dim]Transcript saved: {txt_path}[/dim]")

    # 4. Protocol via Claude CLI
    diarized = "[SPEAKER_" in transcript
    protocol_md = generate_protocol_cli(transcript, diarized=diarized)

    # 5. Save protocol
    OUTPUT_DIR.mkdir(exist_ok=True)
    slug = args.title.lower().replace(" ", "_")
    date = datetime.datetime.now().strftime("%Y%m%d_%H%M")
    out_path = OUTPUT_DIR / f"{date}_{slug}.md"
    out_path.write_text(protocol_md, encoding="utf-8")

    console.print(f"\n[bold green]Protocol saved:[/bold green] {out_path}")
    console.print(Markdown(protocol_md))


if __name__ == "__main__":
    main()
