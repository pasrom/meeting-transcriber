"""Unit tests for speaker IPC functions in diarize.py."""

import json
import threading
import time
import wave
from pathlib import Path

import numpy as np
import pytest

from meeting_transcriber.diarize import (
    cleanup_speaker_count_ipc,
    cleanup_speaker_ipc,
    extract_speaker_samples,
    poll_speaker_count_response,
    poll_speaker_response,
    write_speaker_count_request,
    write_speaker_request,
)

# ── Fixtures ─────────────────────────────────────────────────────────────────


@pytest.fixture()
def ipc_dir(tmp_path, monkeypatch):
    """Patch IPC file paths in config to use tmp_path."""
    import meeting_transcriber.config as cfg
    import meeting_transcriber.diarize as diarize_mod

    request = tmp_path / "speaker_request.json"
    response = tmp_path / "speaker_response.json"
    samples = tmp_path / "speaker_samples"

    monkeypatch.setattr(cfg, "SPEAKER_REQUEST_FILE", request)
    monkeypatch.setattr(cfg, "SPEAKER_RESPONSE_FILE", response)
    monkeypatch.setattr(cfg, "SPEAKER_SAMPLES_DIR", samples)
    # Default param is captured at def-time, so patch the function
    monkeypatch.setattr(diarize_mod, "load_speaker_db", lambda *_a, **_kw: {})

    return {"request": request, "response": response, "samples": samples}


@pytest.fixture()
def sample_wav(tmp_path):
    """Create a 3-second 16kHz mono WAV of silence."""
    path = tmp_path / "test_audio.wav"
    sr = 16000
    duration = 3
    n_frames = sr * duration
    silence = np.zeros(n_frames, dtype=np.int16)

    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.writeframes(silence.tobytes())

    return path


@pytest.fixture()
def sample_turns():
    """Two speaker turns spanning 0–3s."""
    return [(0.0, 1.5, "SPEAKER_00"), (1.5, 3.0, "SPEAKER_01")]


# ── extract_speaker_samples ──────────────────────────────────────────────────


def test_extract_speaker_samples_creates_wav_per_speaker(
    tmp_path, sample_wav, sample_turns
):
    output_dir = tmp_path / "samples"
    result = extract_speaker_samples(sample_wav, sample_turns, output_dir)

    assert set(result.keys()) == {"SPEAKER_00", "SPEAKER_01"}
    for label, filename in result.items():
        wav_path = output_dir / filename
        assert wav_path.exists()
        with wave.open(str(wav_path), "rb") as wf:
            assert wf.getnchannels() == 1
            assert wf.getframerate() == 16000
            assert wf.getnframes() > 0


def test_extract_speaker_samples_limits_duration(tmp_path):
    """A 30s turn with max_duration=5 should produce a WAV of ≤5s."""
    sr = 16000
    audio_path = tmp_path / "long.wav"
    silence = np.zeros(sr * 30, dtype=np.int16)  # 30s
    with wave.open(str(audio_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.writeframes(silence.tobytes())

    turns = [(0.0, 30.0, "SPEAKER_00")]
    output_dir = tmp_path / "samples"
    extract_speaker_samples(audio_path, turns, output_dir, max_duration=5.0)

    with wave.open(str(output_dir / "SPEAKER_00.wav"), "rb") as wf:
        duration = wf.getnframes() / wf.getframerate()
        assert duration <= 5.0


# ── write_speaker_request ────────────────────────────────────────────────────


def test_write_speaker_request_creates_valid_json(ipc_dir, sample_wav, sample_turns):
    mapping = {"SPEAKER_00": "Roman", "SPEAKER_01": "SPEAKER_01"}
    embeddings = {
        "SPEAKER_00": np.random.rand(192),
        "SPEAKER_01": np.random.rand(192),
    }
    speaking_times = {"SPEAKER_00": 45.0, "SPEAKER_01": 30.0}

    write_speaker_request(
        mapping, embeddings, speaking_times, sample_wav, sample_turns, "Test Meeting"
    )

    assert ipc_dir["request"].exists()
    data = json.loads(ipc_dir["request"].read_text())

    assert data["version"] == 1
    assert data["meeting_title"] == "Test Meeting"
    assert len(data["speakers"]) == 2

    # Verify sample files were created
    samples_dir = Path(data["audio_samples_dir"])
    for speaker in data["speakers"]:
        assert speaker["label"] in ("SPEAKER_00", "SPEAKER_01")
        assert speaker["sample_file"]
        assert (samples_dir / speaker["sample_file"]).exists()


def test_write_speaker_request_auto_name_null_when_unmatched(
    ipc_dir, sample_wav, sample_turns
):
    """SPEAKER_01 mapped to itself should have auto_name: null."""
    mapping = {"SPEAKER_00": "Roman", "SPEAKER_01": "SPEAKER_01"}
    embeddings = {
        "SPEAKER_00": np.random.rand(192),
        "SPEAKER_01": np.random.rand(192),
    }
    speaking_times = {"SPEAKER_00": 45.0, "SPEAKER_01": 30.0}

    write_speaker_request(
        mapping, embeddings, speaking_times, sample_wav, sample_turns, "Test"
    )

    data = json.loads(ipc_dir["request"].read_text())
    speakers_by_label = {s["label"]: s for s in data["speakers"]}
    assert speakers_by_label["SPEAKER_01"]["auto_name"] is None
    assert speakers_by_label["SPEAKER_00"]["auto_name"] == "Roman"


# ── poll_speaker_response ────────────────────────────────────────────────────


def test_poll_speaker_response_reads_mapping(ipc_dir):
    """Pre-written response file is read correctly."""
    response_data = {
        "version": 1,
        "speakers": {"SPEAKER_00": "Roman", "SPEAKER_01": "Maria"},
    }
    ipc_dir["response"].write_text(json.dumps(response_data))

    result = poll_speaker_response(timeout=1)
    assert result == {"SPEAKER_00": "Roman", "SPEAKER_01": "Maria"}


def test_poll_speaker_response_timeout_returns_none(ipc_dir):
    """No response file → returns None after timeout."""
    result = poll_speaker_response(timeout=0)
    assert result is None


def test_poll_speaker_response_waits_for_delayed_file(ipc_dir):
    """Response written after 1s via thread → poll finds it."""

    def write_delayed():
        time.sleep(1)
        response_data = {
            "version": 1,
            "speakers": {"SPEAKER_00": "Delayed"},
        }
        ipc_dir["response"].write_text(json.dumps(response_data))

    thread = threading.Thread(target=write_delayed)
    thread.start()

    result = poll_speaker_response(timeout=10)
    thread.join()

    assert result is not None
    assert result["SPEAKER_00"] == "Delayed"


# ── cleanup_speaker_ipc ─────────────────────────────────────────────────────


def test_cleanup_removes_all_files(ipc_dir):
    """Request + response + samples dir are removed."""
    ipc_dir["request"].write_text("{}")
    ipc_dir["response"].write_text("{}")
    ipc_dir["samples"].mkdir(parents=True, exist_ok=True)
    (ipc_dir["samples"] / "test.wav").write_bytes(b"fake")

    cleanup_speaker_ipc()

    assert not ipc_dir["request"].exists()
    assert not ipc_dir["response"].exists()
    assert not ipc_dir["samples"].exists()


def test_cleanup_no_error_when_missing(ipc_dir):
    """Cleanup with no existing files raises no error."""
    cleanup_speaker_ipc()  # Should not raise


# ── Full roundtrip ───────────────────────────────────────────────────────────


def test_ipc_roundtrip(ipc_dir, sample_wav, sample_turns):
    """write_request → thread writes response → poll → correct mapping."""
    mapping = {"SPEAKER_00": "Roman", "SPEAKER_01": "SPEAKER_01"}
    embeddings = {
        "SPEAKER_00": np.random.rand(192),
        "SPEAKER_01": np.random.rand(192),
    }
    speaking_times = {"SPEAKER_00": 45.0, "SPEAKER_01": 30.0}

    write_speaker_request(
        mapping, embeddings, speaking_times, sample_wav, sample_turns, "Roundtrip"
    )

    def write_response_delayed():
        time.sleep(1)
        response_data = {
            "version": 1,
            "speakers": {"SPEAKER_00": "Roman", "SPEAKER_01": "Maria"},
        }
        ipc_dir["response"].write_text(json.dumps(response_data))

    thread = threading.Thread(target=write_response_delayed)
    thread.start()

    result = poll_speaker_response(timeout=10)
    thread.join()

    assert result == {"SPEAKER_00": "Roman", "SPEAKER_01": "Maria"}


# ── Speaker Count IPC ────────────────────────────────────────────────────────


@pytest.fixture()
def count_ipc_dir(tmp_path, monkeypatch):
    """Patch speaker count IPC file paths to use tmp_path."""
    import meeting_transcriber.config as cfg

    request = tmp_path / "speaker_count_request.json"
    response = tmp_path / "speaker_count_response.json"

    monkeypatch.setattr(cfg, "SPEAKER_COUNT_REQUEST_FILE", request)
    monkeypatch.setattr(cfg, "SPEAKER_COUNT_RESPONSE_FILE", response)

    return {"request": request, "response": response}


def test_write_speaker_count_request_creates_valid_json(count_ipc_dir):
    write_speaker_count_request("Sprint Planning")

    assert count_ipc_dir["request"].exists()
    data = json.loads(count_ipc_dir["request"].read_text())

    assert data["version"] == 1
    assert data["meeting_title"] == "Sprint Planning"
    assert "timestamp" in data


def test_poll_speaker_count_response_reads_count(count_ipc_dir):
    """Pre-written response file is read correctly."""
    response_data = {"version": 1, "speaker_count": 5}
    count_ipc_dir["response"].write_text(json.dumps(response_data))

    result = poll_speaker_count_response(timeout=1)
    assert result == 5


def test_poll_speaker_count_response_auto_detect(count_ipc_dir):
    """speaker_count=0 means auto-detect."""
    response_data = {"version": 1, "speaker_count": 0}
    count_ipc_dir["response"].write_text(json.dumps(response_data))

    result = poll_speaker_count_response(timeout=1)
    assert result == 0


def test_poll_speaker_count_response_timeout_returns_none(count_ipc_dir):
    """No response file → returns None after timeout."""
    result = poll_speaker_count_response(timeout=0)
    assert result is None


def test_poll_speaker_count_response_waits_for_delayed_file(count_ipc_dir):
    """Response written after 1s via thread → poll finds it."""

    def write_delayed():
        time.sleep(1)
        response_data = {"version": 1, "speaker_count": 3}
        count_ipc_dir["response"].write_text(json.dumps(response_data))

    thread = threading.Thread(target=write_delayed)
    thread.start()

    result = poll_speaker_count_response(timeout=10)
    thread.join()

    assert result == 3


def test_cleanup_speaker_count_ipc_removes_files(count_ipc_dir):
    """Request + response files are removed."""
    count_ipc_dir["request"].write_text("{}")
    count_ipc_dir["response"].write_text("{}")

    cleanup_speaker_count_ipc()

    assert not count_ipc_dir["request"].exists()
    assert not count_ipc_dir["response"].exists()


def test_cleanup_speaker_count_ipc_no_error_when_missing(count_ipc_dir):
    """Cleanup with no existing files raises no error."""
    cleanup_speaker_count_ipc()  # Should not raise
