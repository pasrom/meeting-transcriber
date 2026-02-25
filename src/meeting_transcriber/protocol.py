"""Protocol generation via Claude CLI and output helpers."""

import datetime
import subprocess
import sys
import tempfile
from pathlib import Path

from rich.console import Console

from meeting_transcriber.config import PROTOCOL_PROMPT

console = Console()


def generate_protocol_cli(
    transcript: str,
    title: str = "Meeting",
    diarized: bool = False,
    claude_bin: str = "claude",
) -> str:
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
                    f"{claude_bin} --print",
                    shell=True,
                    stdin=fin,
                    stdout=fout,
                    timeout=300,
                )
    except FileNotFoundError:
        console.print(
            f"[red]'{claude_bin}' CLI not found. Please install:"
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


def save_transcript(transcript: str, title: str, output_dir: Path) -> Path:
    """Save raw transcript to a text file."""
    output_dir.mkdir(exist_ok=True)
    slug = title.lower().replace(" ", "_")
    date = datetime.datetime.now().strftime("%Y%m%d_%H%M")
    path = output_dir / f"{date}_{slug}.txt"
    path.write_text(transcript, encoding="utf-8")
    return path


def save_protocol(protocol_md: str, title: str, output_dir: Path) -> Path:
    """Save generated protocol to a Markdown file."""
    output_dir.mkdir(exist_ok=True)
    slug = title.lower().replace(" ", "_")
    date = datetime.datetime.now().strftime("%Y%m%d_%H%M")
    path = output_dir / f"{date}_{slug}.md"
    path.write_text(protocol_md, encoding="utf-8")
    return path
