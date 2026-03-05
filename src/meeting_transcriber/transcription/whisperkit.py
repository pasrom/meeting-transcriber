"""WhisperKit transcription via native Swift CLI (whisperkit-transcribe)."""

import logging
import os
import shutil
import subprocess
from pathlib import Path

from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn

log = logging.getLogger(__name__)
console = Console()

_BINARY_NAME = "whisperkit-transcribe"


def _project_search_anchors():
    """Yield candidate directories to search for project root."""
    # Package directory (src/meeting_transcriber/transcription -> project root)
    yield Path(__file__).resolve().parent.parent.parent.parent
    # CWD
    yield Path.cwd()


def _find_binary() -> Path | None:
    """Find the whisperkit-transcribe binary.

    Search order:
    1. WHISPERKIT_BINARY environment variable
    2. Project-local build output
    3. shutil.which() fallback
    """
    env_path = os.environ.get("WHISPERKIT_BINARY")
    if env_path:
        p = Path(env_path)
        if p.is_file() and os.access(p, os.X_OK):
            return p
        log.warning("WHISPERKIT_BINARY=%s is not executable", env_path)

    for anchor in _project_search_anchors():
        candidate = (
            anchor / "tools" / "whisperkit-cli" / ".build" / "release" / _BINARY_NAME
        )
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate

    which = shutil.which(_BINARY_NAME)
    if which:
        return Path(which)

    return None


def transcribe(
    audio_path: Path,
    model: str | None = None,
    language: str | None = None,
) -> str:
    """Transcribe using whisperkit-transcribe Swift binary.

    Args:
        audio_path: Path to audio file (WAV, M4A, etc.)
        model: WhisperKit model variant. None = device-recommended.
        language: Language code (e.g. 'de'). None = auto-detect.
    """
    binary = _find_binary()
    if not binary:
        raise FileNotFoundError(
            f"{_BINARY_NAME} binary not found. Run: ./scripts/build_whisperkit.sh"
        )

    cmd = [str(binary), str(audio_path)]
    if model:
        cmd.extend(["--model", model])
    if language:
        cmd.extend(["--language", language])

    label = model or "device-recommended"
    console.print(f"[dim]Transcribing with WhisperKit ({label})...[/dim]")

    with Progress(
        SpinnerColumn(), TextColumn("{task.description}"), transient=True
    ) as progress:
        progress.add_task("WhisperKit transcribing...", total=None)
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)

    if result.returncode != 0:
        raise RuntimeError(
            f"{_BINARY_NAME} failed (exit {result.returncode}): {result.stderr}"
        )

    transcript = result.stdout.strip()
    console.print(
        f"[green]Transcription complete ({len(transcript)} characters)[/green]"
    )
    return transcript
