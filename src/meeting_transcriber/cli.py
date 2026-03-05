"""Unified CLI entry point for Meeting Transcriber."""

import argparse
import re
import sys
import tempfile
from pathlib import Path

from rich.console import Console
from rich.markdown import Markdown

from meeting_transcriber.config import (
    DEFAULT_CONFIRMATION_COUNT,
    DEFAULT_END_GRACE_PERIOD,
    DEFAULT_POLL_INTERVAL,
    DEFAULT_WHISPER_MODEL_MAC,
    DEFAULT_WHISPER_MODEL_WIN,
    default_output_dir,
)
from meeting_transcriber.protocol import (
    generate_protocol_cli,
    save_protocol,
    save_transcript,
)

console = Console()

IS_MAC = sys.platform == "darwin"
IS_WIN = sys.platform == "win32"


def main():
    default_model = DEFAULT_WHISPER_MODEL_MAC if IS_MAC else DEFAULT_WHISPER_MODEL_WIN

    parser = argparse.ArgumentParser(
        description=(
            "Meeting Transcriber – record audio, transcribe with Whisper,"
            " generate protocols with Claude"
        )
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
        default=default_model,
        help=f"Whisper model (default: {default_model})",
    )
    parser.add_argument(
        "--output-dir",
        "-o",
        type=Path,
        default=None,
        help="Output directory (default: ./protocols)",
    )
    parser.add_argument(
        "--engine",
        choices=["whisper", "whisperkit"],
        default="whisper",
        help=(
            "Transcription engine: 'whisper' (Python/pywhispercpp)"
            " or 'whisperkit' (native Swift CLI)"
        ),
    )

    # macOS-only flags
    parser.add_argument(
        "--app",
        "-a",
        type=str,
        default=None,
        help="App name for audio capture (macOS only, e.g. 'Microsoft Teams')",
    )
    parser.add_argument(
        "--pid",
        type=int,
        default=None,
        help="PID of the app for audio capture (macOS only)",
    )
    parser.add_argument(
        "--list-apps",
        action="store_true",
        help="List running apps and exit (macOS only)",
    )
    parser.add_argument(
        "--mic-only",
        action="store_true",
        help="Record microphone only, no app audio (macOS only)",
    )
    parser.add_argument(
        "--no-mic",
        action="store_true",
        help="Record app audio only, no microphone (macOS only)",
    )
    parser.add_argument(
        "--list-mics",
        action="store_true",
        help="List available microphone devices and exit (macOS only)",
    )
    parser.add_argument(
        "--mic",
        type=str,
        default=None,
        help="Microphone device index (int) or name substring (macOS only)",
    )
    parser.add_argument(
        "--mic-device",
        type=str,
        default=None,
        help="CoreAudio device UID for mic (used with ProcTap)",
    )

    # Claude CLI
    parser.add_argument(
        "--claude",
        type=str,
        default="claude",
        help="Claude CLI binary name (default: 'claude', e.g. 'claude-work')",
    )

    # Diarization
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
    parser.add_argument(
        "--merge-threshold",
        type=float,
        default=None,
        help="Cosine similarity threshold for merging "
        "duplicate speakers (default: 0.92)",
    )
    parser.add_argument(
        "--mic-name",
        type=str,
        default="Me",
        help=(
            "Label for mic speaker in dual-source mode (default: 'Me'). "
            "Use '' to diarize the mic track too (multi-person room)"
        ),
    )

    # Watch mode
    parser.add_argument(
        "--watch",
        action="store_true",
        help="Watch mode: auto-detect meetings and record (macOS only)",
    )
    parser.add_argument(
        "--watch-apps",
        type=str,
        nargs="+",
        default=None,
        help="Apps to watch (default: Teams, Zoom, Webex)",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=DEFAULT_POLL_INTERVAL,
        help=f"Seconds between polls in watch mode (default: {DEFAULT_POLL_INTERVAL})",
    )
    parser.add_argument(
        "--end-grace",
        type=float,
        default=DEFAULT_END_GRACE_PERIOD,
        help=(
            "Grace period in seconds before meeting is considered ended"
            f" (default: {DEFAULT_END_GRACE_PERIOD})"
        ),
    )
    parser.add_argument(
        "--native-transcription",
        action="store_true",
        help=(
            "Native transcription mode: emit recording_done"
            " and let the calling app handle transcription"
        ),
    )

    args = parser.parse_args()

    # Resolve output-dir default lazily (depends on MEETING_TRANSCRIBER_BUNDLED)
    if args.output_dir is None:
        args.output_dir = default_output_dir()

    # Validate macOS-only flags on Windows
    if IS_WIN and (
        args.app
        or args.pid
        or args.list_apps
        or args.mic_only
        or args.no_mic
        or args.list_mics
        or args.mic
        or args.mic_device
        or args.watch
    ):
        console.print(
            "[red]--app, --pid, --list-apps, --mic-only, --list-mics, --mic,"
            " --mic-device, --watch are macOS only.[/red]"
        )
        sys.exit(1)

    # Watch mode: auto-detect meetings
    if args.watch:
        from meeting_transcriber.watch.patterns import ALL_PATTERNS, PATTERN_BY_NAME
        from meeting_transcriber.watch.watcher import MeetingWatcher

        if args.watch_apps:
            patterns = []
            for name in args.watch_apps:
                key = name.lower()
                if key not in PATTERN_BY_NAME:
                    console.print(
                        f"[red]Unknown app '{name}'."
                        f" Available: {', '.join(PATTERN_BY_NAME)}[/red]"
                    )
                    sys.exit(1)
                patterns.append(PATTERN_BY_NAME[key])
        else:
            patterns = list(ALL_PATTERNS)

        # Resolve mic before entering watch mode
        mic_device = None
        if not args.no_mic:
            from meeting_transcriber.audio.mac import choose_mic

            mic_device = choose_mic(args.mic)

        watcher = MeetingWatcher(
            patterns=patterns,
            poll_interval=args.poll_interval,
            end_grace=args.end_grace,
            confirmation_count=DEFAULT_CONFIRMATION_COUNT,
            output_dir=args.output_dir,
            whisper_model=args.model,
            diarize=args.diarize,
            num_speakers=args.speakers,
            merge_threshold=args.merge_threshold,
            no_mic=args.no_mic,
            mic_device=mic_device,
            mic_device_uid=args.mic_device,
            claude_bin=args.claude,
            mic_label=args.mic_name,
            native_transcription=args.native_transcription,
        )
        watcher.run()
        sys.exit(0)

    # Resolve mic device (interactive selection if --mic not given)
    mic_device = None
    if (
        IS_MAC
        and not args.file
        and not args.list_mics
        and not args.list_apps
        and not args.no_mic
    ):
        from meeting_transcriber.audio.mac import choose_mic

        mic_device = choose_mic(args.mic)

    platform_name = "macOS" if IS_MAC else "Windows"
    console.rule(f"[bold]Meeting Transcriber – {platform_name}[/bold]")

    # --list-mics: list microphone devices and exit (macOS only)
    if args.list_mics:
        from meeting_transcriber.audio.mac import list_mic_devices

        mics = list_mic_devices()
        if not mics:
            console.print("[yellow]No input devices found.[/yellow]")
            sys.exit(0)
        console.print(f"\n[bold]Microphone devices ({len(mics)}):[/bold]\n")
        for m in mics:
            console.print(
                f"  {m['index']:>3}. {m['name']}"
                f"  [dim]({m['channels']}ch, {m['sample_rate']} Hz)[/dim]"
            )
        console.print()
        sys.exit(0)

    # --list-apps: list apps and exit (macOS only)
    if args.list_apps:
        from meeting_transcriber.audio.mac import list_audio_apps

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
    recording = None  # RecordingResult from live recording (if any)
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
            if IS_MAC:
                from meeting_transcriber.audio.mac import choose_app, record_audio

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
                recording = record_audio(
                    audio_path,
                    app_pid=app_pid,
                    mic_only=args.mic_only,
                    no_mic=args.no_mic,
                    mic_device=mic_device,
                    mic_device_uid=args.mic_device,
                )
            else:
                from meeting_transcriber.audio.windows import record_audio

                tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
                audio_path = Path(tmp.name)
                tmp.close()
                record_audio(audio_path)

        # 2. Transcription
        if args.engine == "whisperkit":
            from meeting_transcriber.transcription.whisperkit import (
                transcribe as wk_transcribe,
            )

            transcript = wk_transcribe(audio_path)
        elif IS_MAC:
            from meeting_transcriber.transcription.mac import transcribe

            extra_kwargs = {}
            if recording is not None:
                extra_kwargs["app_audio"] = recording.app
                extra_kwargs["mic_audio"] = recording.mic
                extra_kwargs["mic_label"] = args.mic_name
                extra_kwargs["mic_delay"] = recording.mic_delay
                extra_kwargs["mute_timeline"] = recording.mute_timeline
                extra_kwargs["recording_start"] = recording.recording_start
            if args.merge_threshold is not None:
                extra_kwargs["merge_threshold"] = args.merge_threshold
            transcript = transcribe(
                audio_path,
                model=args.model,
                diarize_enabled=args.diarize,
                num_speakers=args.speakers,
                **extra_kwargs,
            )
        else:
            from meeting_transcriber.transcription.windows import transcribe

            transcript = transcribe(
                audio_path,
                model=args.model,
            )

        # 3. Save transcript
        txt_path = save_transcript(transcript, args.title, args.output_dir)
        console.print(f"[dim]Transcript saved: {txt_path}[/dim]")

    # 4. Protocol via Claude CLI
    diarized = bool(re.search(r"\[\w[\w\s]*\]", transcript))
    protocol_md = generate_protocol_cli(
        transcript, title=args.title, diarized=diarized, claude_bin=args.claude
    )

    # 5. Append full transcript and save protocol
    full_md = protocol_md + "\n\n---\n\n## Full Transcript\n\n" + transcript
    out_path = save_protocol(full_md, args.title, args.output_dir)
    console.print(f"\n[bold green]Protocol saved:[/bold green] {out_path}")
    console.print(Markdown(protocol_md))


if __name__ == "__main__":
    main()
