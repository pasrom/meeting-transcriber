"""E2E test for speaker naming IPC via the Swift menu bar app.

Requires:
- Built app binary: app/MeetingTranscriber/.build/release/MeetingTranscriber
- Accessibility permission for Terminal.app (System Settings → Privacy → Accessibility)
"""

import json
import os
import subprocess
import time
from pathlib import Path

import pytest

PROJECT = Path(__file__).resolve().parent.parent
STATUS_DIR = Path.home() / ".meeting-transcriber"
SPEAKER_REQUEST_FILE = STATUS_DIR / "speaker_request.json"
SPEAKER_RESPONSE_FILE = STATUS_DIR / "speaker_response.json"
SPEAKER_SAMPLES_DIR = STATUS_DIR / "speaker_samples"
STATUS_FILE = STATUS_DIR / "status.json"
APP_BINARY = (
    PROJECT / "app" / "MeetingTranscriber" / ".build" / "release" / "MeetingTranscriber"
)


# ── AppleScript helpers ──────────────────────────────────────────────────────


def applescript(script: str) -> str:
    """Run AppleScript and return stdout."""
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=10,
    )
    return result.stdout.strip()


def window_exists(title: str) -> bool:
    """Check if a window with the given title exists in the app."""
    return (
        applescript(f'''
        tell application "System Events"
            tell process "MeetingTranscriber"
                return exists window "{title}"
            end tell
        end tell
    ''')
        == "true"
    )


def applescript_fill_names(names: dict[str, str]) -> None:
    """Fill in speaker names via AppleScript.

    Text fields are inside GroupBox groups within the main content group.
    """
    for i, (_label, name) in enumerate(names.items()):
        grp = i + 1  # group 1 = SPEAKER_00, group 2 = SPEAKER_01
        applescript(
            'tell application "System Events"\n'
            '    tell process "MeetingTranscriber"\n'
            "        tell group 1 of "
            'window "Name Speakers"\n'
            f"            set value of text field 1"
            f' of group {grp} to "{name}"\n'
            "        end tell\n"
            "    end tell\n"
            "end tell"
        )


def applescript_click_confirm() -> None:
    """Click the Confirm button (button 2 inside the content group)."""
    applescript(
        'tell application "System Events"\n'
        '    tell process "MeetingTranscriber"\n'
        "        tell group 1 of "
        'window "Name Speakers"\n'
        "            click button 2\n"
        "        end tell\n"
        "    end tell\n"
        "end tell"
    )


# ── Test data helpers ────────────────────────────────────────────────────────


def write_test_speaker_request() -> None:
    """Write a speaker_request.json with 2 test speakers."""
    STATUS_DIR.mkdir(parents=True, exist_ok=True)
    SPEAKER_SAMPLES_DIR.mkdir(parents=True, exist_ok=True)

    # Create dummy WAV files
    import wave

    import numpy as np

    for label in ("SPEAKER_00", "SPEAKER_01"):
        wav_path = SPEAKER_SAMPLES_DIR / f"{label}.wav"
        silence = np.zeros(16000, dtype=np.int16)  # 1s silence
        with wave.open(str(wav_path), "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(16000)
            wf.writeframes(silence.tobytes())

    data = {
        "version": 1,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "meeting_title": "E2E Test Meeting",
        "audio_samples_dir": str(SPEAKER_SAMPLES_DIR),
        "speakers": [
            {
                "label": "SPEAKER_00",
                "auto_name": "Roman",
                "confidence": 0.85,
                "speaking_time_seconds": 120.0,
                "sample_file": "SPEAKER_00.wav",
            },
            {
                "label": "SPEAKER_01",
                "auto_name": None,
                "confidence": 0.0,
                "speaking_time_seconds": 60.0,
                "sample_file": "SPEAKER_01.wav",
            },
        ],
    }

    tmp = SPEAKER_REQUEST_FILE.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, SPEAKER_REQUEST_FILE)


def write_test_status(state: str) -> None:
    """Write a status.json with the given state."""
    data = {
        "version": 1,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "state": state,
        "detail": "2 speakers detected",
        "meeting": None,
        "protocol_path": None,
        "error": None,
        "pid": os.getpid(),
    }

    STATUS_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATUS_FILE.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, STATUS_FILE)


def read_speaker_response() -> dict | None:
    """Read the speaker_response.json written by the app."""
    if not SPEAKER_RESPONSE_FILE.exists():
        return None
    with open(SPEAKER_RESPONSE_FILE, encoding="utf-8") as f:
        return json.load(f)


def cleanup_test_files() -> None:
    """Remove all IPC test files."""
    import shutil

    for f in (SPEAKER_REQUEST_FILE, SPEAKER_RESPONSE_FILE, STATUS_FILE):
        try:
            f.unlink(missing_ok=True)
        except OSError:
            pass
    if SPEAKER_SAMPLES_DIR.exists():
        shutil.rmtree(SPEAKER_SAMPLES_DIR, ignore_errors=True)


# ── E2E Test ─────────────────────────────────────────────────────────────────


@pytest.mark.slow
def test_speaker_naming_e2e():
    """Full E2E: Python writes IPC, app opens window,
    AppleScript fills names, Python reads response.
    """
    if not APP_BINARY.exists():
        pytest.skip(f"App binary not found: {APP_BINARY}")

    app_proc = None
    try:
        # 1. Start the app
        app_proc = subprocess.Popen(
            [str(APP_BINARY)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(2)  # Wait for app startup

        # 2. Write speaker request + status
        write_test_speaker_request()
        write_test_status("waiting_for_speaker_names")
        time.sleep(3)  # Wait for StatusMonitor poll

        # 3. Verify the naming window opened
        assert window_exists("Name Speakers"), "Naming window did not open"

        # 4. Fill in names and click Confirm
        applescript_fill_names({"SPEAKER_00": "Roman", "SPEAKER_01": "Maria"})
        applescript_click_confirm()

        # 5. Wait for response and verify
        time.sleep(1)
        response = read_speaker_response()
        assert response is not None, "No speaker response file written"
        assert response["speakers"]["SPEAKER_00"] == "Roman"
        assert response["speakers"]["SPEAKER_01"] == "Maria"

    finally:
        # 6. Cleanup
        cleanup_test_files()
        if app_proc is not None:
            app_proc.terminate()
            app_proc.wait(timeout=5)
