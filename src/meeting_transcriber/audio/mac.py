"""macOS audio recording via CATapDescription (audiotap) and sounddevice."""

import logging
import os
import shutil
import signal
import subprocess
import sys
import threading
import wave
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import sounddevice as sd
from rich.console import Console


@dataclass
class RecordingResult:
    """Result of a recording session with paths to individual tracks."""

    mix: Path
    app: Path | None = None
    mic: Path | None = None
    mic_delay: float = 0.0  # seconds: mic started this much later than app
    aec_applied: bool = False  # kept for backward compat
    mute_timeline: list = field(default_factory=list)
    recording_start: float = 0.0  # time.monotonic() when recording began


log = logging.getLogger(__name__)

RECORD_RATE = 48000  # native rate for CATapDescription aggregate device

console = Console()


def list_mic_devices() -> list[dict]:
    """List available microphone input devices."""
    devices = sd.query_devices()
    mics = []
    for i, dev in enumerate(devices):
        if dev["max_input_channels"] > 0:
            mics.append(
                {
                    "index": i,
                    "name": dev["name"],
                    "channels": dev["max_input_channels"],
                    "sample_rate": int(dev["default_samplerate"]),
                }
            )
    return mics


def choose_mic(mic_spec: str | None) -> int | None:
    """Select a mic by index/name or show interactive selection.

    Returns device index or None for system default.
    """
    mics = list_mic_devices()
    if not mics:
        console.print("[yellow]No input devices found.[/yellow]")
        return None

    if mic_spec is not None:
        # Try as integer index
        try:
            idx = int(mic_spec)
            dev = sd.query_devices(idx)
            if dev["max_input_channels"] == 0:
                console.print(f"[red]Device {idx} is not an input device.[/red]")
                sys.exit(1)
            console.print(f"[green]Mic selected:[/green] {dev['name']}")
            return idx
        except ValueError:
            pass

        # Name substring match
        matches = [m for m in mics if mic_spec.lower() in m["name"].lower()]
        if len(matches) == 1:
            console.print(f"[green]Mic selected:[/green] {matches[0]['name']}")
            return matches[0]["index"]
        if len(matches) > 1:
            console.print(f"[yellow]Multiple mics match '{mic_spec}':[/yellow]")
            for i, m in enumerate(matches, 1):
                console.print(
                    f"  {i}. {m['name']}  [dim]({m['channels']}ch,"
                    f" {m['sample_rate']} Hz)[/dim]"
                )
            choice = input("Choose number: ").strip()
            try:
                return matches[int(choice) - 1]["index"]
            except (ValueError, IndexError):
                console.print("[red]Invalid selection.[/red]")
                sys.exit(1)
        console.print(f"[red]No microphone matching '{mic_spec}' found.[/red]")
        sys.exit(1)

    # Non-interactive: use system default when no TTY (e.g. launched from app)
    if not sys.stdin.isatty():
        default_idx = sd.default.device[0]
        mic_name = sd.query_devices(default_idx)["name"]
        console.print(f"[dim]Using default mic (non-interactive): {mic_name}[/dim]")
        return None

    # Interactive selection
    default_idx = sd.default.device[0]
    console.print("\n[bold]Microphone devices:[/bold]")
    for i, m in enumerate(mics, 1):
        marker = " [green](default)[/green]" if m["index"] == default_idx else ""
        console.print(
            f"  {i:>3}. {m['name']}"
            f"  [dim]({m['channels']}ch, {m['sample_rate']} Hz)[/dim]"
            f"{marker}"
        )
    choice = input("\nChoose number (or Enter for default): ").strip()
    if not choice:
        return None
    try:
        return mics[int(choice) - 1]["index"]
    except (ValueError, IndexError):
        console.print("[red]Invalid selection.[/red]")
        sys.exit(1)


def list_audio_apps() -> list[dict]:
    """List running GUI apps (macOS) via NSWorkspace."""
    try:
        from AppKit import NSApplicationActivationPolicyRegular, NSWorkspace
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
            if not sys.stdin.isatty():
                console.print(
                    f"[dim]Multiple matches for '{app_name}',"
                    f" using first: {matches[0]['name']}[/dim]"
                )
                return matches[0]
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


def _project_search_anchors() -> list[Path]:
    """Return anchor paths to search upward for the project root."""
    return [Path(__file__).resolve(), Path.cwd()]


def _find_swift_binary() -> Path | None:
    """Find the audiotap Swift binary.

    Search order:
    1. AUDIOTAP_BINARY environment variable
    2. Project-local build output (tools/audiotap/.build/release/audiotap)
    3. shutil.which() fallback
    """
    # 1. Explicit env var
    env_path = os.environ.get("AUDIOTAP_BINARY")
    if env_path:
        p = Path(env_path)
        if p.is_file() and os.access(p, os.X_OK):
            return p
        log.warning("AUDIOTAP_BINARY=%s is not an executable file", env_path)

    # 2. Project-local build output (walk up from package/cwd to find tools/)
    for anchor in _project_search_anchors():
        d = anchor
        for _ in range(6):
            d = d.parent
            candidate = d / "tools" / "audiotap" / ".build" / "release" / "audiotap"
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return candidate

    # 3. Fall back to PATH lookup
    which = shutil.which("audiotap")
    if which:
        return Path(which)

    return None


def record_audio(
    output_path: Path,
    app_pid: int | None = None,
    mic_only: bool = False,
    no_mic: bool = False,
    mic_device: int | None = None,
    mic_device_uid: str | None = None,
    stop_event: threading.Event | None = None,
) -> RecordingResult:
    """Record app audio (audiotap/CATapDescription) and/or microphone (sounddevice).

    Args:
        mic_device_uid: CoreAudio device UID for audiotap mic selection.

    If stop_event is provided, recording is controlled externally (watch mode).
    Otherwise, the user presses Enter to stop (interactive mode).
    """
    frames_app: list[bytes] = []
    frames_mic: list[np.ndarray] = []
    _stop = stop_event if stop_event is not None else threading.Event()
    app_rate = RECORD_RATE
    app_channels = 2
    mic_wav_path: Path | None = None  # mic WAV written by audiotap

    # ── App audio via CATapDescription (audiotap subprocess) ────────────
    app_proc = None
    app_reader_thread = None
    audiotap_has_mic = False  # audiotap is recording mic with --mic flag
    if app_pid and not mic_only:
        binary = _find_swift_binary()
        if not binary:
            console.print(
                "[red]audiotap binary not found."
                " Run: cd tools/audiotap && swift build -c release[/red]"
            )
            sys.exit(1)

        try:
            # Save individual tracks to recordings/
            from meeting_transcriber.config import get_data_dir

            rec_dir = get_data_dir() / "recordings"
            rec_dir.mkdir(exist_ok=True)
            ts = output_path.stem

            cmd = [
                str(binary),
                str(app_pid),
                str(RECORD_RATE),
                str(app_channels),
            ]

            # Pass --mic to audiotap when mic is enabled
            if not no_mic:
                mic_wav_path = rec_dir / f"{ts}_mic.wav"
                cmd.extend(["--mic", str(mic_wav_path)])
                if mic_device_uid:
                    cmd.extend(["--mic-device", mic_device_uid])
                audiotap_has_mic = True

            app_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0,
            )

            def _read_app_audio():
                chunk_size = RECORD_RATE * app_channels * 4 * 10 // 1000
                while not _stop.is_set():
                    data = app_proc.stdout.read(chunk_size)
                    if not data:
                        break
                    frames_app.append(data)

            app_reader_thread = threading.Thread(target=_read_app_audio, daemon=True)
            app_reader_thread.start()
            console.print(
                f"[dim]App audio active: PID {app_pid},"
                f" {RECORD_RATE} Hz, {app_channels}ch[/dim]"
            )
            if audiotap_has_mic:
                console.print("[dim]Mic recording via audiotap[/dim]")
        except Exception as e:
            console.print(
                f"[yellow]App audio failed ({type(e).__name__}: {e}),"
                " microphone only.[/yellow]"
            )
            app_proc = None
            audiotap_has_mic = False
            mic_wav_path = None

    # ── Microphone via sounddevice (only when audiotap is NOT handling mic) ──
    mic_rate = app_rate  # match app rate so we can mix without resampling
    mic_stream = None

    if not no_mic and not audiotap_has_mic:
        _mic_restart_needed = threading.Event()

        def mic_callback(indata, frame_count, time_info, status):
            if status:
                log.warning("Mic stream status: %s", status)
                _mic_restart_needed.set()
            if not _stop.is_set():
                frames_mic.append(indata[:, 0].copy())

        def _open_mic_stream(device=mic_device):
            s = sd.InputStream(
                samplerate=mic_rate,
                channels=1,
                dtype="float32",
                callback=mic_callback,
                blocksize=1024,
                device=device,
            )
            s.start()
            return s

        mic_stream = _open_mic_stream()

        # Validate actual sample rate matches requested rate
        actual_rate = mic_stream.samplerate
        if actual_rate != mic_rate:
            console.print(
                f"[yellow]Mic rate mismatch: requested {mic_rate} Hz,"
                f" got {actual_rate} Hz. Adjusting.[/yellow]"
            )
            mic_rate = int(actual_rate)

        dev_idx = mic_device if mic_device is not None else sd.default.device[0]
        mic_name = sd.query_devices(dev_idx)["name"]
        console.print(f"[dim]Microphone active: {mic_name} ({mic_rate} Hz, mono)[/dim]")
    elif no_mic:
        console.print("[dim]Microphone disabled (--no-mic)[/dim]")

    # ── Mute detection (Teams only, best-effort) ────────────────────────
    mute_tracker = None
    if app_pid and not no_mic:
        try:
            from meeting_transcriber.watch.mute_detector import MuteTracker

            mute_tracker = MuteTracker(teams_pid=app_pid)
            mute_tracker.start()
            if mute_tracker.is_active:
                console.print(f"[dim]Mute detection active (PID {app_pid})[/dim]")
            else:
                console.print(
                    "[yellow]Mute detection unavailable"
                    " (Accessibility permission needed)[/yellow]"
                )
                mute_tracker = None
        except Exception as exc:
            console.print(f"[yellow]Mute tracker not available: {exc}[/yellow]")

    # ── Recording loop ───────────────────────────────────────────────────
    import time as _time

    recording_start = _time.monotonic()

    def _mic_restart_loop():
        """Background thread: restart mic stream when device changes.

        Detects changes two ways:
        1. Callback status errors (device disappears / hardware issue)
        2. Polling: system default input device changes (e.g. AirPods connected)
        """
        nonlocal mic_stream
        _current_default = sd.default.device[0]
        while not _stop.is_set():
            need_restart = _mic_restart_needed.wait(timeout=2.0)
            if _stop.is_set():
                break
            # Also check if the system default input device changed
            try:
                new_default = sd.default.device[0]
            except Exception:
                continue
            if not need_restart and new_default != _current_default:
                need_restart = True
                log.info(
                    "Default input device changed: %s → %s",
                    _current_default,
                    new_default,
                )
            if not need_restart:
                continue
            _mic_restart_needed.clear()
            _current_default = new_default
            try:
                mic_stream.stop()
                mic_stream.close()
            except Exception:
                pass
            try:
                # Re-open with new system default device
                mic_stream = _open_mic_stream(device=None)
                new_dev = sd.query_devices(sd.default.device[0])["name"]
                _current_default = sd.default.device[0]
                console.print(
                    f"[yellow]Mic device changed → restarted on: {new_dev}[/yellow]"
                )
            except Exception as exc:
                log.error("Failed to restart mic stream: %s", exc)
                console.print(f"[red]Mic stream lost (device change): {exc}[/red]")

    if mic_stream is not None:
        _mic_watcher = threading.Thread(
            target=_mic_restart_loop, daemon=True, name="mic-restart"
        )
        _mic_watcher.start()

    try:
        if stop_event is None:
            # Interactive mode: user presses Enter to stop
            console.print(
                "\n[bold green]Recording ...[/bold green]"
                "  [dim]Press Enter to stop[/dim]\n"
            )
            input()
            _stop.set()
        else:
            # Watch mode: externally controlled via stop_event
            console.print(
                "\n[bold green]Recording ...[/bold green]  [dim](auto-stop)[/dim]\n"
            )
            _stop.wait()
    finally:
        # Always clean up resources, even if an exception occurs
        if mute_tracker:
            mute_tracker.stop()
            console.print(
                f"[dim]Mute tracker: {len(mute_tracker.timeline)} transitions[/dim]"
            )
        if mic_stream:
            try:
                mic_stream.stop()
                mic_stream.close()
            except Exception as exc:
                log.warning("Error closing mic stream: %s", exc)
        if app_proc:
            try:
                app_proc.send_signal(signal.SIGTERM)
            except OSError:
                pass  # Process already dead
            if app_reader_thread:
                app_reader_thread.join(timeout=2)
            try:
                app_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                app_proc.kill()
                app_proc.wait()

    # ── Parse audiotap stderr (MIC_DELAY, ACTUAL_RATE, format info, warnings) ──
    mic_delay = 0.0
    actual_app_rate = app_rate
    if app_proc:
        try:
            stderr_out = app_proc.stderr.read().decode("utf-8", errors="ignore")
            if stderr_out:
                for line in stderr_out.strip().splitlines():
                    if line.startswith("MIC_DELAY="):
                        mic_delay = float(line.split("=", 1)[1])
                        console.print(
                            f"[dim]Stream start delta: {mic_delay:+.3f}s"
                            " (mic vs app, from audiotap)[/dim]"
                        )
                    elif line.startswith("ACTUAL_RATE="):
                        actual_app_rate = int(line.split("=", 1)[1])
                        console.print(
                            f"[yellow]App audio actual rate: {actual_app_rate} Hz"
                            f" (requested {app_rate} Hz)[/yellow]"
                        )
                    elif (
                        "Audio format:" in line or "WARNING" in line or "ERROR" in line
                    ):
                        console.print(f"[dim]{line}[/dim]")
        except Exception:
            pass

    # ── Mix → WAV ────────────────────────────────────────────────────────
    audio_mic = np.concatenate(frames_mic) if frames_mic else np.zeros(0)

    audio_app = np.zeros(0)
    if frames_app:
        raw = np.frombuffer(b"".join(frames_app), dtype=np.float32)
        # Stereo → Mono (trim to even length to avoid reshape crash)
        if app_channels == 2 and len(raw) >= 2:
            n = len(raw) - len(raw) % 2
            raw = raw[:n].reshape(-1, 2).mean(axis=1)
        audio_app = raw

    # Save individual tracks to recordings/
    from meeting_transcriber.config import get_data_dir

    rec_dir = get_data_dir() / "recordings"
    rec_dir.mkdir(parents=True, exist_ok=True)
    ts = output_path.stem
    app_path: Path | None = None
    mic_path: Path | None = None
    if len(audio_app) > 0:
        app_path = rec_dir / f"{ts}_app.wav"
        _save_wav(app_path, audio_app, actual_app_rate)
        console.print(f"[dim]App audio saved: {app_path} ({actual_app_rate} Hz)[/dim]")
        # Resample app audio to target rate if device rate differs
        if actual_app_rate != app_rate:
            from math import gcd

            from scipy.signal import resample_poly

            g = gcd(app_rate, actual_app_rate)
            audio_app = resample_poly(audio_app, app_rate // g, actual_app_rate // g)
            console.print(
                f"[dim]App resampled {actual_app_rate}→{app_rate} Hz for mix[/dim]"
            )

    # Mic track: from audiotap WAV or sounddevice frames
    if audiotap_has_mic and mic_wav_path and mic_wav_path.exists():
        if mic_wav_path.stat().st_size > 44:  # WAV header is 44 bytes
            mic_path = mic_wav_path
            console.print(f"[dim]Mic audio saved: {mic_path}[/dim]")
            # Load mic WAV for mixing
            with wave.open(str(mic_path), "rb") as wf:
                mic_channels = wf.getnchannels()
                mic_rate = wf.getframerate()
                mic_sampwidth = wf.getsampwidth()
                mic_raw = wf.readframes(wf.getnframes())
            if mic_sampwidth == 2:
                audio_mic = (
                    np.frombuffer(mic_raw, dtype=np.int16).astype(np.float32) / 32768.0
                )
            else:
                audio_mic = np.frombuffer(mic_raw, dtype=np.float32)
            if mic_channels > 1:
                audio_mic = audio_mic.reshape(-1, mic_channels).mean(axis=1)
            # Resample mic to app_rate if rates differ (e.g. 24kHz mic → 48kHz app)
            if mic_rate != app_rate:
                from math import gcd

                from scipy.signal import resample_poly

                g = gcd(app_rate, mic_rate)
                audio_mic = resample_poly(audio_mic, app_rate // g, mic_rate // g)
                console.print(
                    f"[dim]Mic resampled {mic_rate}→{app_rate} Hz for mix[/dim]"
                )
        else:
            console.print("[yellow]Mic WAV from audiotap is empty.[/yellow]")
    elif len(audio_mic) > 0:
        mic_path = rec_dir / f"{ts}_mic.wav"
        _save_wav(mic_path, audio_mic, mic_rate)
        console.print(f"[dim]Mic audio saved: {mic_path}[/dim]")

    # ── Warn if mic track is suspiciously short/empty ────────────────────
    if len(audio_app) > 0:
        app_dur = len(audio_app) / app_rate
        mic_dur = len(audio_mic) / app_rate if len(audio_mic) > 0 else 0.0
        if mic_dur < 1.0:
            console.print(
                "[bold red]Warning: Mic track is empty!"
                " Your voice will NOT appear in the transcript."
                " Check if your audio device changed during recording.[/bold red]"
            )
        elif app_dur > 10.0 and mic_dur < app_dur * 0.1:
            console.print(
                f"[bold yellow]Warning: Mic track ({mic_dur:.0f}s) is much shorter"
                f" than app audio ({app_dur:.0f}s)."
                " Parts of your voice may be missing — did the audio device"
                " change during recording?[/bold yellow]"
            )

    # Mix (resample above ensures both streams are at app_rate)
    min_len = min(len(audio_mic), len(audio_app))
    if min_len > 0:
        mixed = (audio_mic[:min_len] + audio_app[:min_len]) / 2
        if len(audio_mic) > min_len:
            mixed = np.concatenate([mixed, audio_mic[min_len:]])
        elif len(audio_app) > min_len:
            mixed = np.concatenate([mixed, audio_app[min_len:]])
    else:
        mixed = audio_mic if len(audio_mic) > 0 else audio_app

    if len(mixed) == 0:
        raise RuntimeError("No audio data recorded")

    # Save mix to recordings/ and use as output
    mix_path = rec_dir / f"{ts}_mix.wav"
    _save_wav(mix_path, mixed, app_rate)
    console.print(f"[dim]Mix saved: recordings/{ts}_mix.wav[/dim]")

    # Copy to output_path for the pipeline (Whisper etc.)
    shutil.copy2(mix_path, output_path)

    duration = len(mixed) / app_rate
    console.print(f"[green]Recording saved ({duration:.1f}s): {output_path}[/green]")
    return RecordingResult(
        mix=output_path,
        app=app_path,
        mic=mic_path,
        mic_delay=mic_delay,
        mute_timeline=mute_tracker.timeline if mute_tracker else [],
        recording_start=recording_start,
    )


def _save_wav(path: Path, audio: np.ndarray, rate: int) -> None:
    """Write float32 mono audio to 16-bit WAV."""
    audio_int16 = (np.clip(audio, -1.0, 1.0) * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(audio_int16.tobytes())
