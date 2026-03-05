"""Atomic JSON status emitter for the menu bar app."""

import json
import os
import tempfile
import time
from pathlib import Path

from meeting_transcriber.config import STATUS_DIR, STATUS_FILE

_enabled = False


def enable():
    """Enable status emission and create the status directory."""
    global _enabled
    STATUS_DIR.mkdir(parents=True, exist_ok=True)
    _enabled = True
    emit("idle")


def disable():
    """Disable status emission and set state to idle."""
    global _enabled
    if _enabled:
        emit("idle")
    _enabled = False


def emit(
    state, *, detail="", meeting=None, protocol_path=None, error=None, audio_path=None
):
    """Write status JSON atomically (write tmp + rename).

    Args:
        state: One of idle, watching, recording, transcribing,
               generating_protocol, protocol_ready, recording_done, error.
        detail: Human-readable detail string.
        meeting: Dict with app, title, pid keys (or None).
        protocol_path: Path to generated protocol file (or None).
        error: Error message string (or None).
        audio_path: Path to recorded audio file (or None).
    """
    if not _enabled:
        return

    data = {
        "version": 1,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "state": state,
        "detail": detail,
        "meeting": meeting,
        "protocol_path": str(protocol_path) if protocol_path else None,
        "error": error,
        "audio_path": audio_path,
        "pid": os.getpid(),
    }

    tmp_path = None
    try:
        fd, tmp_path = tempfile.mkstemp(
            dir=STATUS_DIR, prefix=".status_", suffix=".tmp"
        )
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, STATUS_FILE)
    except OSError:
        # Best-effort: don't crash the pipeline over status updates
        if tmp_path:
            try:
                Path(tmp_path).unlink(missing_ok=True)
            except Exception:
                pass
