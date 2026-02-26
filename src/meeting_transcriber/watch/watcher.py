"""Watch-mode orchestrator: detect meetings, record, run pipeline."""

import tempfile
import threading
import time
from pathlib import Path

from rich.console import Console

from meeting_transcriber.config import (
    DEFAULT_END_GRACE_PERIOD,
    DEFAULT_OUTPUT_DIR,
    DEFAULT_POLL_INTERVAL,
)
from meeting_transcriber.watch.detector import DetectedMeeting, MeetingDetector
from meeting_transcriber.watch.patterns import AppMeetingPattern

console = Console()


class MeetingWatcher:
    """Watches for meetings, records audio, and runs the transcription pipeline."""

    def __init__(
        self,
        patterns: list[AppMeetingPattern],
        poll_interval: float = DEFAULT_POLL_INTERVAL,
        end_grace: float = DEFAULT_END_GRACE_PERIOD,
        confirmation_count: int = 2,
        output_dir: Path = DEFAULT_OUTPUT_DIR,
        whisper_model: str | None = None,
        diarize: bool = False,
        num_speakers: int | None = None,
        no_mic: bool = False,
        mic_device: int | None = None,
        claude_bin: str = "claude",
    ):
        self.detector = MeetingDetector(patterns, confirmation_count=confirmation_count)
        self.poll_interval = poll_interval
        self.end_grace = end_grace
        self.output_dir = output_dir
        self.whisper_model = whisper_model
        self.diarize = diarize
        self.num_speakers = num_speakers
        self.no_mic = no_mic
        self.mic_device = mic_device
        self.claude_bin = claude_bin

    def run(self) -> None:
        """Main loop: poll for meetings, record, run pipeline. Blocks until Ctrl+C."""
        console.print(
            "\n[bold]Watch mode active[/bold] — waiting for meetings...\n"
            f"  Poll interval: {self.poll_interval}s\n"
            f"  Grace period:  {self.end_grace}s\n"
            f"  Apps:          "
            f"{', '.join(p.app_name for p in self.detector.patterns)}\n"
        )
        console.print("[dim]Press Ctrl+C to exit[/dim]\n")

        try:
            while True:
                meeting = self.detector.check_once()
                if meeting:
                    self._handle_meeting(meeting)
                    self.detector.reset()
                time.sleep(self.poll_interval)
        except KeyboardInterrupt:
            console.print("\n[yellow]Watch mode stopped.[/yellow]")

    def _handle_meeting(self, meeting: DetectedMeeting) -> None:
        """Record a meeting, wait for it to end, then run the pipeline."""
        console.rule(
            f"[bold green]Meeting detected: {meeting.window_title}[/bold green]"
        )
        console.print(f"  App: {meeting.pattern.app_name} (PID {meeting.window_pid})\n")

        # Prepare recording
        stop_event = threading.Event()
        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        audio_path = Path(tmp.name)
        tmp.close()

        # Start recording in a background thread
        record_thread = threading.Thread(
            target=self._record,
            args=(audio_path, meeting.window_pid, stop_event),
            daemon=True,
        )
        record_thread.start()

        # Wait for meeting to end
        self._wait_for_meeting_end(meeting)

        # Stop recording
        console.print("[yellow]Stopping recording...[/yellow]")
        stop_event.set()
        record_thread.join(timeout=10)

        if not audio_path.exists() or audio_path.stat().st_size == 0:
            console.print("[red]No audio recorded, skipping pipeline.[/red]")
            return

        # Run pipeline
        console.rule("[bold]Running transcription pipeline[/bold]")
        self._run_pipeline(audio_path, meeting)

    def _record(
        self,
        audio_path: Path,
        app_pid: int,
        stop_event: threading.Event,
    ) -> None:
        """Run record_audio in a thread."""
        try:
            from meeting_transcriber.audio.mac import record_audio

            record_audio(
                audio_path,
                app_pid=app_pid,
                no_mic=self.no_mic,
                mic_device=self.mic_device,
                stop_event=stop_event,
            )
        except Exception as e:
            console.print(f"[red]Recording error: {e}[/red]")

    def _wait_for_meeting_end(self, meeting: DetectedMeeting) -> None:
        """Poll until the meeting window disappears, with grace period."""
        grace_start: float | None = None

        try:
            while True:
                active = self.detector.is_meeting_active(meeting)

                if active:
                    if grace_start is not None:
                        console.print(
                            "[dim]Meeting window reappeared,"
                            " cancelling grace period.[/dim]"
                        )
                        grace_start = None
                else:
                    if grace_start is None:
                        console.print(
                            f"[yellow]Meeting window gone, grace period"
                            f" ({self.end_grace}s)...[/yellow]"
                        )
                        grace_start = time.time()
                    elif time.time() - grace_start >= self.end_grace:
                        console.print("[yellow]Grace period expired.[/yellow]")
                        return

                time.sleep(self.poll_interval)
        except KeyboardInterrupt:
            console.print("\n[yellow]Manual stop.[/yellow]")

    def _run_pipeline(self, audio_path: Path, meeting: DetectedMeeting) -> None:
        """Transcribe + generate protocol."""
        title = meeting.window_title
        # Strip " | Microsoft Teams" etc. for a cleaner title
        for suffix in [" | Microsoft Teams", " - Zoom", " - Webex"]:
            if title.endswith(suffix):
                title = title[: -len(suffix)]
                break

        try:
            from meeting_transcriber.transcription.mac import transcribe

            transcript = transcribe(
                audio_path,
                model=self.whisper_model,
                diarize_enabled=self.diarize,
                num_speakers=self.num_speakers,
            )
        except Exception as e:
            console.print(
                f"[red]Transcription failed: {e}[/red]\n"
                f"[dim]Audio file preserved: {audio_path}[/dim]"
            )
            return

        from meeting_transcriber.protocol import (
            generate_protocol_cli,
            save_protocol,
            save_transcript,
        )

        txt_path = save_transcript(transcript, title, self.output_dir)
        console.print(f"[dim]Transcript saved: {txt_path}[/dim]")

        try:
            diarized = "[SPEAKER_" in transcript
            protocol_md = generate_protocol_cli(
                transcript, title=title, diarized=diarized, claude_bin=self.claude_bin
            )
            out_path = save_protocol(protocol_md, title, self.output_dir)
            console.print(f"\n[bold green]Protocol saved:[/bold green] {out_path}")
        except Exception as e:
            console.print(
                f"[red]Protocol generation failed: {e}[/red]\n"
                f"[dim]Transcript preserved: {txt_path}[/dim]"
            )
            return

        console.print("\n[bold]Pipeline complete.[/bold] Resuming watch mode...\n")
