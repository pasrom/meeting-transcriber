"""Tests for mute detection (MuteTracker, MuteTransition, _apply_mute_mask)."""

import wave
from pathlib import Path
from unittest.mock import patch

import numpy as np

from meeting_transcriber.watch.mute_detector import (
    _MUTE_LABELS,
    MuteTracker,
    MuteTransition,
)


class TestMuteTransition:
    def test_fields(self):
        t = MuteTransition(timestamp=1.5, is_muted=True)
        assert t.timestamp == 1.5
        assert t.is_muted is True

    def test_unmuted(self):
        t = MuteTransition(timestamp=2.0, is_muted=False)
        assert t.is_muted is False


class TestMuteLabels:
    def test_english_labels(self):
        assert "mute" in _MUTE_LABELS
        assert "unmute" in _MUTE_LABELS

    def test_german_labels(self):
        assert "stummschalten" in _MUTE_LABELS
        assert "stummschaltung aufheben" in _MUTE_LABELS

    def test_all_lowercase(self):
        for label in _MUTE_LABELS:
            assert label == label.lower()


class TestMuteTrackerGracefulDegradation:
    @patch(
        "meeting_transcriber.watch.mute_detector._is_accessibility_trusted",
        return_value=False,
    )
    def test_ax_unavailable_empty_timeline(self, mock_trusted):
        """When AX is not trusted, tracker starts but records nothing."""
        tracker = MuteTracker(teams_pid=12345)
        tracker.start()
        assert not tracker.is_active
        tracker.stop()
        assert tracker.timeline == []

    @patch(
        "meeting_transcriber.watch.mute_detector._is_accessibility_trusted",
        return_value=False,
    )
    def test_no_crash_on_permission_denied(self, mock_trusted):
        """Tracker doesn't crash when permission is denied."""
        tracker = MuteTracker(teams_pid=99999)
        tracker.start()
        # Should complete without exception
        tracker.stop()
        assert isinstance(tracker.timeline, list)

    def test_stop_without_start(self):
        """Calling stop() without start() doesn't crash."""
        tracker = MuteTracker(teams_pid=12345)
        tracker.stop()
        assert tracker.timeline == []


def _write_wav(path: Path, samples: np.ndarray, rate: int = 16000) -> None:
    """Write float32 mono samples to a 16-bit WAV file."""
    audio_int16 = (np.clip(samples, -1.0, 1.0) * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(audio_int16.tobytes())


class TestApplyMuteMask:
    def test_empty_timeline_passthrough(self, tmp_path):
        """Empty mute timeline returns original path unchanged."""
        from meeting_transcriber.transcription.mac import _apply_mute_mask

        rate = 16000
        mic = 0.5 * np.ones(rate, dtype=np.float32)
        mic_path = tmp_path / "mic.wav"
        _write_wav(mic_path, mic, rate)

        result = _apply_mute_mask(mic_path, [])
        assert result == mic_path

    def test_muted_region_zeroed(self, tmp_path):
        """Muted region is zeroed out in the output."""
        from meeting_transcriber.transcription.mac import _apply_mute_mask

        rate = 16000
        duration = 2.0
        n = int(rate * duration)
        mic = 0.5 * np.ones(n, dtype=np.float32)
        mic_path = tmp_path / "mic.wav"
        _write_wav(mic_path, mic, rate)

        # Muted from t=0.5 to t=1.5 (recording_start=0)
        timeline = [
            MuteTransition(timestamp=0.5, is_muted=True),
            MuteTransition(timestamp=1.5, is_muted=False),
        ]

        result = _apply_mute_mask(mic_path, timeline, recording_start=0.0)

        with wave.open(str(result), "rb") as wf:
            raw = wf.readframes(wf.getnframes())
        clean = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0

        # Muted region (0.5s - 1.5s) should be zero
        muted_start = int(0.5 * rate)
        muted_end = int(1.5 * rate)
        muted_rms = np.sqrt(np.mean(clean[muted_start:muted_end] ** 2))
        assert muted_rms == 0.0, f"Muted region not zeroed: RMS={muted_rms}"

    def test_unmuted_region_preserved(self, tmp_path):
        """Unmuted regions are preserved."""
        from meeting_transcriber.transcription.mac import _apply_mute_mask

        rate = 16000
        duration = 2.0
        n = int(rate * duration)
        mic = 0.5 * np.ones(n, dtype=np.float32)
        mic_path = tmp_path / "mic.wav"
        _write_wav(mic_path, mic, rate)

        # Muted only from t=0.5 to t=1.0
        timeline = [
            MuteTransition(timestamp=0.5, is_muted=True),
            MuteTransition(timestamp=1.0, is_muted=False),
        ]

        result = _apply_mute_mask(mic_path, timeline, recording_start=0.0)

        with wave.open(str(result), "rb") as wf:
            raw = wf.readframes(wf.getnframes())
        clean = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0

        # Before mute (0-0.5s) and after mute (1.0-2.0s) should be preserved
        before_rms = np.sqrt(np.mean(clean[: int(0.5 * rate)] ** 2))
        after_rms = np.sqrt(np.mean(clean[int(1.0 * rate) :] ** 2))
        assert before_rms > 0.4, f"Before-mute region too quiet: RMS={before_rms}"
        assert after_rms > 0.4, f"After-mute region too quiet: RMS={after_rms}"

    def test_muted_until_end(self, tmp_path):
        """Mute that extends to end of recording zeros everything after."""
        from meeting_transcriber.transcription.mac import _apply_mute_mask

        rate = 16000
        n = rate  # 1 second
        mic = 0.5 * np.ones(n, dtype=np.float32)
        mic_path = tmp_path / "mic.wav"
        _write_wav(mic_path, mic, rate)

        # Muted from t=0.5 with no unmute transition
        timeline = [MuteTransition(timestamp=0.5, is_muted=True)]

        result = _apply_mute_mask(mic_path, timeline, recording_start=0.0)

        with wave.open(str(result), "rb") as wf:
            raw = wf.readframes(wf.getnframes())
        clean = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0

        # Second half should be zeroed
        muted_rms = np.sqrt(np.mean(clean[int(0.5 * rate) :] ** 2))
        assert muted_rms == 0.0, f"Muted-to-end region not zeroed: RMS={muted_rms}"
