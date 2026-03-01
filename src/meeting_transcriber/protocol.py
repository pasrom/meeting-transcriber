"""Protocol generation via Claude CLI and output helpers."""

import datetime
import json
import subprocess
import threading
import time
from pathlib import Path

from rich.console import Console

from meeting_transcriber.config import PROTOCOL_PROMPT

console = Console()

TIMEOUT_SECONDS = 600


def generate_protocol_cli(
    transcript: str,
    title: str = "Meeting",
    diarized: bool = False,
    claude_bin: str = "claude",
) -> str:
    """Call Claude CLI with stream-json output for live progress."""
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

    console.print("[dim]Generating protocol with Claude CLI ...[/dim]")

    try:
        proc = subprocess.Popen(
            [
                claude_bin,
                "-p",
                "-",
                "--output-format",
                "stream-json",
                "--verbose",
                "--model",
                "sonnet",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError:
        raise FileNotFoundError(
            f"'{claude_bin}' CLI not found. "
            "Please install: npm install -g @anthropic-ai/claude-code"
        )

    # Write prompt in a thread to avoid deadlock if pipe buffer fills up
    def _feed_stdin():
        try:
            proc.stdin.write(prompt.encode("utf-8"))
            proc.stdin.close()
        except BrokenPipeError:
            pass  # Process died early; handled via returncode check below

    writer = threading.Thread(target=_feed_stdin, daemon=True)
    writer.start()

    # Drain stderr in a thread to prevent pipe buffer from filling → deadlock
    stderr_lines: list[str] = []

    def _drain_stderr():
        for raw in proc.stderr:
            stderr_lines.append(raw.decode("utf-8", errors="replace"))

    stderr_thread = threading.Thread(target=_drain_stderr, daemon=True)
    stderr_thread.start()

    try:
        text = _read_stream(proc)
    except TimeoutError:
        proc.kill()
        proc.wait()
        raise TimeoutError("Claude CLI took too long (>10 min)")
    finally:
        writer.join(timeout=5)
        stderr_thread.join(timeout=5)

    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()

    if proc.returncode != 0:
        stderr_text = "".join(stderr_lines).strip()
        raise RuntimeError(
            f"Claude CLI exited with code {proc.returncode}"
            + (f": {stderr_text}" if stderr_text else "")
        )

    if not text.strip():
        raise RuntimeError(
            "Protocol is empty. Tip: Test manually: echo Hello | claude --print"
        )

    return text.strip()


def _read_stream(proc: subprocess.Popen) -> str:
    """Read stream-json output, print live deltas, return full text."""
    parts: list[str] = []
    start = time.monotonic()

    # readline() is unbuffered per-line; `for line in proc.stdout` buffers ~8KB
    while True:
        if time.monotonic() - start > TIMEOUT_SECONDS:
            raise TimeoutError

        raw_line = proc.stdout.readline()
        if not raw_line:
            break  # EOF

        line = raw_line.decode("utf-8", errors="replace").strip()
        if not line:
            continue

        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue

        # content_block_delta carries streaming text chunks
        if obj.get("type") == "content_block_delta":
            delta = obj.get("delta", {})
            if delta.get("type") == "text_delta":
                chunk = delta["text"]
                parts.append(chunk)
                print(chunk, end="", flush=True)

        # assistant message carries the final full text
        elif obj.get("type") == "assistant":
            for block in obj.get("message", {}).get("content", []):
                if block.get("type") == "text":
                    if not parts:
                        parts.append(block["text"])

    proc.wait()
    if parts:
        print()  # final newline after streamed output
    return "".join(parts)


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
