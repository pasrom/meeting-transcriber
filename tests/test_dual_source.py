"""Tests for dual-source transcription (app + mic separate tracks)."""

import wave
from pathlib import Path
from unittest.mock import MagicMock, patch

import numpy as np

from meeting_transcriber.audio.mac import RecordingResult
from meeting_transcriber.diarize import TimestampedSegment
from meeting_transcriber.transcription.mac import _merge_segments, _suppress_echo


class TestRecordingResult:
    def test_all_fields(self):
        r = RecordingResult(
            mix=Path("/tmp/mix.wav"),
            app=Path("/tmp/app.wav"),
            mic=Path("/tmp/mic.wav"),
        )
        assert r.mix == Path("/tmp/mix.wav")
        assert r.app == Path("/tmp/app.wav")
        assert r.mic == Path("/tmp/mic.wav")

    def test_defaults_none(self):
        r = RecordingResult(mix=Path("/tmp/mix.wav"))
        assert r.app is None
        assert r.mic is None
        assert r.mic_delay == 0.0
        assert r.aec_applied is False

    def test_mute_timeline_default_empty(self):
        r = RecordingResult(mix=Path("/tmp/mix.wav"))
        assert r.mute_timeline == []

    def test_mic_delay(self):
        r = RecordingResult(
            mix=Path("/tmp/mix.wav"),
            app=Path("/tmp/app.wav"),
            mic=Path("/tmp/mic.wav"),
            mic_delay=0.123,
        )
        assert r.mic_delay == 0.123

    def test_aec_applied(self):
        r = RecordingResult(
            mix=Path("/tmp/mix.wav"),
            app=Path("/tmp/app.wav"),
            mic=Path("/tmp/mic.wav"),
            aec_applied=True,
        )
        assert r.aec_applied is True

    def test_partial(self):
        r = RecordingResult(mix=Path("/tmp/mix.wav"), app=Path("/tmp/app.wav"))
        assert r.app is not None
        assert r.mic is None


class TestMergeSegments:
    def test_interleaving(self):
        app = [
            TimestampedSegment(start=0.0, end=1.0, text="hello", speaker="Remote"),
            TimestampedSegment(start=3.0, end=4.0, text="world", speaker="Remote"),
        ]
        mic = [
            TimestampedSegment(start=1.5, end=2.5, text="yes", speaker="Me"),
            TimestampedSegment(start=5.0, end=6.0, text="ok", speaker="Me"),
        ]
        merged = _merge_segments(app, mic)
        assert len(merged) == 4
        assert [s.text for s in merged] == ["hello", "yes", "world", "ok"]

    def test_empty_app(self):
        mic = [TimestampedSegment(start=1.0, end=2.0, text="only mic", speaker="Me")]
        merged = _merge_segments([], mic)
        assert len(merged) == 1
        assert merged[0].text == "only mic"

    def test_empty_mic(self):
        app = [
            TimestampedSegment(start=0.0, end=1.0, text="only app", speaker="Remote")
        ]
        merged = _merge_segments(app, [])
        assert len(merged) == 1
        assert merged[0].text == "only app"

    def test_both_empty(self):
        merged = _merge_segments([], [])
        assert merged == []

    def test_same_timestamp(self):
        app = [
            TimestampedSegment(start=1.0, end=2.0, text="app", speaker="Remote"),
        ]
        mic = [
            TimestampedSegment(start=1.0, end=2.0, text="mic", speaker="Me"),
        ]
        merged = _merge_segments(app, mic)
        assert len(merged) == 2

    def test_does_not_mutate_originals(self):
        app = [TimestampedSegment(start=0.0, end=1.0, text="a", speaker="Remote")]
        mic = [TimestampedSegment(start=0.5, end=1.5, text="b", speaker="Me")]
        _merge_segments(app, mic)
        assert len(app) == 1
        assert len(mic) == 1


class TestDualSourceDispatch:
    @patch("meeting_transcriber.transcription.mac._transcribe_dual_source")
    @patch("meeting_transcriber.transcription.mac._load_whisper_model")
    def test_dual_source_called_when_both_tracks(self, mock_load, mock_dual):
        """transcribe() dispatches to dual-source when both tracks provided."""
        mock_load.return_value = MagicMock()
        mock_dual.return_value = "[Me] hello [Remote] world"

        from meeting_transcriber.transcription.mac import transcribe

        result = transcribe(
            Path("/tmp/mix.wav"),
            app_audio=Path("/tmp/app.wav"),
            mic_audio=Path("/tmp/mic.wav"),
            mic_label="Me",
        )
        mock_dual.assert_called_once()
        assert result == "[Me] hello [Remote] world"

    @patch("meeting_transcriber.transcription.mac._transcribe_dual_source")
    @patch("meeting_transcriber.transcription.mac._load_whisper_model")
    def test_mic_delay_passed_through(self, mock_load, mock_dual):
        """transcribe() passes mic_delay to dual-source."""
        mock_load.return_value = MagicMock()
        mock_dual.return_value = "[Me] test"

        from meeting_transcriber.transcription.mac import transcribe

        transcribe(
            Path("/tmp/mix.wav"),
            app_audio=Path("/tmp/app.wav"),
            mic_audio=Path("/tmp/mic.wav"),
            mic_delay=0.5,
        )
        _, kwargs = mock_dual.call_args
        assert kwargs["mic_delay"] == 0.5

    @patch("meeting_transcriber.transcription.mac._transcribe_dual_source")
    @patch("meeting_transcriber.transcription.mac._load_whisper_model")
    def test_mute_timeline_passed_through(self, mock_load, mock_dual):
        """transcribe() passes mute_timeline to dual-source."""
        mock_load.return_value = MagicMock()
        mock_dual.return_value = "[Me] test"

        from meeting_transcriber.transcription.mac import transcribe

        timeline = [{"timestamp": 1.0, "is_muted": True}]
        transcribe(
            Path("/tmp/mix.wav"),
            app_audio=Path("/tmp/app.wav"),
            mic_audio=Path("/tmp/mic.wav"),
            mute_timeline=timeline,
        )
        _, kwargs = mock_dual.call_args
        assert kwargs["mute_timeline"] is timeline

    @patch("meeting_transcriber.transcription.mac._load_whisper_model")
    def test_single_source_when_no_tracks(self, mock_load):
        """transcribe() uses single-source when no separate tracks."""
        mock_model = MagicMock()
        mock_load.return_value = mock_model

        # Mock whisper transcribe to return segments
        seg = MagicMock()
        seg.text = "hello world"
        seg.t0 = 0
        seg.t1 = 100
        mock_model.transcribe.return_value = [seg]

        from meeting_transcriber.transcription.mac import transcribe

        with patch(
            "meeting_transcriber.transcription.mac._ensure_16khz",
            return_value=Path("/tmp/mix.wav"),
        ):
            result = transcribe(Path("/tmp/mix.wav"))

        assert "hello world" in result
        mock_model.transcribe.assert_called_once()

    @patch("meeting_transcriber.transcription.mac._load_whisper_model")
    def test_single_source_when_only_app(self, mock_load):
        """transcribe() uses single-source when only app track provided."""
        mock_model = MagicMock()
        mock_load.return_value = mock_model

        seg = MagicMock()
        seg.text = "app only"
        seg.t0 = 0
        seg.t1 = 100
        mock_model.transcribe.return_value = [seg]

        from meeting_transcriber.transcription.mac import transcribe

        with patch(
            "meeting_transcriber.transcription.mac._ensure_16khz",
            return_value=Path("/tmp/mix.wav"),
        ):
            result = transcribe(
                Path("/tmp/mix.wav"), app_audio=Path("/tmp/app.wav"), mic_audio=None
            )

        assert "app only" in result


def _write_wav(path: Path, samples: np.ndarray, rate: int = 16000) -> None:
    """Write float32 mono samples to a 16-bit WAV file."""
    audio_int16 = (np.clip(samples, -1.0, 1.0) * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(audio_int16.tobytes())


class TestEchoSuppression:
    @patch("meeting_transcriber.transcription.mac._suppress_echo")
    @patch("meeting_transcriber.transcription.mac._transcribe_segments")
    @patch("meeting_transcriber.transcription.mac._load_whisper_model")
    def test_suppress_echo_always_called(self, mock_load, mock_segments, mock_suppress):
        """_suppress_echo is always called in dual-source mode."""
        mock_load.return_value = MagicMock()
        mock_segments.return_value = []
        mock_suppress.return_value = Path("/tmp/mic_clean.wav")

        from meeting_transcriber.transcription.mac import _transcribe_dual_source

        _transcribe_dual_source(
            mock_load.return_value,
            Path("/tmp/app.wav"),
            Path("/tmp/mic.wav"),
        )

        mock_suppress.assert_called_once()

    def test_attenuates_active_regions(self, tmp_path):
        """Echo regions (where app is loud) are attenuated in mic output."""
        rate = 16000
        duration = 1.0  # 1 second
        n = int(rate * duration)
        t = np.linspace(0, duration, n, dtype=np.float32)

        # App: sine tone in first 0.5s, silence in second 0.5s
        app = np.zeros(n, dtype=np.float32)
        app[: n // 2] = 0.5 * np.sin(2 * np.pi * 440 * t[: n // 2])

        # Mic: sine tone in both halves (echo in first, real speech in second)
        mic = 0.3 * np.sin(2 * np.pi * 440 * t)

        app_path = tmp_path / "app.wav"
        mic_path = tmp_path / "mic.wav"
        _write_wav(app_path, app, rate)
        _write_wav(mic_path, mic, rate)

        clean_path = _suppress_echo(app_path, mic_path)

        # Read back the cleaned mic
        with wave.open(str(clean_path), "rb") as wf:
            raw = wf.readframes(wf.getnframes())
        clean = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0

        # Echo region (first half) should be heavily attenuated
        echo_rms = np.sqrt(np.mean(clean[: n // 2] ** 2))
        # Speech region (second half, minus margin) should be preserved
        margin = int(0.25 * rate)  # skip margin area
        speech_rms = np.sqrt(np.mean(clean[n // 2 + margin :] ** 2))

        assert echo_rms < 0.01, f"Echo region not attenuated enough: RMS={echo_rms}"
        assert speech_rms > 0.1, f"Speech region too quiet: RMS={speech_rms}"

    def test_silent_app_preserves_mic(self, tmp_path):
        """When app track is silent, mic track is unchanged."""
        rate = 16000
        n = int(rate * 0.5)
        t = np.linspace(0, 0.5, n, dtype=np.float32)

        app = np.zeros(n, dtype=np.float32)
        mic = 0.3 * np.sin(2 * np.pi * 440 * t)

        app_path = tmp_path / "app.wav"
        mic_path = tmp_path / "mic.wav"
        _write_wav(app_path, app, rate)
        _write_wav(mic_path, mic, rate)

        clean_path = _suppress_echo(app_path, mic_path)

        with wave.open(str(clean_path), "rb") as wf:
            raw = wf.readframes(wf.getnframes())
        clean = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0

        original_rms = np.sqrt(np.mean(mic**2))
        clean_rms = np.sqrt(np.mean(clean**2))

        # Should be essentially unchanged (small rounding from int16 conversion)
        assert abs(original_rms - clean_rms) < 0.01

    def test_returns_clean_path(self, tmp_path):
        """Output file has _clean suffix."""
        rate = 16000
        n = rate  # 1 second

        app_path = tmp_path / "app.wav"
        mic_path = tmp_path / "mic.wav"
        _write_wav(app_path, np.zeros(n, dtype=np.float32), rate)
        _write_wav(mic_path, np.zeros(n, dtype=np.float32), rate)

        result = _suppress_echo(app_path, mic_path)

        assert result.stem == "mic_clean"
        assert result.suffix == ".wav"
        assert result.exists()
