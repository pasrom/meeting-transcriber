"""E2E test for speaker naming IPC via the Swift menu bar app.

Launches the real .app bundle (like run_app.sh), writes IPC files,
drives the UI via AppleScript, and verifies the response.

Requires:
- Built release binary: app/MeetingTranscriber/.build/release/MeetingTranscriber
- Accessibility permission for Terminal.app
"""

import json
import os
import shutil
import subprocess
import time
import wave
from pathlib import Path

import numpy as np
import pytest

PROJECT = Path(__file__).resolve().parent.parent
SPM_DIR = PROJECT / "app" / "MeetingTranscriber"
BUILD_BINARY = SPM_DIR / ".build" / "release" / "MeetingTranscriber"
APP_BUNDLE = SPM_DIR / ".build" / "MeetingTranscriber.app"
INFO_PLIST = SPM_DIR / "Sources" / "Info.plist"

STATUS_DIR = Path.home() / ".meeting-transcriber"
SPEAKER_REQUEST_FILE = STATUS_DIR / "speaker_request.json"
SPEAKER_RESPONSE_FILE = STATUS_DIR / "speaker_response.json"
SPEAKER_SAMPLES_DIR = STATUS_DIR / "speaker_samples"
STATUS_FILE = STATUS_DIR / "status.json"

PROCESS_NAME = "MeetingTranscriber"


# ── App lifecycle ────────────────────────────────────────────────────────────


def assemble_app_bundle() -> None:
    """Build the .app bundle from the release binary + Info.plist."""
    macos_dir = APP_BUNDLE / "Contents" / "MacOS"
    macos_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(INFO_PLIST, APP_BUNDLE / "Contents" / "Info.plist")
    shutil.copy2(BUILD_BINARY, macos_dir / "MeetingTranscriber")


def launch_app() -> None:
    """Launch the .app bundle via `open` (like run_app.sh)."""
    env = os.environ.copy()
    env["TRANSCRIBER_ROOT"] = str(PROJECT)
    subprocess.Popen(
        ["open", str(APP_BUNDLE)],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def quit_app() -> None:
    """Quit the app gracefully via AppleScript."""
    subprocess.run(
        [
            "osascript",
            "-e",
            f'tell application "{PROCESS_NAME}" to quit',
        ],
        capture_output=True,
        timeout=5,
    )
    time.sleep(1)
    # Force-kill if still running
    subprocess.run(
        ["pkill", "-f", "MeetingTranscriber.app"],
        capture_output=True,
    )


def app_is_running() -> bool:
    """Check if the app process exists."""
    result = subprocess.run(
        ["pgrep", "-f", "MeetingTranscriber.app"],
        capture_output=True,
    )
    return result.returncode == 0


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
    """Check if a window with the given title exists."""
    return (
        applescript(
            'tell application "System Events"\n'
            f'    tell process "{PROCESS_NAME}"\n'
            f'        return exists window "{title}"\n'
            "    end tell\n"
            "end tell"
        )
        == "true"
    )


def applescript_fill_names(names: dict[str, str]) -> None:
    """Fill in speaker names via AppleScript.

    Text fields are inside GroupBox groups within the content group.
    """
    for i, (_label, name) in enumerate(names.items()):
        grp = i + 1
        applescript(
            'tell application "System Events"\n'
            f'    tell process "{PROCESS_NAME}"\n'
            '        tell group 1 of window "Name Speakers"\n'
            f"            set value of text field 1"
            f' of group {grp} to "{name}"\n'
            "        end tell\n"
            "    end tell\n"
            "end tell"
        )


def applescript_click_confirm() -> None:
    """Click the Confirm button (button 2 in content group)."""
    applescript(
        'tell application "System Events"\n'
        f'    tell process "{PROCESS_NAME}"\n'
        '        tell group 1 of window "Name Speakers"\n'
        "            click button 2\n"
        "        end tell\n"
        "    end tell\n"
        "end tell"
    )


# ── IPC test data ────────────────────────────────────────────────────────────


def write_test_speaker_request() -> None:
    """Write speaker_request.json with 2 test speakers + WAV samples."""
    STATUS_DIR.mkdir(parents=True, exist_ok=True)
    SPEAKER_SAMPLES_DIR.mkdir(parents=True, exist_ok=True)

    for label in ("SPEAKER_00", "SPEAKER_01"):
        wav_path = SPEAKER_SAMPLES_DIR / f"{label}.wav"
        silence = np.zeros(16000, dtype=np.int16)
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
    """Write status.json with the given state (atomic rename)."""
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


def cleanup_ipc_files() -> None:
    """Remove all IPC test files."""
    for f in (SPEAKER_REQUEST_FILE, SPEAKER_RESPONSE_FILE, STATUS_FILE):
        try:
            f.unlink(missing_ok=True)
        except OSError:
            pass
    if SPEAKER_SAMPLES_DIR.exists():
        shutil.rmtree(SPEAKER_SAMPLES_DIR, ignore_errors=True)


# ── E2E Tests ────────────────────────────────────────────────────────────


@pytest.mark.slow
def test_transcription_with_diarization():
    """E2E: pre-recorded two-speaker WAV through Whisper + pyannote diarization."""
    fixture = PROJECT / "tests" / "fixtures" / "two_speakers_de.wav"
    if not fixture.exists():
        pytest.skip(
            f"Fixture not found: {fixture} — run scripts/generate_test_audio.sh"
        )
    if not os.environ.get("HF_TOKEN"):
        pytest.skip("HF_TOKEN not set (required for pyannote diarization)")

    from meeting_transcriber.transcription.mac import transcribe

    transcript = transcribe(
        fixture,
        model="base",
        language="de",
        diarize_enabled=True,
        num_speakers=2,
        meeting_title="Test Meeting",
    )

    # Diarization labels present
    assert "[SPEAKER_" in transcript, f"No speaker labels in transcript:\n{transcript}"

    # German keywords from the spoken text recognised
    keywords = ["meeting", "projekt", "entwicklung", "status"]
    found = [kw for kw in keywords if kw in transcript.lower()]
    assert len(found) >= 2, (
        f"Expected ≥2 keywords from {keywords}, found {found}.\n"
        f"Transcript:\n{transcript}"
    )


@pytest.mark.slow
def test_speaker_naming_e2e():
    """Full E2E: .app bundle launched via open, IPC triggers
    naming window, AppleScript fills names, response verified.
    """
    if not BUILD_BINARY.exists():
        pytest.skip(f"Release binary not found: {BUILD_BINARY}")

    try:
        # 1. Assemble .app bundle and launch (like run_app.sh)
        assemble_app_bundle()
        launch_app()
        time.sleep(3)
        assert app_is_running(), "App failed to start"

        # 2. Write speaker request + status
        write_test_speaker_request()
        write_test_status("waiting_for_speaker_names")
        time.sleep(4)  # StatusMonitor poll interval

        # 3. Verify the naming window opened
        assert window_exists("Name Speakers"), "Naming window did not open"

        # 4. Fill in names and click Confirm
        applescript_fill_names(
            {
                "SPEAKER_00": "Roman",
                "SPEAKER_01": "Maria",
            }
        )
        applescript_click_confirm()

        # 5. Wait for response and verify
        time.sleep(1)
        response = read_speaker_response()
        assert response is not None, "No speaker response file written"
        assert response["speakers"]["SPEAKER_00"] == "Roman"
        assert response["speakers"]["SPEAKER_01"] == "Maria"

    finally:
        # 6. Cleanup
        quit_app()
        cleanup_ipc_files()
