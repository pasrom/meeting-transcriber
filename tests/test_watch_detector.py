"""Unit tests for meeting detection via window patterns."""

from unittest.mock import patch

from meeting_transcriber.watch.detector import MeetingDetector
from meeting_transcriber.watch.patterns import (
    TEAMS_PATTERN,
    WEBEX_PATTERN,
    ZOOM_PATTERN,
    AppMeetingPattern,
)


def _make_window(
    owner: str,
    name: str,
    pid: int = 1234,
    width: float = 800,
    height: float = 600,
) -> dict:
    """Create a fake CGWindowListCopyWindowInfo entry."""
    return {
        "kCGWindowOwnerName": owner,
        "kCGWindowName": name,
        "kCGWindowOwnerPID": pid,
        "kCGWindowBounds": {"Width": width, "Height": height},
    }


MOCK_PATH = "meeting_transcriber.watch.detector.MeetingDetector._get_windows"


class TestAppMeetingPattern:
    def test_teams_pattern_has_required_fields(self):
        assert TEAMS_PATTERN.app_name == "Microsoft Teams"
        assert len(TEAMS_PATTERN.owner_names) > 0
        assert len(TEAMS_PATTERN.meeting_patterns) > 0

    def test_zoom_pattern_has_required_fields(self):
        assert ZOOM_PATTERN.app_name == "Zoom"
        assert len(ZOOM_PATTERN.owner_names) > 0

    def test_webex_pattern_has_required_fields(self):
        assert WEBEX_PATTERN.app_name == "Webex"
        assert len(WEBEX_PATTERN.owner_names) > 0


class TestMeetingDetector:
    def test_no_windows_returns_none(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=1)
        with patch(MOCK_PATH, return_value=[]):
            assert detector.check_once() is None

    def test_detects_teams_meeting_after_confirmation(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=2)
        windows = [
            _make_window("Microsoft Teams", "Sprint Review | Microsoft Teams"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            # First check: not yet confirmed
            result = detector.check_once()
            assert result is None

            # Second check: confirmed
            result = detector.check_once()
            assert result is not None
            assert result.pattern.app_name == "Microsoft Teams"
            assert "Sprint Review" in result.window_title

    def test_detects_teams_meeting_with_confirmation_1(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=1)
        windows = [
            _make_window("Microsoft Teams", "Sprint Review | Microsoft Teams"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            result = detector.check_once()
            assert result is not None
            assert result.window_pid == 1234

    def test_ignores_idle_teams_window(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=1)
        windows = [
            _make_window("Microsoft Teams", "Microsoft Teams"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            assert detector.check_once() is None

    def test_ignores_chat_window(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=1)
        windows = [
            _make_window("Microsoft Teams", "Chat | John Doe"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            assert detector.check_once() is None

    def test_ignores_small_windows(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=1)
        windows = [
            _make_window(
                "Microsoft Teams",
                "Sprint Review | Microsoft Teams",
                width=50,
                height=50,
            ),
        ]
        with patch(MOCK_PATH, return_value=windows):
            assert detector.check_once() is None

    def test_ignores_empty_title(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=1)
        windows = [
            _make_window("Microsoft Teams", ""),
        ]
        with patch(MOCK_PATH, return_value=windows):
            assert detector.check_once() is None

    def test_ignores_wrong_owner(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=1)
        windows = [
            _make_window("Firefox", "Sprint Review | Microsoft Teams"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            assert detector.check_once() is None

    def test_resets_counter_when_window_disappears(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=3)
        meeting_windows = [
            _make_window("Microsoft Teams", "Sprint Review | Microsoft Teams"),
        ]
        with patch(MOCK_PATH, return_value=meeting_windows):
            detector.check_once()  # count=1

        # Window disappears
        with patch(MOCK_PATH, return_value=[]):
            detector.check_once()  # count reset to 0

        # Window reappears — needs full confirmation_count again
        with patch(MOCK_PATH, return_value=meeting_windows):
            assert detector.check_once() is None  # count=1
            assert detector.check_once() is None  # count=2
            result = detector.check_once()  # count=3
            assert result is not None

    def test_detects_zoom_meeting(self):
        detector = MeetingDetector([ZOOM_PATTERN], confirmation_count=1)
        windows = [
            _make_window("zoom.us", "Zoom Meeting"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            result = detector.check_once()
            assert result is not None
            assert result.pattern.app_name == "Zoom"

    def test_detects_zoom_named_meeting(self):
        detector = MeetingDetector([ZOOM_PATTERN], confirmation_count=1)
        windows = [
            _make_window("zoom.us", "Sprint Planning - Zoom"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            result = detector.check_once()
            assert result is not None

    def test_ignores_zoom_idle(self):
        detector = MeetingDetector([ZOOM_PATTERN], confirmation_count=1)
        windows = [
            _make_window("zoom.us", "Zoom Workplace"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            assert detector.check_once() is None

    def test_detects_webex_meeting(self):
        detector = MeetingDetector([WEBEX_PATTERN], confirmation_count=1)
        windows = [
            _make_window("Webex", "Team Sync - Webex"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            result = detector.check_once()
            assert result is not None
            assert result.pattern.app_name == "Webex"

    def test_multiple_patterns(self):
        detector = MeetingDetector([TEAMS_PATTERN, ZOOM_PATTERN], confirmation_count=1)
        windows = [
            _make_window("Microsoft Teams", "Microsoft Teams"),  # idle
            _make_window("zoom.us", "Zoom Meeting"),  # active
        ]
        with patch(MOCK_PATH, return_value=windows):
            result = detector.check_once()
            assert result is not None
            assert result.pattern.app_name == "Zoom"

    def test_is_meeting_active_true(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=1)
        windows = [
            _make_window("Microsoft Teams", "Sprint Review | Microsoft Teams"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            meeting = detector.check_once()

        with patch(MOCK_PATH, return_value=windows):
            assert detector.is_meeting_active(meeting) is True

    def test_is_meeting_active_false(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=1)
        windows = [
            _make_window("Microsoft Teams", "Sprint Review | Microsoft Teams"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            meeting = detector.check_once()

        # Meeting window gone, only idle window
        idle_windows = [
            _make_window("Microsoft Teams", "Microsoft Teams"),
        ]
        with patch(MOCK_PATH, return_value=idle_windows):
            assert detector.is_meeting_active(meeting) is False

    def test_reset_clears_counters(self):
        detector = MeetingDetector([TEAMS_PATTERN], confirmation_count=2)
        windows = [
            _make_window("Microsoft Teams", "Sprint Review | Microsoft Teams"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            detector.check_once()  # count=1

        detector.reset()

        with patch(MOCK_PATH, return_value=windows):
            # After reset, needs full confirmation again
            assert detector.check_once() is None  # count=1

    def test_custom_pattern(self):
        custom = AppMeetingPattern(
            app_name="Custom App",
            owner_names=["CustomApp"],
            meeting_patterns=[r"^Meeting:.*"],
            idle_patterns=[r"^Custom App$"],
        )
        detector = MeetingDetector([custom], confirmation_count=1)
        windows = [
            _make_window("CustomApp", "Meeting: Sprint"),
        ]
        with patch(MOCK_PATH, return_value=windows):
            result = detector.check_once()
            assert result is not None
            assert result.pattern.app_name == "Custom App"
