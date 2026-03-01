"""Tests for dual-source transcription (app + mic separate tracks)."""

from pathlib import Path
from unittest.mock import MagicMock, patch

from meeting_transcriber.audio.mac import RecordingResult
from meeting_transcriber.diarize import TimestampedSegment
from meeting_transcriber.transcription.mac import _merge_segments


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

    def test_mic_delay(self):
        r = RecordingResult(
            mix=Path("/tmp/mix.wav"),
            app=Path("/tmp/app.wav"),
            mic=Path("/tmp/mic.wav"),
            mic_delay=0.123,
        )
        assert r.mic_delay == 0.123

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
