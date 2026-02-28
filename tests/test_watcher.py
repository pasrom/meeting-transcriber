"""Unit tests for watch-mode watcher (max duration, thread safety)."""

import time
from unittest.mock import Mock

from meeting_transcriber.config import MAX_RECORDING_SECONDS
from meeting_transcriber.watch.watcher import MeetingWatcher


def _make_watcher(**kwargs) -> MeetingWatcher:
    """Create a MeetingWatcher with minimal defaults."""
    defaults = {
        "patterns": [],
        "poll_interval": 0.01,  # fast for tests
        "end_grace": 0.05,
        "confirmation_count": 1,
    }
    defaults.update(kwargs)
    return MeetingWatcher(**defaults)


class TestWaitForMeetingEnd:
    def test_grace_period_expired(self):
        watcher = _make_watcher(end_grace=0.05, poll_interval=0.01)
        meeting = Mock()

        # Meeting window disappears immediately
        watcher.detector = Mock()
        watcher.detector.is_meeting_active = Mock(return_value=False)

        start = time.monotonic()
        watcher._wait_for_meeting_end(meeting, start_time=start)
        # Should return after grace period
        elapsed = time.monotonic() - start
        assert elapsed < 2.0  # should be ~0.05s, generous bound

    def test_max_duration_enforced(self):
        watcher = _make_watcher(poll_interval=0.01)
        meeting = Mock()

        # Meeting stays active forever
        watcher.detector = Mock()
        watcher.detector.is_meeting_active = Mock(return_value=True)

        # Pretend we started MAX_RECORDING_SECONDS + 1 ago
        fake_start = time.monotonic() - MAX_RECORDING_SECONDS - 1

        start = time.monotonic()
        watcher._wait_for_meeting_end(meeting, start_time=fake_start)
        elapsed = time.monotonic() - start
        # Should return almost immediately due to max duration
        assert elapsed < 2.0

    def test_window_reappears_cancels_grace(self):
        watcher = _make_watcher(end_grace=10.0, poll_interval=0.01)
        meeting = Mock()

        call_count = 0

        def _is_active(m):
            nonlocal call_count
            call_count += 1
            if call_count <= 2:
                return False  # disappears briefly
            if call_count <= 4:
                return True  # reappears
            return False  # disappears again

        watcher.detector = Mock()
        watcher.detector.is_meeting_active = Mock(side_effect=_is_active)
        # Override grace to something short so test finishes
        watcher.end_grace = 0.05

        start = time.monotonic()
        watcher._wait_for_meeting_end(meeting, start_time=start)
        elapsed = time.monotonic() - start
        assert elapsed < 5.0
        assert call_count >= 4  # went through disappear → reappear → disappear


class TestHandleMeetingThreadSafety:
    def test_stop_event_set_on_exception(self):
        """stop_event.set() must be called even if _wait_for_meeting_end raises."""
        watcher = _make_watcher()
        meeting = Mock()
        meeting.window_title = "Test Meeting"
        meeting.window_pid = 1234
        meeting.pattern = Mock()
        meeting.pattern.app_name = "Test"

        stop_events = []

        def _fake_record(audio_path, app_pid, stop_event):
            stop_events.append(stop_event)
            stop_event.wait(timeout=5)

        watcher._record = _fake_record
        watcher._wait_for_meeting_end = Mock(side_effect=RuntimeError("test error"))

        try:
            watcher._handle_meeting(meeting)
        except RuntimeError:
            pass

        # The stop_event should have been set in the finally block
        assert len(stop_events) == 1
        assert stop_events[0].is_set()


class TestMaxRecordingConfig:
    def test_max_recording_is_4_hours(self):
        assert MAX_RECORDING_SECONDS == 14400

    def test_max_recording_is_positive(self):
        assert MAX_RECORDING_SECONDS > 0
