#!/usr/bin/env python3
"""
Meeting Transcriber
Aufnahme → Whisper (Transkription) → Claude (Protokoll + Tasks)

Setup:
    pip install openai-whisper anthropic pyaudio wave rich

Für GPU-Beschleunigung (optional):
    pip install torch torchvision torchaudio

Umgebungsvariable setzen:
    export ANTHROPIC_API_KEY="sk-ant-..."
"""

import sys
import wave
import argparse
import datetime
import tempfile
import threading
from pathlib import Path

import numpy as np

from faster_whisper import WhisperModel
from rich.console import Console
from rich.markdown import Markdown
from rich.progress import Progress, SpinnerColumn, TextColumn

console = Console()

# ── Konfiguration ────────────────────────────────────────────────────────────

WHISPER_MODEL   = "large"          # tiny | base | small | medium | large
WHISPER_LANG    = None                # None = auto-detect
CLAUDE_MODEL    = "claude-opus-4-6"
OUTPUT_DIR      = Path("./protokolle")

PROTOCOL_PROMPT = """Du bist ein professioneller Meeting-Protokollant.
Erstelle aus dem folgenden Transkript ein strukturiertes Meetingprotokoll auf Deutsch.

Gib NUR das fertige Markdown-Dokument zurück – keine Erklärungen, keine Einleitung, kein Kommentar davor oder danach.

Verwende exakt diese Struktur:

# Meetingprotokoll – [Titel des Meetings]
**Datum:** [Datum aus dem Kontext oder heute]

---

## Zusammenfassung
[3-5 Sätze Zusammenfassung des Meetings]

## Teilnehmer
- [Name 1]
- [Name 2]

## Besprochene Themen

### [Thema 1]
[Was wurde dazu besprochen]

### [Thema 2]
[Was wurde dazu besprochen]

## Entscheidungen
- [Entscheidung 1]
- [Entscheidung 2]

## Tasks
| Task | Verantwortlich | Deadline | Priorität |
|------|----------------|----------|-----------|
| [Beschreibung] | [Name] | [Datum oder offen] | 🔴 hoch / 🟡 mittel / 🟢 niedrig |

## Offene Fragen
- [Frage 1]
- [Frage 2]

---

## Vollständiges Transkript
[Das vollständige Transkript hier einfügen]

---
Transkript:
"""

# ── Audio-Aufnahme ───────────────────────────────────────────────────────────

def record_audio(output_path: Path, sample_rate: int = 16000) -> Path:
    """Nimmt Mikrofon + Systemton (WASAPI Loopback) gleichzeitig auf und mischt sie."""
    try:
        import pyaudiowpatch as pyaudio
    except ImportError:
        console.print("[red]pyaudiowpatch nicht installiert: pip install pyaudiowpatch[/red]")
        sys.exit(1)

    CHUNK = 1024
    frames_mic = []
    frames_loop = []
    stop_event = threading.Event()

    pa = pyaudio.PyAudio()

    # Standard-Mikrofon
    mic_stream = pa.open(
        format=pyaudio.paInt16, channels=1,
        rate=sample_rate, input=True,
        frames_per_buffer=CHUNK
    )

    # WASAPI Loopback (Systemton)
    loopback_stream = None
    loopback_rate = sample_rate
    try:
        wasapi_info = pa.get_host_api_info_by_type(pyaudio.paWASAPI)
        default_speaker = pa.get_device_info_by_index(wasapi_info["defaultOutputDevice"])
        for loopback_dev in pa.get_loopback_device_info_generator():
            if default_speaker["name"] in loopback_dev["name"]:
                loopback_rate = int(loopback_dev["defaultSampleRate"])
                loopback_stream = pa.open(
                    format=pyaudio.paInt16,
                    channels=loopback_dev["maxInputChannels"],
                    rate=loopback_rate, input=True,
                    input_device_index=loopback_dev["index"],
                    frames_per_buffer=CHUNK
                )
                console.print(f"[dim]Systemton-Loopback aktiv: {loopback_dev['name']} ({loopback_rate} Hz)[/dim]")
                break
    except Exception as e:
        console.print(f"[yellow]⚠ Kein Loopback verfügbar ({type(e).__name__}), nur Mikrofon.[/yellow]")

    def record_mic():
        while not stop_event.is_set():
            frames_mic.append(mic_stream.read(CHUNK, exception_on_overflow=False))

    def record_loopback():
        if loopback_stream is None:
            return
        while not stop_event.is_set():
            frames_loop.append(loopback_stream.read(CHUNK, exception_on_overflow=False))

    console.print("\n[bold green]🎙  Aufnahme läuft ...[/bold green]  [dim]Drücke Enter zum Stoppen[/dim]\n")
    t_mic  = threading.Thread(target=record_mic,      daemon=True)
    t_loop = threading.Thread(target=record_loopback, daemon=True)
    t_mic.start()
    t_loop.start()

    input()
    stop_event.set()
    t_mic.join()
    t_loop.join()

    mic_stream.stop_stream(); mic_stream.close()
    if loopback_stream:
        loopback_stream.stop_stream(); loopback_stream.close()
    pa.terminate()

    # Bytes → numpy, mischen
    to_np = lambda frames: np.frombuffer(b"".join(frames), dtype=np.int16).astype(np.float32) / 32768.0
    audio_mic  = to_np(frames_mic)  if frames_mic  else np.zeros(0)
    audio_loop = to_np(frames_loop) if frames_loop else np.zeros(0)

    # Loopback resampeln falls nötig
    if len(audio_loop) > 0 and loopback_rate != sample_rate:
        ratio = sample_rate / loopback_rate
        new_len = int(len(audio_loop) * ratio)
        audio_loop = np.interp(
            np.linspace(0, len(audio_loop) - 1, new_len),
            np.arange(len(audio_loop)),
            audio_loop
        )

    min_len = min(len(audio_mic), len(audio_loop))
    if min_len > 0:
        mixed = (audio_mic[:min_len] + audio_loop[:min_len]) / 2
    else:
        mixed = audio_mic if len(audio_mic) > 0 else audio_loop

    audio_int16 = (np.clip(mixed, -1.0, 1.0) * 32767).astype(np.int16)

    with wave.open(str(output_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(audio_int16.tobytes())

    duration = len(mixed) / sample_rate
    console.print(f"[green]✓ Aufnahme gespeichert ({duration:.1f}s): {output_path}[/green]")
    return output_path

# ── Transkription ────────────────────────────────────────────────────────────

def get_device() -> tuple[str, str]:
    """Erkennt automatisch die schnellste verfügbare Hardware."""
    try:
        import torch
        if torch.cuda.is_available():
            gpu = torch.cuda.get_device_name(0)
            console.print(f"[green]GPU erkannt:[/green] {gpu} → CUDA (float16)")
            return "cuda", "float16"
    except ImportError:
        pass
    console.print("[dim]Kein GPU gefunden → CPU (int8)[/dim]")
    return "cpu", "int8"


def transcribe(audio_path: Path) -> str:
    """Transkribiert eine Audiodatei mit Whisper."""
    device, compute_type = get_device()
    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        transient=True,
    ) as progress:
        progress.add_task(f"Lade Whisper-Modell [bold]{WHISPER_MODEL}[/bold] ...", total=None)
        model = WhisperModel(WHISPER_MODEL, device=device, compute_type=compute_type)

    console.print(f"[dim]Modell geladen. Starte Transkription ...[/dim]")

    with Progress(SpinnerColumn(), TextColumn("{task.description}"), transient=True) as progress:
        progress.add_task("Transkribiere Audio ...", total=None)
        segments, _ = model.transcribe(
            str(audio_path),
            language=WHISPER_LANG,
        )

    text = " ".join(segment.text for segment in segments).strip()
    console.print(f"[green]✓ Transkription fertig ({len(text)} Zeichen)[/green]")
    return text

# ── Protokoll via Claude CLI ──────────────────────────────────────────────────

def generate_protocol_cli(transcript: str) -> str:
    """Ruft claude --print via PowerShell auf (findet .cmd-Dateien auf Windows)."""
    import subprocess

    prompt = PROTOCOL_PROMPT + transcript

    # Prompt in Datei schreiben (umgeht Argumentlängen-Limit)
    tmp_in = tempfile.NamedTemporaryFile(suffix=".txt", delete=False, mode="w", encoding="utf-8")
    tmp_in.write(prompt)
    tmp_in.close()
    in_file = Path(tmp_in.name)

    tmp_out = tempfile.NamedTemporaryFile(suffix=".txt", delete=False)
    tmp_out.close()
    out_file = Path(tmp_out.name)

    console.print("[dim]Erstelle Protokoll mit Claude CLI ...[/dim]")

    # shell=True → cmd.exe findet claude.cmd automatisch im PATH
    # stdin/stdout als Python-File-Objekte: kein cmd-Redirect, kein Pfad-Problem
    try:
        with open(in_file, "r", encoding="utf-8") as fin, \
             open(out_file, "w", encoding="utf-8") as fout:
            subprocess.run(
                "claude --print",
                shell=True,
                stdin=fin,
                stdout=fout,
                timeout=300,
            )
    except subprocess.TimeoutExpired:
        console.print("[red]Timeout – Claude hat zu lange gebraucht (>5 min).[/red]")
        sys.exit(1)
    finally:
        in_file.unlink(missing_ok=True)

    text = ""
    if out_file.exists():
        text = out_file.read_text(encoding="utf-8").strip()
        out_file.unlink(missing_ok=True)

    if not text:
        console.print("[red]Protokoll ist leer.[/red]")
        console.print("[dim]Tipp: Teste manuell im Terminal: echo Hallo | claude --print[/dim]")
        sys.exit(1)

    return text

# ── Ausgabe ──────────────────────────────────────────────────────────────────

def format_markdown(protocol: dict, transcript: str, meeting_title: str) -> str:
    """Wandelt das Protokoll-Dict in ein schönes Markdown-Dokument um."""
    now = datetime.datetime.now().strftime("%d.%m.%Y %H:%M")
    lines = [
        f"# Meetingprotokoll – {meeting_title}",
        f"**Datum:** {now}",
        "",
        "---",
        "",
        "## 📋 Zusammenfassung",
        protocol.get("zusammenfassung", "–"),
        "",
    ]

    if protocol.get("teilnehmer"):
        lines += ["## 👥 Teilnehmer",
                  ", ".join(protocol["teilnehmer"]), ""]

    if protocol.get("themen"):
        lines.append("## 📌 Besprochene Themen")
        for t in protocol["themen"]:
            lines += [f"### {t['titel']}", t["inhalt"], ""]

    if protocol.get("entscheidungen"):
        lines.append("## ✅ Entscheidungen")
        for e in protocol["entscheidungen"]:
            lines.append(f"- {e}")
        lines.append("")

    if protocol.get("tasks"):
        lines += [
            "## 📝 Tasks",
            "| Task | Verantwortlich | Deadline | Priorität |",
            "|------|---------------|----------|-----------|",
        ]
        prio_icon = {"hoch": "🔴", "mittel": "🟡", "niedrig": "🟢"}
        for task in protocol["tasks"]:
            p = task.get("prioritaet", "mittel")
            icon = prio_icon.get(p, "⚪")
            lines.append(
                f"| {task['beschreibung']} "
                f"| {task.get('verantwortlich','–')} "
                f"| {task.get('deadline','offen')} "
                f"| {icon} {p} |"
            )
        lines.append("")

    if protocol.get("offene_fragen"):
        lines.append("## ❓ Offene Fragen")
        for f in protocol["offene_fragen"]:
            lines.append(f"- {f}")
        lines.append("")

    lines += ["---", "## 🎙 Vollständiges Transkript", "", transcript]
    return "\n".join(lines)

def save_transcript(transcript: str, title: str) -> Path:
    OUTPUT_DIR.mkdir(exist_ok=True)
    slug = title.lower().replace(" ", "_")
    date = datetime.datetime.now().strftime("%Y%m%d_%H%M")
    path = OUTPUT_DIR / f"{date}_{slug}.txt"
    path.write_text(transcript, encoding="utf-8")
    return path

# ── CLI ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Meeting aufnehmen oder Audiodatei transkribieren und als .txt speichern"
    )
    parser.add_argument("--file", "-f", type=Path,
                        help="Audio-Datei (mp3, wav, m4a, ...) ODER Transkript (.txt)")
    parser.add_argument("--title", "-t", default="Meeting",
                        help="Meeting-Titel für die Ausgabedatei")
    args = parser.parse_args()

    console.rule("[bold]🎙 Meeting Transcriber[/bold]")

    # 1. Audio-Quelle bestimmen
    if args.file and args.file.suffix.lower() == ".txt":
        # Transkript-Datei direkt einlesen, Whisper überspringen
        console.print(f"[blue]Transkript-Datei erkannt:[/blue] {args.file}")
        transcript = args.file.read_text(encoding="utf-8").strip()
        console.print(f"[green]✓ Transkript geladen ({len(transcript)} Zeichen)[/green]")
    else:
        if args.file:
            audio_path = args.file
            console.print(f"[blue]Verwende Audio-Datei:[/blue] {audio_path}")
        else:
            tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
            audio_path = Path(tmp.name)
            tmp.close()
            record_audio(audio_path)

        # 2. Transkription
        transcript = transcribe(audio_path)

        # 3. Transkript speichern
        save_transcript(transcript, args.title)

    # 4. Protokoll via Claude CLI
    protocol_md = generate_protocol_cli(transcript)

    # 5. Protokoll speichern
    OUTPUT_DIR.mkdir(exist_ok=True)
    slug = args.title.lower().replace(" ", "_")
    date = datetime.datetime.now().strftime("%Y%m%d_%H%M")
    out_path = OUTPUT_DIR / f"{date}_{slug}.md"
    out_path.write_text(protocol_md, encoding="utf-8")

    console.print(f"\n[bold green]✓ Protokoll gespeichert:[/bold green] {out_path}")
    console.print(Markdown(protocol_md))

if __name__ == "__main__":
    main()